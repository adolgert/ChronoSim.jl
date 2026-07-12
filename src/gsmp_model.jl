########## The model value (Phase OB-3c, design doc Sections 3 and 6.1)
#
# One value that contains EXACTLY what determines the probability law of
# trajectories as a function of θ: the event families (entries, IN declaration
# order), the initial law, and the global parameter names. Everything else —
# sampler choice, observer, master seed, stop condition, execution policy — is
# a RUN concern and deliberately stays out of the model.
#
# The model value also owns the artifacts that only make sense once the whole
# model is in hand and never change afterward: the resolved per-family bindings
# (`resolve_entries`), the derived instance-key union (`event_key_union`), the
# family-position index, and the family-position key order that OB-3a's interim
# `Base.isless` deferred here. They are computed once at construction, so a
# consumer (e.g. a derivative-estimator extension) reads them as data instead
# of re-deriving them per run.

using Random: AbstractRNG

export GsmpModel, simulate, model_events, model_initial, model_params,
    model_keytype, family_index, model_binding, model_param_view,
    model_key_order, ModelKeyOrder

"""
    GsmpModel(; events, initial, params=nothing)

The MODEL VALUE of a generalized semi-Markov process: one value containing
exactly what determines the probability law of trajectories as a function of
the parameter vector θ, and nothing else.

```julia
model = GsmpModel(
    events  = (entry(Fail; params=(rate=:lambda,)), Repair),  # entries; bare types normalize
    initial = () -> make_factory(5),                          # any initial-law ladder rung
    params  = (:lambda, :mu),                                 # global θ names; θ is positional
)
record = simulate(rng, model, θ; horizon=20.0)
```

  * `events` — the event FAMILIES, as a tuple (or vector) of [`entry`](@ref)
    values and/or bare `SimEvent` subtypes (a bare type is the all-defaults
    family). Declaration ORDER is part of the model: it fixes each family's
    position ([`family_index`](@ref)) and the family-position key order
    ([`model_key_order`](@ref)).
  * `initial` — the initial law, any rung of the ladder
    ([`normalize_initial`](@ref)): a state value, a thunk, `(rng) -> state`,
    `(rng, θ) -> state`, an [`InitialLaw`](@ref), or an
    [`InitialRecipe`](@ref). Stored normalized.
  * `params` — the global θ-component names, a tuple of Symbols; a θ vector is
    read POSITIONALLY against this list. Omit it (or pass `nothing`) for a
    model whose families declare no parameter bindings.

Construction validates the whole model once: entries normalize, the same event
type may appear only once (two inclusions of one type need distinct parametric
types, e.g. `Break{:lineA}`/`Break{:lineB}`), every family binding resolves
against `params` ([`resolve_entries`](@ref)), and the initial law normalizes.
Derived artifacts are computed here and cached: the resolved bindings
([`model_binding`](@ref), [`model_param_view`](@ref)), the instance-key union
([`model_keytype`](@ref)), the family-position index
([`family_index`](@ref)), and the key order ([`model_key_order`](@ref)).

What is IN the model: the families with their per-model declarations, the
initial law, the parameter names. What is OUT, because it does not change the
probability law over trajectories (or is a choice about how to REALIZE the
law): the sampler method, the observer, the execution policy, the master seed,
and the stop condition — those belong to [`simulate`](@ref) or to a hand-built
[`SimulationFSM`](@ref).
"""
struct GsmpModel{Entries<:Tuple,N,CK}
    # The heterogeneous entries tuple keeps each family's concrete EventEntry
    # type, so tuple-position work (family_index, key order) is on typed data.
    events::Entries
    initial::NormalizedInitialLaw
    params::NTuple{N,Symbol}
    # Derived once at construction, immutable thereafter.
    resolved::Dict{DataType,ResolvedEntry}
    family_index::Dict{DataType,Int}
end

function GsmpModel(; events, initial, params=nothing)
    entries = map(_normalize_entry, Tuple(events))
    isempty(entries) && throw(ArgumentError(
        "GsmpModel needs at least one event family in `events`"))
    global_names = params === nothing ? nothing : _normalize_global_names(params)
    # resolve_entries is the shared validator (phase OB-3b): it throws on a
    # same-type-twice event list and on a binding that names an unknown global.
    resolved = resolve_entries(entries, global_names)
    nlaw = normalize_initial(initial)
    famidx = Dict{DataType,Int}(
        event_type(entries[i]) => i for i in eachindex(entries))
    CK = event_key_union(entries)
    stored = global_names === nothing ? () : global_names
    return GsmpModel{typeof(entries),length(stored),CK}(
        entries, nlaw, stored, resolved, famidx)
end

function Base.show(io::IO, m::GsmpModel)
    names = join((nameof(event_type(e)) for e in m.events), ", ")
    print(io, "GsmpModel(", length(m.events), " families: ", names,
        "; params=", m.params, ", initial=:", m.initial.form, ")")
