using Logging
using Random
import CompetingClocks
import CompetingClocks: clone, force_fire!, rekey_streams!
using CompetingClocks:
    SamplingContext, SamplerBuilder, NextReactionMethod, enable!, disable!, next,
    reenable!,
    keytype, steploglikelihood, KeyedStreams, stream_for!, pin_stream!,
    copy_clocks!

using Distributions

export SimulationFSM, ModelDefinitionError, TraceEvaluation, trace_likelihood,
    censoring_loglikelihood, event_key_union

# Milestone 4 (guarantee G7): the reserved fire-stream key for initialization
# draws. Init randomness precedes any firing, so it is drawn straight from this
# stream and NEVER through the CountingRNG detector -- init draws are not
# fire-randomness (matching M1 semantics, where the initial condition never set
# `fire_random`).
const _INIT_STREAM_KEY = (:__init__,)

########## The Simulation Finite State Machine (FSM)

mutable struct SimulationFSM{State,Sampler<:SamplingContext,CK,P<:ExecutionPolicy}
    physical::State
    sampler::Sampler
    immediategen::GeneratorSearch
    when::Float64
    rng::Xoshiro
    event_dependency::EventDependency{CK}
    enabled_events::Dict{CK,SimEvent}
    enabling_times::Dict{CK,Float64}
    # Milestone 5 (guarantee G6): the memory-policy bank. For an event declaring
    # `memory_policy == :resume`, the enabled age it accumulated before a disable is
    # banked HERE, keyed by clock, and read back when the clock is re-enabled to
    # left-shift the enabling time it hands the sampler (age-conditioned redraw). A
    # `:fresh` event NEVER touches this table, so a model with no memory declarations
    # keeps an empty bank and its behavior is unchanged. `initialize!` clears it, and
    # firing a clock clears that clock's entry (the draw is consumed).
    banked_age::Dict{CK,Float64}
    observer                    # untouched: untyped, backward compatible
    policy::P                   # NEW, last field
    step_likelihood::Bool       # opt-in trace-likelihood capability
    likelihood_eltype::DataType # eltype(θ) for ForwardDiff
    # Adoption step 1: fire-randomness detection. `counting_rng` is the rng handed
    # to user `fire!`; `fire_random` latches true for the run if any firing
    # advanced the draw count. Both are reset by `initialize!`. Milestone 4: the
    # wrapped generator is re-pointed at each firing to the firing event's own
    # keyed stream (below), so the SAME CountingRNG accumulates the count across a
    # whole firing while each event draws from its own stream.
    counting_rng::CountingRNG{Xoshiro}
    fire_random::Bool
    # Milestone 2 (design guarantee G4): the θ (parameter) seam. The engine passes
    # `params` to the four-argument `enable`/five-argument `reenable`, so an
    # estimator can re-evaluate the seam at a θ (possibly dual-valued) the forward
    # run never saw without re-instantiating global state. The field is untyped
    # (AbstractVector) to match this codebase's seam call sites, which are already
    # dynamic through abstract distributions; it is mutable, so `trace_likelihood`
    # can swap it in place. Defaults to `Float64[]`, which every pre-seam model
    # ignores (its `enable` never reads θ).
    params::AbstractVector
    # Milestone 4 (guarantee G7): firing draws are owned by keyed streams addressed
    # by MODEL-LEVEL identity. When event `evt` fires, user `fire!` receives a
    # CountingRNG wrapping `stream_for!(fire_streams, clock_key(evt))`, so an
    # event's firing randomness belongs to THAT event, not to a position in the
    # global call order: two runs from the same seed give each event identical
    # firing draws even when other events interleave differently. Immediate events
    # triggered inside a firing draw from their OWN clock_key streams; the reserved
    # `_INIT_STREAM_KEY` carries initialization draws. `KeyedStreams{Tuple}` (the
    # abstract Tuple key type) holds both the concrete clock-key tuples and the
    # reserved init key.
    fire_streams::KeyedStreams{Tuple}
    # The master seed from which every stream family is derived: the sampler
    # context's per-clock streams AND `fire_streams`. Recorded by the skeleton so a
    # replay reconstructs the identical randomness from the seed alone. `sim.rng` is
    # retained only as the documented carrier of this seed (removing it is out of
    # scope for milestone 4); it no longer feeds any draw.
    seed::UInt64
    # Phase OB-1: clock-key -> event-type resolution for the record-derived state
    # fold (`states_at`). The running engine resolves a clock key through
    # `sim.enabled_events`, but a fold over a FINISHED run has no enabled set for
    # mid-trajectory steps, so the constructor records the model's event types here
    # and the fold rebuilds each event with `key_clock`. Model-side and immutable
    # with respect to the trajectory, so `clone` shares it.
    event_types::Dict{Symbol,DataType}
    # Phase OB-3b: the per-FAMILY resolved entries (design doc Section 6). Each
    # event type in the model's event list maps to its effective memory policy
    # (entry override, else trait) and its resolved parameter binding (nothing =
    # whole-θ passthrough; a ResolvedBinding = the NamedTuple view over θ). The
    # engine consults this at the enable/reenable θ seam and at the two
    # memory-policy sites. Model-side and trajectory-immutable, so `clone` shares
    # it. An event type absent from this table (framework-test mocks) falls back
    # to the traits, i.e. behaves as its own all-defaults family.
    resolved_entries::Dict{DataType,ResolvedEntry}
end


"""
Look at events and determine a common base type.
Internally the simulation tracks events with sets of tuples by turning
each event instance into a tuple. If all the tuples have the same type,
this should turn out to be performant.
"""
function common_base_key_tuple(events)
    all_field_types = [Tuple{Symbol,fieldtypes(T)...} for T in events]
    typejoined = reduce(typejoin, all_field_types)
    return typejoined
end

"""
    event_key_union(events) -> Union{events...}

The clock-key type that makes event INSTANCES the sampler keys (phase OB-3a):
pass it as `key_type` to [`SimulationFSM`](@ref),

```julia
sim = SimulationFSM(shop, (Fail, Repair);
    key_type=event_key_union((Fail, Repair)), seed=1)
```

and the engine keys every table — the enabled set, the dependency network, the
sampler's clock table and per-clock streams — by the event struct itself
instead of by the `clock_key` tuple `(:TypeName, fields...)`.

Why choose it: when every event struct is `isbits`, the union is an
isbits-union, which Julia's `Dict`s and `Vector`s store INLINE (no per-key heap
box, unlike a tuple key whose leading `Symbol` forces boxing), and a model
whose event types have different field counts keeps a CONCRETE small-union key
where the default `common_base_key_tuple` degrades to an abstract
`Tuple{Symbol,Vararg}`. Trajectories are IDENTICAL across the two
representations at the same seed: the per-clock stream derivation hashes the
instance's `clock_key` tuple (the `CompetingClocks.stream_hash` overload), and
instances sort in their tuple keys' order (`Base.isless(::SimEvent,
::SimEvent)`).

Tuple keys remain the DEFAULT; instance keys are opt-in through this
`key_type`. (The design plan calls this helper `keytype`, but `Base.keytype`
and `CompetingClocks.keytype` already mean "the key type of a container", so
the union-builder gets its own name.) Elements may be bare event types or
[`entry`](@ref) values, matching what the event list accepts.
"""
event_key_union(events) = Union{(event_type(_normalize_entry(ev)) for ev in events)...}


"""
    SimulationFSM(physical_state, trans_rules; sampler, key_type, step_likelihood,
                  likelihood_eltype, seed, rng, observer=nothing, policy=NoPolicy(),
                  params=Float64[], param_names=nothing)

Create a simulation.

The `physical_state` is of type `PhysicalState`. The `trans_rules` are a list
of event FAMILIES: `SimEvent` subtypes and/or [`entry`](@ref) values, mixed
freely — a bare type is the all-defaults family `entry(T)`. An entry carries
this model's per-family declarations: a [`memory_policy`](@ref) override and a
parameter binding (see [`entry`](@ref)). The same event type may appear only
once; two inclusions of one type need distinct parametric types
(`Break{:lineA}`, `Break{:lineB}`).

`param_names` names the components of the global parameter vector `params`
(θ), as a tuple or vector of Symbols, e.g.
`param_names=(:fail_shape, :fail_scale, :repair_rate)`. It is required exactly
when some family declares a binding (a nonempty [`param_names`](@ref) trait on
the event type); each family's binding is resolved against it once, at
construction, and at enabling time that family's `enable`/`reenable` receives
a `NamedTuple` view of exactly its bound components through the θ seam
argument. Families with no declared binding receive the whole `params` vector
unchanged, exactly as before entries existed.

The seed is an integer seed for a `Xoshiro` random number
generator. The observer is a callback with the signature:

```
observer(physical, when::Float64, event::SimEvent, changed_places::AbstractSet{Tuple})
```

The `changed_places` argument is a set-like object with tuples that are keys that
represent which places were changed.

The `policy` keyword is an [`ExecutionPolicy`](@ref) that observes the executor
at its hook points; it defaults to [`NoPolicy`](@ref), which compiles away and
costs a production run nothing.

# Sampler selection

The `sampler` keyword takes a CompetingClocks sampler *method spec* or a
`CompetingClocks.SamplerBuilder`, and `SimulationFSM` owns the random number
generator and builds the underlying `SamplingContext` itself.

  * `sampler=nothing` (default) uses `NextReactionMethod()`, which reproduces the
    historical `CombinedNextReaction` sampler and its exact rng stream.
  * `sampler=spec` where `spec isa CompetingClocks.SamplerSpec` (e.g.
    `NextReactionMethod()`, `FirstReactionMethod()`) builds a context around that
    method.
  * `sampler=builder` where `builder isa SamplerBuilder` uses the builder as-is;
    in that case `key_type`, `step_likelihood`, and `likelihood_eltype` must not
    also be passed (the builder already carries them).

The `key_type` keyword overrides the clock-key type (default
`common_base_key_tuple` of the events). Passing
`key_type=event_key_union((EventA, EventB, ...))` opts into INSTANCE keys
(phase OB-3a): the event structs themselves key every clock table, which stores
isbits events inline and keeps a concrete key type when event arities differ;
trajectories are bit-identical to the tuple-keyed run at the same seed (see
[`event_key_union`](@ref)). Set `step_likelihood=true` to
opt in to the trace-likelihood machinery ([`trace_likelihood`](@ref)); passing a
non-`Float64` `likelihood_eltype` (e.g. `eltype(θ)` for `ForwardDiff`)
auto-enables it.

Passing a sampler *instance* (e.g. `CombinedNextReaction{K,Float64}()` or a
`MemorySampler`) is no longer supported and throws an `ArgumentError` with
migration guidance.
"""
function SimulationFSM(
    physical, events;
    sampler=nothing,
    key_type=nothing,
    step_likelihood::Bool=false,
    likelihood_eltype::DataType=Float64,
    observer=nothing, rng=nothing, seed=nothing,
    policy::ExecutionPolicy=NoPolicy(),
    params::AbstractVector=Float64[],
    param_names=nothing,
)
    # Phase OB-3b: the event list holds FAMILIES (entries); a bare type is the
    # all-defaults family. Everything downstream that wants the TYPES (key-type
    # inference, generator derivation, the key_clock table) reads the normalized
    # list, and the per-family declarations resolve into `resolved_entries`.
    entries = [_normalize_entry(ev) for ev in events]
    event_type_list = [event_type(ent) for ent in entries]
    resolved_entries = resolve_entries(entries, _normalize_global_names(param_names))
    # Milestone 4 (guarantee G7): a single master seed drives every stream family.
    # The sampler context's per-clock streams and the FSM's fire streams both
    # derive from `master_seed`, so recording the seed alone lets a replay
    # reconstruct the identical randomness (see `_apply_seeds!`). `rng` and `seed`
    # are two ways to supply the master seed; the retained `sim.rng` is thereafter
    # only the documented seed carrier and feeds no draw.
    master_seed::UInt64 = if !isnothing(seed)
        UInt64(seed)
    elseif !isnothing(rng)
        rand(rng, UInt64)
    else
        rand(RandomDevice(), UInt64)
    end
    randgen = Xoshiro(master_seed)

    if sampler isa SamplerBuilder
        if key_type !== nothing || step_likelihood || likelihood_eltype !== Float64
            throw(ArgumentError(
                "When `sampler` is a SamplerBuilder it already carries the clock " *
                "key type and likelihood settings; do not also pass `key_type`, " *
                "`step_likelihood`, or `likelihood_eltype`."))
        end
        builder = sampler
        if builder.time_type !== Float64 || builder.start_time != 0.0 ||
                builder.support_delayed
            throw(ArgumentError(
                "SimulationFSM requires a SamplerBuilder with time_type=Float64, " *
                "start_time=0.0, and support_delayed=false; the simulation clock " *
                "is Float64, starts at 0.0, and draws via next(), which does not " *
                "handle delayed reactions."))
        end
        ClockKey = builder.clock_type
        sim_step_likelihood = builder.step_likelihood || builder.path_likelihood ||
            builder.likelihood_cnt > 1
        sim_likelihood_eltype = builder.likelihood_eltype
    else
        # A non-Float64 accumulator implies a likelihood watcher is needed.
        sim_step_likelihood = step_likelihood || likelihood_eltype !== Float64
        sim_likelihood_eltype = likelihood_eltype
        ClockKey = key_type !== nothing ? key_type : common_base_key_tuple(event_type_list)
        method = if isnothing(sampler)
            # Pin the historical default; never let the builder auto-select, which
            # would pick a different sampler and change every seeded test.
            NextReactionMethod()
        elseif sampler isa CompetingClocks.SamplerSpec
            sampler
        else
            throw(ArgumentError(
                "The `sampler` keyword now takes a sampler *method spec* " *
                "(e.g. NextReactionMethod(), FirstReactionMethod()) or a " *
                "CompetingClocks.SamplerBuilder, not a sampler instance. " *
                "SimulationFSM owns the rng and builds the SamplingContext itself. " *
                "Replace `sampler=CombinedNextReaction{K,Float64}()` with " *
                "`sampler=NextReactionMethod(), key_type=K`."))
        end
        builder = SamplerBuilder(
            ClockKey, Float64; method=method,
            step_likelihood=sim_step_likelihood, likelihood_eltype=sim_likelihood_eltype,
        )
        @debug "Creating a sampler with clock key type $ClockKey"
    end
    ctx = SamplingContext(builder, randgen)
    generator_searches = generators_from_events(event_type_list)
    if isnothing(observer)
        observer = (args...) -> nothing
    end
    sim = SimulationFSM{typeof(physical),typeof(ctx),ClockKey,typeof(policy)}(
        physical,
        ctx,
        generator_searches["immediate"],
        0.0,
        randgen,
        EventDependency{ClockKey}(generator_searches["timed"]),
        Dict{ClockKey,SimEvent}(),
        Dict{ClockKey,Float64}(),
        Dict{ClockKey,Float64}(),   # banked_age (G6 memory policy); empty for :fresh-only models
        observer,
        policy,
        sim_step_likelihood,
        sim_likelihood_eltype,
        CountingRNG(randgen),   # inner generator is re-pointed per firing (see modify_state!)
        false,
        params,                 # the θ seam vector (Milestone 2, G4)
        KeyedStreams{Tuple}(),  # fire streams; seeded by `_apply_seeds!` below
        master_seed,
        Dict{Symbol,DataType}(nameof(evt) => evt for evt in event_type_list),
        resolved_entries,
    )
    # Seed both stream families deterministically from the master seed. This runs
    # after construction so the same helper serves `replay`, which reconstructs the
    # streams from the recorded seed on a freshly built sim.
    _apply_seeds!(sim, master_seed)
    return sim