end

"""
    model_events(model::GsmpModel) -> Tuple

The model's event families as normalized [`EventEntry`](@ref) values, in
DECLARATION order — the order that defines [`family_index`](@ref) and
[`model_key_order`](@ref). A bare type passed to the constructor appears here
as its all-defaults `entry(T)`.
"""
model_events(m::GsmpModel) = m.events

"""
    model_initial(model::GsmpModel) -> NormalizedInitialLaw

The model's initial law, normalized ([`normalize_initial`](@ref)). Pass it
anywhere a law is accepted: `run(sim, law, stop)`,
`trace_likelihood(sim, law, record)`, [`sample_initial`](@ref),
[`initial_logdensity`](@ref).
"""
model_initial(m::GsmpModel) = m.initial

"""
    model_params(model::GsmpModel) -> NTuple{N,Symbol}

The model's global θ-component names, in the positional order a θ vector is
read against. The empty tuple means the model declares no global names (every
family is whole-θ passthrough).
"""
model_params(m::GsmpModel) = m.params

"""
    model_keytype(model::GsmpModel) -> Type

The model's derived clock-key type: the `Union` of its event types
([`event_key_union`](@ref)), so event INSTANCES key every clock table. This is
the model value's default key representation — [`simulate`](@ref) passes it as
`key_type` — chosen because an isbits event union stores inline and stays
concrete when family arities differ.
"""
model_keytype(::GsmpModel{Entries,N,CK}) where {Entries,N,CK} = CK

# Shared lookup with the shared complaint: name the foreign type AND the
# model's own families, so the error reads without the model in hand.
function _model_family(m::GsmpModel, ::Type{E}) where {E<:SimEvent}
    idx = get(m.family_index, E, nothing)
    idx === nothing && throw(ArgumentError(
        "the event type $E is not a family of this model; its families are " *
        "(" * join((string(event_type(e)) for e in m.events), ", ") * ")"))
    return idx
end

"""
    family_index(model::GsmpModel, EventType) -> Int
    family_index(model::GsmpModel, event::SimEvent) -> Int

The POSITION of an event type's family in the model's declared event tuple
(1-based). This position, not the type's name, is the family's identity within
the model: [`model_key_order`](@ref) sorts keys by it, and a per-family
estimator indexes its accumulators with it. Throws an `ArgumentError` naming
the offending type for a type that is not a family of this model.
"""
family_index(m::GsmpModel, ::Type{E}) where {E<:SimEvent} = _model_family(m, E)
family_index(m::GsmpModel, event::SimEvent) = _model_family(m, typeof(event))

"""
    model_binding(model::GsmpModel, EventType) -> Union{Nothing,ResolvedBinding}

The family's RESOLVED parameter binding: `nothing` for a whole-θ passthrough
family (no declared formals), else the [`ResolvedBinding`](@ref) mapping the
family's formal names to θ positions. Resolved once at model construction;
compose it with `param_view(binding, θ)` or use
[`model_param_view`](@ref) directly. Throws for a type that is not a family of
this model.
"""
model_binding(m::GsmpModel, ::Type{E}) where {E<:SimEvent} =
    m.resolved[event_type(m.events[_model_family(m, E)])].binding

"""
    model_param_view(model::GsmpModel, EventType, θ)

What the θ seam hands `EventType`'s family at enabling time, built from the
model's resolved binding ([`model_binding`](@ref)) by OB-3b's `param_view`:
the whole `θ` object for a passthrough family, or the `NamedTuple` view of
exactly the bound components. The view's eltype follows `eltype(θ)`, so a
dual-valued θ yields a dual-valued view.
"""
model_param_view(m::GsmpModel, ::Type{E}, θ) where {E<:SimEvent} =
    param_view(model_binding(m, E), θ)

# ---------------------------------------------------------------------------
# The family-position key order.
# ---------------------------------------------------------------------------

"""
    ModelKeyOrder <: Base.Order.Ordering

The family-position key order of one [`GsmpModel`](@ref), built by
[`model_key_order`](@ref). Because it is a `Base.Order.Ordering`, it plugs
into the standard sorting verbs: `sort(keys; order=model_key_order(model))`,
`searchsortedfirst(keys, k, model_key_order(model))`, etc.
"""
struct ModelKeyOrder{M<:GsmpModel} <: Base.Order.Ordering
    model::M
end