end


"""
    _apply_seeds!(sim, master_seed; repin=true) -> sim

Derive and install every random stream family from a single `master_seed`
(guarantee G7). Two independent seeds are drawn from `Xoshiro(master_seed)` — one
for the sampler context's per-clock streams, one for the FSM's fire streams — and
applied with `rekey_streams!`. `sim.rng` is reset to `Xoshiro(master_seed)` as the
documented seed carrier, and `sim.seed` records the master seed. Both the
constructor and [`replay`](@ref) call this, so a run and its replay reconstruct
identical randomness from the recorded seed alone. The two seeds come from a
`Xoshiro(master_seed)` sequence, so the sampler and fire families never share a
stream yet both reproduce from the one recorded number. The derivation ORDER is
load-bearing: the sampler family's seed is drawn FIRST and the fire family's
SECOND (`_fold_fire_streams` in functionals.jl re-derives the fire family by
replaying exactly this order).

With `repin=true` (the constructor and `replay`), the reserved init stream
`_INIT_STREAM_KEY` is pinned to the fire-family seed just installed
(`pin_stream!`), so initialization draws belong to THIS seeding. A divergence
rekey ([`rekey_streams!`](@ref) on the sim) passes `repin=false`, which leaves
the pin at the seeding that created the world: a rekeyed clone re-initialized
from the same law redraws the SAME initial condition, because clones share x₀ —
branching happens after time zero.
"""
function _apply_seeds!(sim::SimulationFSM, master_seed::UInt64; repin::Bool=true)
    seedgen = Xoshiro(master_seed)
    rekey_streams!(sim.sampler.sampler, rand(seedgen, UInt64))
    rekey_streams!(sim.fire_streams, rand(seedgen, UInt64))
    repin && pin_stream!(sim.fire_streams, _INIT_STREAM_KEY)
    copy!(sim.rng, Xoshiro(master_seed))
    sim.seed = master_seed
    return sim
end


function checksim(sim::SimulationFSM)
    @assert keys(sim.enabled_events) == keys(sim.event_dependency.depnet.event)
    @assert sim.when == time(sim.sampler)
end

struct ModelDefinitionError <: Exception
    context::String
    event_type::Type
    event::Any
    cause::Exception
    backtrace::Vector
end

function Base.showerror(io::IO, e::ModelDefinitionError)
    println(io, "Error in user-defined $(e.context) for $(e.event_type)")
    println(io, "  Event: $(e.event)")
    println(io, "  Caused by:")
    showerror(io, e.cause)
    println(io, "\n\nIn model code:")
    Base.show_backtrace(io, e.backtrace)
end

function invoke_user_code(f::Function, context::String, event::SimEvent)
    try
        return f()
    catch e
        bt = catch_backtrace()
        throw(ModelDefinitionError(context, typeof(event), event, e, bt))
    end
end

"""
The three `sim_event_*` functions call user-defined code, so we separate this
out in order to check the calls and return values. This also provides a way
to mock interaction with both events and the sampler for testing the central
function `deal_with_changes()`. Subclass `SimEvent` to create a fake interaction.
"""
function sim_event_precondition(event::SimEvent, physical)
    reads_result = capture_state_reads(physical) do
        invoke_user_code("precondition", event) do
            precondition(event, physical)
        end
    end
    # Soundness oracle (opt-in): the derived triggers must cover every read the
    # precondition performed, else a change could flip it silently.
    maybe_verify_coverage(event, reads_result.reads)
    return reads_result
end


function sim_event_enable(event::SimEvent, event_key, sim, when)
    # Phase OB-3b: what flows through the seam's third argument is the FAMILY's
    # parameter view -- the whole `sim.params` vector for a family with no
    # binding (bit-for-bit the pre-entry behavior, same object), or the
    # NamedTuple view of exactly the bound components.
    θ_family = _family_params(sim, event)
    reads_result = capture_state_reads(sim.physical) do
        enabling_spec = invoke_user_code("enable", event) do
            # Four-argument θ seam (G4); `sim.params` defaults to Float64[] and the
            # default four-arg `enable` drops it, so pre-seam models are unchanged.
            enable(event, sim.physical, θ_family, when)
        end
        if length(enabling_spec) != 2
            error("""The enable() function for $event_key should return a
                distribution and a time. This one returns $enabling_spec.
                """)
        end
        return enabling_spec
    end
    (dist, enable_time) = reads_result.result
    # Memory policy (G6): a `:resume` clock re-enters at an age-conditioned draw. The
    # enabled age banked across its last disable left-shifts the enabling time we
    # hand the sampler, so a memory-carrying backend draws the remaining lifetime
    # conditioned on that age. A `:fresh` clock has no bank, so `te_used ==
    # enable_time` and this path is bit-for-bit the pre-milestone behavior.
    te_used = _resume_shifted_te(sim, event, event_key, enable_time)
    # `enabling_times` records the te the SAMPLER was given (the shifted te), so the
    # disable-path banking reads back the true accumulated active age. For a `:fresh`
    # event this equals `enable_time`, matching the value the create branch pre-set.
    sim.enabling_times[event_key] = te_used
    # User contract is absolute `enable_time`; the context takes a relative shift
    # `te = ctx.time + relative_te`, and `sim.when == time(ctx)` here.
    enable!(sim.sampler, event_key, dist, te_used - sim.when)
    on_enable(sim.policy, sim, event_key, event, dist, te_used)
    return (; reads=reads_result.reads)
end


"""
    _resume_shifted_te(sim, event, event_key, enable_time)

The enabling time actually handed to the sampler under the event's memory policy
(guarantee G6). For a `:fresh` event this is `enable_time` unchanged. For a
`:resume` event it is left-shifted by the age banked across the clock's last
disable, `enable_time − banked_age`, so a memory-carrying sampler draws the
remaining lifetime conditioned on the age the clock already has. The bank
already carries the full history (each re-enable's shift is folded into the next
disable's banked value), so no separate accumulation is needed here.
"""
function _resume_shifted_te(sim::SimulationFSM, event::SimEvent, event_key, enable_time::Float64)
    if _effective_memory(sim, event) === :resume
        return enable_time - get(sim.banked_age, event_key, 0.0)
    else
        return enable_time
    end
end


"""
    _family_params(sim, event)

The θ the seam hands this event's FAMILY (phase OB-3b): the family's
`param_view` -- the whole `sim.params` object for a family with no binding, or
the NamedTuple view of exactly its bound components. An event type not in the
model's event list (framework-test mocks) gets the whole vector, the pre-entry
behavior. The Dict lookup plus the dynamically typed `binding` field make this
a dynamic step, but it sits on a call path that is already dynamic over the
abstract `SimEvent`; `param_view` itself is type-stable given concrete
arguments.
"""
function _family_params(sim::SimulationFSM, event::SimEvent)
    re = get(sim.resolved_entries, typeof(event), nothing)
    re === nothing && return sim.params
    return param_view(re.binding, sim.params)
end

"""
    _effective_memory(sim, event) -> Symbol

The memory policy the engine applies to this event's FAMILY (phase OB-3b): the
entry's override when it gave one, else the type's [`memory_policy`](@ref)
trait -- both already folded into `resolved_entries` at construction. An event
type not in the model's event list falls back to the trait.
"""
function _effective_memory(sim::SimulationFSM, event::SimEvent)
    re = get(sim.resolved_entries, typeof(event), nothing)
    return re === nothing ? memory_policy(typeof(event)) : re.memory
end


function sim_event_reenable(event::SimEvent, event_key, sim)
    first_enable = sim.enabling_times[event_key]
    # Phase OB-3b: the reenable seam carries the SAME per-family view as enable.
    θ_family = _family_params(sim, event)
    reads_result = capture_state_reads(sim.physical) do
        invoke_user_code("reenable", event) do
            # Five-argument θ seam (G4); default five-arg `reenable` drops `sim.params`.
            reenable(event, sim.physical, θ_family, first_enable, sim.when)
        end
    end
    if !isnothing(reads_result.result)
        (dist, enable_time) = reads_result.result
        # Re-evaluation coupling (G6): which pathwise coupling realizes a mid-flight
        # distribution change (`:carry` maps the retained draw through the change,
        # the only IPA-safe coupling; `:redraw` draws the remaining lifetime fresh
        # at the current age) is a construction-time property of the sampler, chosen
        # via `NextReactionMethod(coupling=...)` / `FirstToFireMethod(coupling=...)`.
        # A sampler that cannot honor the requested coupling already errored when
        # the SimulationFSM was built, so no capability guard is needed here.
        # Absolute `enable_time` → relative shift; `sim.when == time(ctx)` here. The
        # relative-te computation is unchanged; only the verb (reenable!) differs
        # from the historical plain enable!.
        reenable!(sim.sampler, event_key, dist, enable_time - sim.when)
        on_enable(sim.policy, sim, event_key, event, dist, enable_time)
    end
    return reads_result.reads
end


"""
    deal_with_changes(sim::SimulationFSM, event_dependency, fired_event_keys, changed_places)

An event changed the state. This function modifies events to respond to changes in state.

 * `sim` - the simulation
 * `event_dependency` - the bipartite graph of addresses and clocks, separated out from the sim
   so that we can test more easily.
 * `fired_event_keys` - a list of what fired. It's a list because of immediate events.
 * `changed_places` - the addresses of physical state affected by firing.
"""
function deal_with_changes(
    sim::SimulationFSM{State,Sampler,CK}, event_dependency, fired_event_keys, changed_places
) where {State,Sampler,CK}
    # This function starts with enabled events. It ends with enabled events.
    # Let's look at just those events that depend on changed places.
    #                      Finish
    #                 Enabled     Disabled
    # Start  Enabled  re-enable   remove
    #       Disabled  create      nothing
    #
    # Sort for reproducibility run-to-run.
    isempty(changed_places) && return nothing

    clock_toremove = CK[]
    over_event_invariants(event_dependency, sim, fired_event_keys, changed_places) do event
        # _event_key, not clock_key: under instance keys (CK<:SimEvent) the
        # event is its own key; under tuple keys this is clock_key as before.
        check_clock_key = _event_key(CK, event)
        event_should_be_enabled, depends_places = sim_event_precondition(event, sim.physical)
        # While the current dependency network knows if it was enabled, we check it here
        # in case we use a dependency graph that doesn't depend on the current state.
        event_was_enabled = check_clock_key ∈ keys(sim.enabled_events)

        if event_was_enabled && !event_should_be_enabled
            push!(clock_toremove, check_clock_key)
        elseif !event_was_enabled && event_should_be_enabled
            record_admitted(event)
            sim.enabled_events[check_clock_key] = event
            sim.enabling_times[check_clock_key] = sim.when
            rate_deps, = sim_event_enable(event, check_clock_key, sim, sim.when)
            @debug "Evtkey $(check_clock_key) with enable deps $(depends_places) rate deps $(rate_deps)"
            add_event!(event_dependency, check_clock_key, depends_places, rate_deps)
        elseif event_was_enabled && event_should_be_enabled
            # Every time we check an invariant after a state change, we must
            # re-calculate how it depends on the state. For instance,
            # A can move right. Then A moves down. Then A can still move
            # right, but its moving right now depends on a different space
            # to the right. This is because a "move right" event is defined
            # relative to a state, not on a specific, absolute set of places.
            depended_on_places = getevent_enable(event_dependency, check_clock_key)
            @assert eltype(depends_places) == eltype(depended_on_places)
            if depends_places != depended_on_places
                rate_deps = sim_event_reenable(event, check_clock_key, sim)
                add_event!(event_dependency, check_clock_key, depends_places, rate_deps)
            else
                rate_deps = getevent_rate(event_dependency, check_clock_key)
                @assert eltype(rate_deps) == eltype(changed_places)
                if !isdisjoint(rate_deps, changed_places)
                    new_rate_deps = sim_event_reenable(event, check_clock_key, sim)
                    if rate_deps != new_rate_deps
                        add_event!(event_dependency, check_clock_key, depends_places, new_rate_deps)
                    end
                end
            end
            # else event wasn't enabled and it isn't now.
        end
    end

    disable_clocks!(sim, clock_toremove)
    remove_event!(event_dependency, clock_toremove)

    over_event_rates(event_dependency, sim, fired_event_keys, changed_places) do event
        rate_clock_key = _event_key(CK, event)
        rate_event = get(sim.enabled_events, rate_clock_key, nothing)
        if !isnothing(rate_event)
            rate_deps = getevent_rate(event_dependency, rate_clock_key)
            new_rate_deps = sim_event_reenable(rate_event, rate_clock_key, sim)
            if rate_deps != new_rate_deps
                cond_deps = getevent_enable(event_dependency, rate_clock_key)
                add_event!(event_dependency, rate_clock_key, cond_deps, new_rate_deps)
            end
            # else it won't be in event_dependency either so nothing to add/delete.
        end
    end