"""
    model_key_order(model::GsmpModel) -> ModelKeyOrder

A total order on the model's instance keys AS A VALUE: keys compare by
`(family_index(model, typeof(key)), field values)` — the event type's POSITION
in the model's declared event tuple first, then the instance's fields. Being
position-based, the order is robust to RENAMING an event type: renaming
`Fail` to `Zfail` does not move its family, whereas the model-free interim
`Base.isless(::SimEvent, ::SimEvent)` (which compares `(nameof, fields)`
tuples) would reorder it.

A single global `isless` cannot know the model, so the family-position order
exists only as this model-derived value. The boundary is honest: the engine's
own deterministic sort sites (candidate sorting in `over_event_invariants`,
CompetingClocks' `enabled_ages`) keep sorting by the model-free interim order,
and trajectory byte-identity does NOT depend on which total order those sites
use — they only need SOME deterministic order. Threading the model into them
(especially into CompetingClocks) would be invasive for no statistical gain;
a consumer that wants family-position order (e.g. an estimator indexing
per-family accumulators by sorted position) sorts with this value:

```julia
sort(collect(keys(sim.enabled_events)); order=model_key_order(model))
```
"""
model_key_order(m::GsmpModel) = ModelKeyOrder(m)

# The instance's field values without the type-name Symbol that leads
# clock_key: family position replaces the name as the leading comparator.
_key_fields(evt::SimEvent) = Base.tail(clock_key(evt))

function Base.Order.lt(o::ModelKeyOrder, a::SimEvent, b::SimEvent)
    ia = family_index(o.model, typeof(a))
    ib = family_index(o.model, typeof(b))
    ia == ib || return ia < ib
    return isless(_key_fields(a), _key_fields(b))
end

# ---------------------------------------------------------------------------
# simulate: the model-value front door.
# ---------------------------------------------------------------------------

"""
    simulate(rng::AbstractRNG, model::GsmpModel, θ::AbstractVector;
             horizon::Real, sampler=nothing, observer=nothing,
             step_likelihood=false, likelihood_eltype=Float64) -> MinimalRecord

Run one trajectory of `model` at parameter vector `θ` over the window
`[0, horizon]` and return the self-contained [`MinimalRecord`](@ref): the
realized initial state, the firing sequence keyed by event INSTANCES
([`model_keytype`](@ref)), the horizon, the sampler's re-evaluation coupling,
and the fire-randomness flag. Because the record carries its realized x₀, it
can be scored later with `trace_likelihood(sim, model_initial(model), record)`
at any (possibly dual-valued) θ, with no seed relationship to this run.

`θ` is positional against [`model_params`](@ref); its length must match when
the model declares global names. The run's master seed is drawn from `rng`
(`rand(rng, UInt64)`), so trajectory identity is a function of `rng`'s state —
a hand-built [`SimulationFSM`](@ref) given that same seed, key type, params,
and law reproduces this record byte for byte.

Run concerns stay keywords here, not model fields: `sampler` is a
CompetingClocks method spec (default `NextReactionMethod()`), `observer` a
per-firing callback, and `step_likelihood`/`likelihood_eltype` opt into
forward likelihood accumulation, all as in [`SimulationFSM`](@ref). The stop
condition is the time horizon: the run stops before the first event whose
firing time exceeds `horizon`.

# The physical template

`SimulationFSM` needs a physical state at construction, before any
initialization, because the state's concrete type parameterizes the sim. The
law path (`run(sim, law, stop)`) then RE-SAMPLES x₀ into the sim from the
reserved, master-seed-pinned initialization stream. `simulate` therefore
builds a throwaway TEMPLATE by sampling the law once with a private
`Xoshiro(seed)` — its drawn values are discarded; only its concrete type
matters — and the realized x₀ the record carries is the law-path draw, which
depends only on the master seed, never on the template.
"""
function simulate(
    rng::AbstractRNG, model::GsmpModel, θ::AbstractVector;
    horizon::Real, sampler=nothing, observer=nothing,
    step_likelihood::Bool=false, likelihood_eltype::DataType=Float64,
)
    horizon >= 0 || throw(ArgumentError("simulate needs horizon >= 0; got $horizon"))
    if !isempty(model.params) && length(θ) != length(model.params)
        throw(ArgumentError(
            "θ has $(length(θ)) components but the model names " *
            "$(length(model.params)) parameters $(model.params); θ is read " *
            "positionally against those names"))
    end
    # The ONE draw from the caller's rng: the master seed. Everything random in
    # the run derives from it, so a hand-built twin sim given this seed is
    # byte-identical.
    seed = rand(rng, UInt64)
    law = model_initial(model)
    # Throwaway template; see the docstring. The private Xoshiro(seed) never
    # touches the engine's stream families.
    template = sample_initial(law, Xoshiro(seed), θ)
    policy = RecordMinimal(; initializer=law)
    sim = SimulationFSM(
        template, model_events(model);
        seed=seed,
        key_type=model_keytype(model),
        params=θ,
        param_names=isempty(model.params) ? nothing : model.params,
        policy=policy,
        sampler=sampler,
        observer=observer,
        step_likelihood=step_likelihood,
        likelihood_eltype=likelihood_eltype,
    )
    # The stop condition sees the event ABOUT to fire, so the horizon boundary
    # is exact: the last fired event's time is <= horizon.
    stop = (physical, step_idx, event, when) -> when > horizon
    run(sim, law, stop)
    return minimal_record(policy; horizon=horizon)
end