end


function disable_clocks!(sim::SimulationFSM, clock_keys)
    isempty(clock_keys) && return nothing
    @debug "Disable clock $(clock_keys)"
    for clock_done in clock_keys
        on_disable(sim.policy, sim, clock_done)
        # Memory policy (G6): a :resume clock that leaves the enabled set WITHOUT
        # firing banks its accumulated active age so the next enable can condition
        # its draw on it. te_effective is the te the sampler was given (recorded in
        # enabling_times), which for a resumed clock is already left-shifted by the
        # prior bank -- so `sim.when - te_effective` is the TOTAL active age across
        # every cycle, an assignment rather than a running sum. A :fresh clock never
        # touches the bank, so a model with no memory declarations is unaffected.
        evt = get(sim.enabled_events, clock_done, nothing)
        if evt !== nothing && _effective_memory(sim, evt) === :resume
            te_effective = get(sim.enabling_times, clock_done, sim.when)
            sim.banked_age[clock_done] = sim.when - te_effective
        end
        disable!(sim.sampler, clock_done)
        delete!(sim.enabled_events, clock_done)
        delete!(sim.enabling_times, clock_done)
    end
end


function modify_state!(sim::SimulationFSM, fire_event)
    # Hand user `fire!` the counting proxy, not a bare rng. Milestone 4 (G7): the
    # proxy's inner generator is re-pointed at THIS event's own keyed stream, so
    # the firing draws of a given event belong to that event and are identical
    # run-to-run for the same seed regardless of how other events interleave.
    # Swapping only the wrapped generator keeps a single CountingRNG accumulating
    # the draw count across the whole firing (main event + immediates), which is
    # how fire-randomness detection (guarantee G3) still works: the count is
    # sampled once around the whole firing, so immediate-event draws are included.
    crng = sim.counting_rng
    count_before = crng.count
    # Fire streams are keyed by clock_key TUPLES regardless of the simulation's
    # clock-key type (phase OB-3a): they carry model-level content identity, not
    # the sampler's key representation, and the reserved `_INIT_STREAM_KEY`
    # tuple lives in the same family. Keeping the fire family tuple-keyed makes
    # fire-draw identity across key representations automatic (same tuple, same
    # stream) and sidesteps a reserved-key/union type mismatch.
    crng.rng = stream_for!(sim.fire_streams, clock_key(fire_event))
    changes_result = capture_state_changes(sim.physical) do
        fire!(fire_event, sim.physical, sim.when, crng)
    end
    changed_places = changes_result.changes
    seen_immediate = SimEvent[]
    over_generated_events(
        sim.immediategen, sim.physical, clock_key(fire_event), changed_places
    ) do newevent
        if newevent ∉ seen_immediate && precondition(newevent, sim.physical)
            push!(seen_immediate, newevent)
            # An immediate event triggered inside the firing draws from ITS OWN
            # clock_key stream, not the triggering event's -- ownership follows
            # model identity, not call nesting.
            crng.rng = stream_for!(sim.fire_streams, clock_key(newevent))
            ans = capture_state_changes(sim.physical) do
                fire!(newevent, sim.physical, sim.when, crng)
            end
            # Merge the immediate event's changed addresses element-wise;
            # push! would insert the whole set as one (mistyped) element.
            union!(changed_places, ans.changes)
        end
    end
    if crng.count != count_before
        sim.fire_random = true
    end
    return changed_places
end

"""
    fire!(sim::SimulationFSM, time, event_key)

Let the event act on the state.
"""
fire!(sim::SimulationFSM, when, what) = _fire!(sim, when, what, _commit_natural)

# The natural-firing sampler commit: the race is realized, so the clock is
# committed with the sampler's `fire!` (which sets `ctx.time = when` and
# delegates to the underlying sampler). Committing with `fire!` rather than
# `disable!` avoids censoring a consumed draw and letting a reusing sampler (e.g.
# CombinedNextReaction) resurrect residual randomness -- a statistics bug for
# non-exponential distributions.
_commit_natural(sim::SimulationFSM, what, when) = fire!(sim.sampler, what, when)

# The branch-step sampler commit: the CHOSEN clock is imposed at the CHOSEN time
# regardless of the race, and the losers are re-conditioned on survival past
# `when` by the sampler's `force_fire!`. The state-update path is IDENTICAL to a
# natural firing (see `_fire!`); only which clock the sampler commits and how it
# re-conditions the losers differs, because the update rule is a property of the
# transition, not of why it fired.
_commit_force(sim::SimulationFSM, what, when) = force_fire!(sim.sampler, what, when)

# The shared firing core. `commit!(sim, what, when)` is the ONLY difference
# between a natural firing and a forced (branch) firing; everything else -- the
# state update, the enabled-set/dependency-network maintenance, the memory bank,
# the policy hooks, and the observer -- is common, because the resulting world
# depends on the transition that ran, not on why it ran.
function _fire!(sim::SimulationFSM, when, what, commit!::C) where {C}
    event = sim.enabled_events[what]              # moved up (no side effects)
    on_prefire(sim.policy, sim, what, event, when)  # sim.when is still the old time
    sim.when = when
    # Break the invariant that state and events are consistent.
    changed_places = modify_state!(sim, event)
    commit!(sim, what, when)
    delete!(sim.enabled_events, what)
    delete!(sim.enabling_times, what)
    # G6: firing realizes and CONSUMES the draw, so any resume bank for this clock is
    # spent -- a subsequent re-enable starts fresh. (No-op for a :fresh clock, which
    # never had an entry.)
    delete!(sim.banked_age, what)
    remove_event!(sim.event_dependency, [what])
    deal_with_changes(sim, sim.event_dependency, what, changed_places)
    checksim(sim)
    # Invariant for states and events is restored, so show the result.
    on_postfire(sim.policy, sim, what, event, when, changed_places)
    sim.observer(sim.physical, when, event, changed_places)
end

"""
    force_fire!(sim::SimulationFSM, event_key, tstar)

The branch step of the weak-derivative estimator (guarantee G2): fire the CHOSEN
`event_key` at the CHOSEN time `tstar` through the SAME state-update path as a
natural firing. The event must currently be enabled and `tstar` must not precede
the simulation clock. The state update, dependency-network maintenance, policy
hooks, and observer are identical to [`fire!`](@ref); only the sampler commit
differs (`force_fire!` on the context, which imposes the clock and re-conditions
the losers on survival past `tstar`). Requires a sampler whose
`CompetingClocks.supports_force` trait is true (the default `NextReactionMethod`
backend qualifies).
"""
function force_fire!(sim::SimulationFSM, what, tstar)
    tstar >= sim.when || throw(ArgumentError(
        "force_fire! time tstar=$tstar precedes the simulation clock sim.when=$(sim.when)"))
    haskey(sim.enabled_events, what) || throw(ArgumentError(
        "force_fire! cannot fire $what: it is not in the enabled set"))
    _fire!(sim, tstar, what, _commit_force)
end

get_enabled_events(sim::SimulationFSM) = collect(values(sim.enabled_events))

# ---------------------------------------------------------------------------
# Clone protocol (World-clone, guarantee G2): an independent copy of the whole
# running simulation such that stepping the clone behaves bit-for-bit as the
# original would have.
# ---------------------------------------------------------------------------

# A COUPLED copy of the live sampling context. `CompetingClocks.clone(sc, rng)`
# builds a decoupled shell (fresh empty sampler + freshly-cloned empty watchers,
# with time reset to the fixed start); `copy_clocks!` then carries the live
# state faithfully -- the sampler's keyed streams (generator states AND counts),
# the watchers' state, the delayed state, and the split weight -- so the clone's
# future draws are identical to the original's. We finish by restoring the live
# time, which `clone(sc, rng)` had reset to `fixed_start`. Using only the public
# `clone`/`copy_clocks!` verbs keeps the watcher fan-out in CompetingClocks'
# hands rather than reaching into its internals.
function _clone_context_coupled(sc::SamplingContext)
    newctx = clone(sc, copy(sc.rng))
    copy_clocks!(newctx, sc)
    newctx.time = sc.time
    return newctx
end

# The dependency network is trajectory state, so it is copied (its inner Dicts
# and Sets are duplicated). The GeneratorSearch (`eventgen`) is model-side and
# immutable with respect to the trajectory, so it is SHARED. The `seen` set is
# transient scratch (cleared at the top of every `over_event_invariants`), but
# is copied for completeness so the clone owns its own scratch.
function _copy_event_dependency(ed::EventDependency{CK}) where {CK}
    fresh = EventDependency{CK}(ed.eventgen)   # shares eventgen; empty depnet + seen
    for (place, de) in ed.depnet.place
        fresh.depnet.place[place] = (en=copy(de.en), ra=copy(de.ra))
    end
    for (evtkey, de) in ed.depnet.event
        fresh.depnet.event[evtkey] = (en=copy(de.en), ra=copy(de.ra))
    end
    union!(fresh.seen, ed.seen)
    return fresh
end

"""
    clone(sim::SimulationFSM) -> SimulationFSM

An independent copy of the whole running simulation (guarantee G2). Stepping the
clone behaves bit-for-bit as the original would have, because they share the
sampler's and fire streams' state at the clone point but no mutable object:

  * `physical` is deep-copied with the address protocol restored (see the
    `ObservedState` `clone`).
  * `sampler` is a COUPLED context copy (`_clone_context_coupled`): the cloned
    sampler carries the original's keyed-stream states, so both continuations
    draw the same per-clock randomness.
  * `fire_streams` is copied state-carrying (`copy`), so user `fire!` draws
    reproduce; `counting_rng` is a fresh wrapper (its inner generator is
    re-pointed to a fire stream at every firing anyway).
  * `event_dependency` copies the trajectory-state dependency network and SHARES
    the model-side generator search.
  * `enabled_events`, `enabling_times`, `banked_age` are copied
    (event values are immutable clock-keyed structs, so a shallow dict/set copy
    is a full copy of the mutable trajectory state).
  * `immediategen` (model-side generator search), `params` (read-only by the θ
    contract), `observer`, and `policy` are SHARED. Sharing `policy` keeps the
    concrete `SimulationFSM` type identical; for a branching clone the policy is
    typically `NoPolicy` (an immutable singleton), so sharing is safe. A policy
    that accumulates mutable per-run state should be cloned by the caller after
    `clone` if independent accounting is wanted.

The clone continues the SAME world as the original. To make it DIVERGE (an
independent branch), call `rekey_streams!(clone, new_seed)`.
"""
function clone(sim::SimulationFSM{State,Sampler,CK,P}) where {State,Sampler,CK,P}
    return SimulationFSM{State,Sampler,CK,P}(
        clone(sim.physical),
        _clone_context_coupled(sim.sampler),
        sim.immediategen,                       # shared: model-side generator search
        sim.when,
        copy(sim.rng),
        _copy_event_dependency(sim.event_dependency),
        copy(sim.enabled_events),
        copy(sim.enabling_times),
        copy(sim.banked_age),
        sim.observer,                           # shared: user callback
        sim.policy,                             # shared: see docstring
        sim.step_likelihood,
        sim.likelihood_eltype,
        CountingRNG(copy(sim.rng)),             # fresh wrapper; re-pointed per firing
        sim.fire_random,
        sim.params,                             # shared: read-only θ by contract
        copy(sim.fire_streams),                 # state-carrying stream copy
        sim.seed,
        sim.event_types,                        # shared: model-side, trajectory-immutable
        sim.resolved_entries,                   # shared: model-side, trajectory-immutable
    )
end

"""
    rekey_streams!(sim::SimulationFSM, seed) -> sim

Decouple a cloned simulation from its original by re-seeding EVERY random stream
family from a new master `seed` -- the sampler context's per-clock streams and
the FSM's fire streams alike -- reusing [`_apply_seeds!`](@ref). After this the
clone runs an INDEPENDENT continuation; a same-`seed` clone would instead track
the original bit-for-bit at the clone point. This is the divergence half of the
branch coupling.

One stream is exempt: the reserved initialization stream (`_INIT_STREAM_KEY`)
stays pinned to the seeding that created the world, so a rekeyed clone
re-initialized from the same initial law redraws the SAME time-zero state.
Clones share x₀; branching happens after time zero.
"""
rekey_streams!(sim::SimulationFSM, seed) = _apply_seeds!(sim, UInt64(seed); repin=false)

"""
Initialize the simulation. You could call it as a do-function.
It is structured this way so that the simulation will record changes to the
physical state.
```
    initialize!(sim) do init_physical
        initialize!(init_physical, agent_cnt, sim.rng)
    end
```
"""
function initialize!(init_evt, callback::Function, sim::SimulationFSM)
    # A fresh trajectory starts with a clean fire-randomness verdict. The counter
    # is reset too so any external inspection of `counting_rng.count` reflects
    # this run only. Milestone 4: initialization draws come from the reserved
    # `_INIT_STREAM_KEY` fire stream, NOT through the CountingRNG, so the initial
    # condition is never itself "fire-random" (matching M1 semantics). Because the
    # init stream is seeded from the master seed, a same-seed run reproduces the
    # initial condition exactly.
    sim.fire_random = false
    reset_count!(sim.counting_rng)
    # G6: a fresh trajectory carries no banked age.
    empty!(sim.banked_age)
    on_preinit(sim.policy, sim)
    init_rng = stream_for!(sim.fire_streams, _INIT_STREAM_KEY)
    changes_result = capture_state_changes(sim.physical) do
        callback(sim.physical, sim.when, init_rng)
    end
    # The `what` event is type Nothing to signal it isn't an event.
    deal_with_changes(sim, sim.event_dependency, nothing, changes_result.changes)
    checksim(sim)
    on_init(sim.policy, sim, init_evt, changes_result.changes)
    sim.observer(sim.physical, sim.when, init_evt, changes_result.changes)
end


"""
    run(simulation, initializer, stop_condition)

Given a simulation, this initializes the physical state and generates a
trajectory from the simulation until the stop condition is met. The `initializer`
is either a function whose argument is a physical state and returns nothing, or
it is an event key for an event that initializes the system. The
stop condition is a function with the signature:

```
stop_condition(physical_state, step_idx, event::SimEvent, when)::Bool
```

The event and when passed into the stop condition are the event and time that are
about to fire but have not yet fired. This lets you enforce a stopping time that
is between events.
"""
# Next-event source for the forward executor: draw from the sampler.
struct _SamplerNext end
function (::_SamplerNext)(sim::SimulationFSM, step_idx)
    (when, what) = next(sim.sampler)
    if isfinite(when) && !isnothing(what)
        return (when, what)
    else
        # The old forward loop logged @info exactly here, on sampler exhaustion.
        @info "No more events to process after $step_idx iterations."
        return nothing
    end
end

# Next-event source for the trace evaluator: index the recorded trace.
struct _TraceNext{T<:AbstractVector}
    trace::T
end
function (tn::_TraceNext)(sim::SimulationFSM, step_idx)
    step_idx > length(tn.trace) && return nothing
    (when, what) = tn.trace[step_idx]
    # A non-finite time or missing key ends evaluation, matching the old loop's
    # break; the old trace loop logged @info only in exactly this case.
    if isfinite(when) && !isnothing(what)
        return (when, what)
    else
        @info "No more events to process after $step_idx iterations."
        return nothing
    end
end

# Per-step gate for `run`: adapts the user stop condition. A concrete struct
# (not a closure) so the captured function's type is a parameter and the
# per-step call is statically dispatched.
struct _StopAdapter{F}
    stop_condition::F
end
function (sa::_StopAdapter)(sim::SimulationFSM, step_idx, what, when)
    return sa.stop_condition(sim.physical, step_idx, what, when)
end

# The executor seam. Both the forward executor (`run`) and the trace evaluator
# (`trace_likelihood`) drive this loop; they differ only in the two injected
# callables: `next_event(sim, step_idx) -> (when, what) | nothing` supplies the
# next event, and `before_step!(sim, step_idx, what, when) -> Bool` runs the
# per-step gate (stop condition or feasibility + accumulation) and returns
# `true` to stop before firing.
function _step_loop!(sim::SimulationFSM, next_event::N, before_step!::B) where {N,B}
    step_idx = 1
    while true
        nxt = next_event(sim, step_idx)
        if !isnothing(nxt)
            (when, what) = nxt
            before_step!(sim, step_idx, what, when) && break
            @debug "Firing $what at $when"
            fire!(sim, when, what)
        else
            break
        end
        step_idx += 1
    end
    return step_idx
end

function run(sim::SimulationFSM, init_evt::SimEvent, init_func::Function, stop_condition::Function)
    initialize!(init_evt, init_func, sim)
    stop_condition(sim.physical, 0, init_evt, sim.when) && return nothing
    return _step_loop!(sim, _SamplerNext(), _StopAdapter(stop_condition))
end

function run(sim::SimulationFSM, init_evt::SimEvent, stop_condition::Function)
    init_func = (physical, when, rng) -> fire!(init_evt, physical, when, rng)
    run(sim, init_evt, init_func, stop_condition)
end

function run(sim::SimulationFSM, initializer::Function, stop_condition::Function)
    run(sim, InitializeEvent(), initializer, stop_condition)
end

"""
    TraceEvaluation

The result of evaluating a recorded trace against a model with
[`trace_likelihood`](@ref).

# Fields

  * `loglikelihood::L` — sum of the per-step log-likelihoods, or `-Inf`
    when the trace is infeasible under the model. The element type `L` is
    `sim.likelihood_eltype` (`Float64` by default, or a `ForwardDiff.Dual`
    when `likelihood_eltype=eltype(θ)` was passed for gradients).
  * `feasible::Bool` — `true` when every step of the trace named an enabled
    event at a time strictly after the previous event.
  * `steps_evaluated::Int` — number of steps successfully evaluated; equals
    `length(steploglik)`. When infeasible, evaluation stopped at step
    `steps_evaluated + 1`.
  * `first_infeasible::Union{Nothing,Tuple{Int,Any,Symbol}}` — `nothing` for a
    feasible trace, else `(step, event, reason)` for the first failing step.
    `reason` is `:not_enabled` (the event was not in `sim.enabled_events` when
    its turn came) or `:time_order` (its time was not strictly greater than the
    simulation clock).
  * `steploglik::Vector{L}` — the per-step log-likelihood contributions,
    one entry per evaluated step.

The `sim` passed to [`trace_likelihood`](@ref) must be constructed with
`step_likelihood=true` so its `SamplingContext` records the enabled-clock
likelihood. To make the result differentiable with `ForwardDiff`, also pass
`likelihood_eltype=eltype(θ)`, which sets `L` to the Dual number type.
"""
struct TraceEvaluation{L<:Real}
    loglikelihood::L
    feasible::Bool
    steps_evaluated::Int
    first_infeasible::Union{Nothing,Tuple{Int,Any,Symbol}}
    steploglik::Vector{L}
end

function Base.show(io::IO, ev::TraceEvaluation)
    print(io, "TraceEvaluation(feasible=", ev.feasible,
        ", loglikelihood=", ev.loglikelihood,
        ", steps_evaluated=", ev.steps_evaluated, ")")
end

function Base.show(io::IO, ::MIME"text/plain", ev::TraceEvaluation)
    println(io, "TraceEvaluation")
    println(io, "  feasible         : ", ev.feasible)
    println(io, "  loglikelihood    : ", ev.loglikelihood)
    println(io, "  steps evaluated  : ", ev.steps_evaluated)
    if ev.first_infeasible === nothing
        print(io,   "  first infeasible : none")
    else
        (step, event, reason) = ev.first_infeasible
        print(io,   "  first infeasible : step ", step, ", event ", event,
            ", reason ", reason)
    end
end

# Per-step gate for the evaluator: feasibility check + accumulation.
mutable struct _TraceAccumulator{L<:Real}
    steploglik::Vector{L}
    feasible::Bool
    first_infeasible::Union{Nothing,Tuple{Int,Any,Symbol}}
end
_TraceAccumulator{L}() where {L<:Real} = _TraceAccumulator{L}(L[], true, nothing)
function (acc::_TraceAccumulator)(sim::SimulationFSM, step_idx, what, when)
    reason = if !haskey(sim.enabled_events, what)
        :not_enabled
    elseif !(when > sim.when)
        :time_order
    else
        nothing
    end
    if reason !== nothing
        acc.feasible = false
        acc.first_infeasible = (step_idx, what, reason)
        return true                       # stop the loop; do NOT fire
    end
    # The accumulator runs BEFORE fire! advances the clocks, so ctx.time (which
    # the context supplies as t0 internally) is the previous event time.
    push!(acc.steploglik, steploglikelihood(sim.sampler, when, what))
    return false
end

"""
    trace_likelihood(sim::SimulationFSM, initializer, trace; params=nothing) -> TraceEvaluation

Evaluate a recorded trace against a model: initialize `sim`, then walk the
trace, accumulating each step's log-likelihood and firing the step's event, and
return a [`TraceEvaluation`](@ref). The `trace` is an `AbstractVector` of
`(when::Float64, clock_key::Tuple)` pairs, as recorded by an observer via
`clock_key(event)`. The `initializer` is either an initialization function
`(physical, when, rng) -> nothing` or a `SimEvent` whose `fire!` initializes
the state; a third method accepts `(sim, init_evt::SimEvent, init_func::Function, trace)`.

Infeasible traces do not throw. If a step names an event that is not enabled,
or a time that is not strictly after the previous event's time, evaluation
stops and the result has `feasible == false`, `loglikelihood == -Inf`, and
`first_infeasible` identifying the step. A trace entry with a non-finite time
ends evaluation early without marking the trace infeasible.

`sim` must be constructed with `step_likelihood=true` so its `SamplingContext`
records the enabled-clock likelihood. To make the result differentiable with
`ForwardDiff`, also pass `likelihood_eltype=eltype(θ)`:

```julia
sim = SimulationFSM(physical, events; step_likelihood=true, likelihood_eltype=eltype(θ))
```

# The θ (parameter) seam

Pass `params=θ` to evaluate the trace at an explicit parameter vector `θ` (design
guarantee G4): before initialization, `sim.params` is set to `θ`, so the model's
four-argument `enable(event, physical, θ, when)` reads it. This removes the need
to bake θ into module globals between evaluations — an estimator that
re-evaluates at many θ (or a dual-valued θ from `ForwardDiff`) passes each one
here. Because the FSM is mutable, `sim.params` **stays set** after the call;
construct the sim with `likelihood_eltype=eltype(θ)` when θ is dual so the result
type follows.
"""
function trace_likelihood(
    sim::SimulationFSM, init_evt::SimEvent, init_func::Function, trace::AbstractVector;
    params=nothing,
)
    sim.step_likelihood || throw(ArgumentError(
        "trace_likelihood needs a simulation built with step_likelihood=true; " *
        "for gradients also pass likelihood_eltype=eltype(θ). " *
        "Example: SimulationFSM(physical, events; step_likelihood=true)"))
    # The θ seam (G4): evaluate this trace at an explicit parameter vector. The FSM
    # is mutable and this leaves `sim.params` set for later inspection; an estimator
    # that re-evaluates at many θ simply passes each θ here. `params` must be set
    # BEFORE `initialize!` below, because enabling happens during initialization.
    if params !== nothing
        sim.params = params
    end
    Base.require_one_based_indexing(trace)
    L = sim.likelihood_eltype
    acc = _TraceAccumulator{L}()
    initialize!(init_evt, init_func, sim)
    _step_loop!(sim, _TraceNext(trace), acc)
    loglikelihood = acc.feasible ? sum(acc.steploglik; init=zero(L)) : convert(L, -Inf)
    return TraceEvaluation(
        loglikelihood, acc.feasible, length(acc.steploglik), acc.first_infeasible,
        acc.steploglik,
    )
end

function trace_likelihood(sim::SimulationFSM, initializer::SimEvent, trace; params=nothing)
    init_func = (physical, when, rng) -> fire!(initializer, physical, when, rng)
    trace_likelihood(sim, initializer, init_func, trace; params=params)
end

function trace_likelihood(sim::SimulationFSM, initializer::Function, trace; params=nothing)
    trace_likelihood(sim, InitializeEvent(), initializer, trace; params=params)
end

"""
    censoring_loglikelihood(sim::SimulationFSM, horizon) -> L

The finite-horizon CENSORING contribution to a path log-likelihood: the log
probability that EVERY still-enabled clock does NOT fire between the last evaluated
event time (`sim.when`) and `horizon`. [`trace_likelihood`](@ref) stops at the last
recorded event and omits this survival term, so a trajectory observed over a fixed
window `[0, horizon]` -- rather than one that happens to end at its last event --
scores as `trace_likelihood(...).loglikelihood + censoring_loglikelihood(sim, horizon)`.
This is the term a score estimator for a horizon functional otherwise adds by hand.

The math is REUSED from CompetingClocks rather than reimplemented, through the same
`steploglikelihood` primitive [`trace_likelihood`](@ref) already scores each step
with. `steploglikelihood(ctx, t, which)` sums, over every still-enabled clock, the
firing clock's log-density and every OTHER clock's log-survival from the context
clock (`sim.when`) to `t`. Passing `which = nothing` — "no clock fires" — puts EVERY
enabled clock on the survival branch, so the result is exactly the log-probability
that no enabled clock fires in `(sim.when, horizon]`: the censoring term. The
per-clock base already subtracts survival up to `sim.when`, so a single call gives
the tail with no bookkeeping. Because the same primitive keeps the generic eltype
`L` (`Float64`, or a `ForwardDiff.Dual` when `likelihood_eltype=eltype(θ)`), a
dual-valued θ flows through unchanged — the horizon-aware score differentiates just
like the trace likelihood.

`sim` must have been built with `step_likelihood=true` and must be positioned at
the end of a run or a [`trace_likelihood`](@ref) evaluation (its enabled set and
`sim.when` are read as-is). Requires `horizon ≥ sim.when`; at `horizon == sim.when`
the term is zero.
"""
function censoring_loglikelihood(sim::SimulationFSM, horizon)
    sim.step_likelihood || throw(ArgumentError(
        "censoring_loglikelihood needs a simulation built with step_likelihood=true; " *
        "the finite-horizon survival term is read through the step-likelihood machinery."))
    horizon >= sim.when || throw(ArgumentError(
        "censoring horizon=$horizon precedes the last evaluated time sim.when=$(sim.when)"))
    # `which=nothing` matches no enabled clock, so every enabled clock takes the
    # log-survival branch: the probability that NOTHING fires over (sim.when, horizon].
    # steploglikelihood uses ctx.time == sim.when as the interval's left endpoint.
    return steploglikelihood(sim.sampler, horizon, nothing)
end
