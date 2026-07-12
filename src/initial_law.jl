########## The initial law (Phase OB-2, design doc Section 8)
#
# Initialization today is write-to-seed: the user's init callback WRITES the
# state, and those writes are what propose the first candidate events. That
# path stays fully supported. This file adds the declared alternative: the user
# states the probability law of the time-zero state, the engine SAMPLES x₀ from
# it, marks EVERY address changed (`all_addresses`), and runs the standard
# generator reaction once — no write discipline, no wart.
#
# The declaration is a LADDER OF FORMS, and the form is the promise (nothing is
# kept by discipline):
#
#   1. a state value                 — point mass;
#   2. a zero-arg thunk `() -> x`    — point mass, lazy;
#   3. `(rng) -> x`                  — random but θ-FREE, proved by arity: the
#                                      function never receives θ, so anything
#                                      it captures is a model constant;
#   4. `InitialLaw(sample, logdensity)` — the full θ-dependent law;
#   5. `InitialRecipe`               — a product-form recipe from which BOTH
#                                      sample and logdensity derive (they
#                                      cannot disagree).
#
# A bare `(rng, θ) -> x` sampler WITHOUT a density is also accepted — it
# simulates fine — but the likelihood refuses it BY NAME. θ-freeness of rungs
# 1–3 means the score's initial term is a θ-constant with zero derivative, so
# score gradients are correct with no density at all.
#
# Initial clock ages are OUT of scope for this version; `InitialLaw` is
# keyword-constructible so an optional ages slot can be added later without
# breaking existing constructions.

using Random: AbstractRNG
using .ObservedState: all_addresses

export AbstractInitialLaw, InitialLaw, InitialRecipe, NormalizedInitialLaw,
    normalize_initial, sample_initial, initial_logdensity, is_theta_dependent,
    has_logdensity, audit_initial_law, InitialLawAudit, all_addresses

# The likelihood's refusal, quoted where thrown so the message is identical at
# every refusal site (design doc Section 8).
const _DENSITYLESS_THETA_MSG =
    "the initial law is θ-dependent and has no logdensity; supply one, or " *
    "express the initialization as time-zero events."

"""
    AbstractInitialLaw

Supertype of the declared initial-law forms: [`InitialLaw`](@ref),
[`InitialRecipe`](@ref), and the normalized internal representation
[`NormalizedInitialLaw`](@ref) that [`normalize_initial`](@ref) maps every
ladder form onto. Dispatch surfaces that must not collide with the
write-to-seed initializer path (`run`, `trace_likelihood`) accept this type;
raw ladder forms (a state value, a thunk, an rng function) are accepted
directly by `initialize!` or wrapped once with `normalize_initial`.
"""
abstract type AbstractInitialLaw end

"""
    InitialLaw(sample, logdensity)
    InitialLaw(; sample, logdensity=nothing)

The full θ-dependent initial law (ladder rung 4): `sample(rng, θ) -> state`
draws a time-zero state and `logdensity(state, θ) -> Real` evaluates
`log p(state; θ)`. Because `sample` receives θ, the law is θ-dependent by
FORM; when constructed without a `logdensity` it still simulates, but
[`trace_likelihood`](@ref) refuses it by name. When you can express the law as
per-address distributions, prefer [`InitialRecipe`](@ref), whose sample and
density derive from one description and cannot disagree; a hand-written pair
can be checked with [`audit_initial_law`](@ref).

Keyword-constructible so that a future optional slot (e.g. initial clock ages)
can be added without breaking existing constructions; this version defines no
such slot.
"""
struct InitialLaw <: AbstractInitialLaw
    sample::Function
    logdensity::Union{Nothing,Function}
end
InitialLaw(; sample::Function, logdensity::Union{Nothing,Function}=nothing) =
    InitialLaw(sample, logdensity)

"""
    InitialRecipe(base, components)

The product-form initial law (ladder rung 5): a θ-free structural description
from which BOTH the sampler and the density derive, so they cannot disagree.
`base` is the time-zero state scaffold — either a state value (cloned per
sample) or a zero-arg function returning a fresh state. `components` is a
vector of `address => (θ -> Distribution)` pairs: each address (a tuple of
`Symbol`/`Member` field names and container indices, e.g.
`(:machine, 3, :up)`) receives an independent draw from its distribution built
at θ, and the density is the sum of `logpdf` of each component's distribution
at the realized value.

```julia
recipe = InitialRecipe(
    () -> Shop(4),
    [(:machine, i, :up) => (θ -> Bernoulli(θ[1])) for i in 1:4],
)
```

Distributions must produce values assignable to the addressed field (e.g.
`Bernoulli` for a `Bool` field, a discrete distribution for an `Int` field).
"""
struct InitialRecipe <: AbstractInitialLaw
    base::Any
    components::Vector{Pair{Tuple,Function}}
end
function InitialRecipe(base, components::AbstractVector{<:Pair})
    comps = Pair{Tuple,Function}[Tuple(addr) => fn for (addr, fn) in components]
    return InitialRecipe(base, comps)
end

"""
    NormalizedInitialLaw

The ONE internal representation every ladder form maps onto (see
[`normalize_initial`](@ref)): a `sample(rng, θ) -> state` closure, an optional
`logdensity(state, θ) -> Real` closure, the `theta_dependent` flag proved by
the declared form, and the `form` it came from (`:point`, `:thunk`, `:rng`,
`:law`, `:recipe`, or `:sampler`). Consumers read it through
[`sample_initial`](@ref), [`initial_logdensity`](@ref),
[`is_theta_dependent`](@ref), and [`has_logdensity`](@ref).
"""
struct NormalizedInitialLaw <: AbstractInitialLaw
    sample::Function                       # (rng, θ) -> state
    logdensity::Union{Nothing,Function}    # (state, θ) -> Real
    theta_dependent::Bool
    form::Symbol
end

# A point mass has log-probability zero at its atom; adding the constant is the
# honest choice (the ThetaInit prototype added it), and zero is exact here.
_zero_logdensity(state, θ) = 0.0

# Rung 1's sample must behave like a DRAW: each sample is an independent state,
# so an observed state is cloned per sample. A state type without the clone
# protocol is returned as-is (a repeated initialization then shares the object).
_point_value(v) = v
_point_value(v::ObservedState.ObservedPhysical) = clone(v)

"""
    normalize_initial(x) -> NormalizedInitialLaw

Map any ladder form onto the ONE internal representation:

  * a state value → point mass (θ-free, logdensity ≡ 0);
  * a zero-arg thunk `() -> state` → lazy point mass (θ-free, logdensity ≡ 0);
  * `(rng) -> state` → random but θ-free, no density (its likelihood term is a
    θ-constant that the likelihood omits — zero θ-derivative either way);
  * `(rng, θ) -> state` → a bare θ-dependent sampler with no density: it
    simulates, but the likelihood refuses it by name;
  * [`InitialLaw`](@ref) / [`InitialRecipe`](@ref) → the full θ-dependent law.

θ-freeness is proved by ARITY, checked with `hasmethod`: a callable is a thunk
if it has a zero-argument method, else the rng rung if it has a method
accepting one `AbstractRNG`, else the bare sampler rung if it has a
two-argument method. The checks run in that order, so a function with several
methods takes the LOWEST rung it supports. Two consequences to know about: a
vararg function `(args...) -> state` matches the zero-argument check and is
treated as a thunk, and a single-argument method typed NARROWER than
`AbstractRNG` (e.g. `f(rng::Xoshiro)`) is not recognized — type the argument
as `AbstractRNG` or leave it untyped. A callable struct that is not a
`Function` subtype is treated as a state VALUE (point mass); wrap it in
[`InitialLaw`](@ref) to use it as a sampler.
"""
normalize_initial(law::NormalizedInitialLaw) = law
normalize_initial(law::InitialLaw) =
    NormalizedInitialLaw(law.sample, law.logdensity, true, :law)
normalize_initial(r::InitialRecipe) = NormalizedInitialLaw(
    (rng, θ) -> _recipe_sample(r, rng, θ),
    (state, θ) -> _recipe_logdensity(r, state, θ),
    true, :recipe,
)
function normalize_initial(f::Function)
    if hasmethod(f, Tuple{})
        return NormalizedInitialLaw((rng, θ) -> f(), _zero_logdensity, false, :thunk)
    elseif hasmethod(f, Tuple{AbstractRNG})
        return NormalizedInitialLaw((rng, θ) -> f(rng), nothing, false, :rng)
    elseif hasmethod(f, Tuple{AbstractRNG,Any})
        return NormalizedInitialLaw((rng, θ) -> f(rng, θ), nothing, true, :sampler)
    else
        throw(ArgumentError(
            "this function fits no rung of the initial-law ladder: expected a " *
            "zero-arg thunk `() -> state`, a θ-free `(rng) -> state`, or a bare " *
            "sampler `(rng, θ) -> state` (the rng argument typed AbstractRNG or " *
            "untyped). A three-argument `(physical, when, rng)` initializer is " *
            "the write-to-seed path: pass it to `run`/`initialize!` directly, " *
            "not through the initial-law path."))
    end
end
normalize_initial(state) =
    NormalizedInitialLaw((rng, θ) -> _point_value(state), _zero_logdensity, false, :point)
# A SimEvent initializer belongs to the write-to-seed path, not the ladder.
normalize_initial(evt::SimEvent) = throw(ArgumentError(
    "a SimEvent initializer is the write-to-seed path; pass it to run/" *
    "initialize! directly. The initial-law ladder takes a state, a thunk, an " *
    "rng function, an InitialLaw, or an InitialRecipe."))

"""
    sample_initial(law, rng, θ) -> state

Draw a time-zero state from an initial law (any ladder form; normalized
internally). The engine calls this with the reserved initialization stream and
`sim.params` as θ.
"""
sample_initial(law::NormalizedInitialLaw, rng::AbstractRNG, θ) = law.sample(rng, θ)
sample_initial(law, rng::AbstractRNG, θ) = sample_initial(normalize_initial(law), rng, θ)

"""
    is_theta_dependent(law) -> Bool

Whether the initial law depends on the model parameters θ, proved by the
declared FORM (a point mass, thunk, or `(rng) -> state` function never receives
θ; an `InitialLaw`, `InitialRecipe`, or bare `(rng, θ) -> state` sampler does).
A θ-free law's likelihood term is a θ-constant with zero derivative, so score
gradients are correct without any density.
"""
is_theta_dependent(law::NormalizedInitialLaw) = law.theta_dependent
is_theta_dependent(law) = is_theta_dependent(normalize_initial(law))

"""
    has_logdensity(law) -> Bool

Whether the initial law carries a `log p(x₀; θ)` evaluator. Point masses do
(zero); recipes and full `InitialLaw`s do; the `(rng) -> state` rung and the
bare `(rng, θ) -> state` sampler do not.
"""
has_logdensity(law::NormalizedInitialLaw) = law.logdensity !== nothing
has_logdensity(law) = has_logdensity(normalize_initial(law))

"""
    initial_logdensity(law, state, θ) -> Real

Evaluate `log p(state; θ)` under the initial law. Throws an `ArgumentError`
when the law has no logdensity: a θ-dependent law is refused with the named
message ("the initial law is θ-dependent and has no logdensity; supply one, or
express the initialization as time-zero events."); a θ-free law without a
density is refused with an explanation that its term is an omittable
θ-constant. Guard calls with [`has_logdensity`](@ref).
"""
function initial_logdensity(law::NormalizedInitialLaw, state, θ)
    if law.logdensity === nothing
        if law.theta_dependent
            throw(ArgumentError(_DENSITYLESS_THETA_MSG))
        else
            throw(ArgumentError(
                "this θ-free initial law has no logdensity; its likelihood " *
                "contribution is a θ-constant (zero θ-derivative), which " *
                "trace_likelihood omits."))
        end
    end
    return law.logdensity(state, θ)
end
initial_logdensity(law, state, θ) = initial_logdensity(normalize_initial(law), state, θ)

# ---------------------------------------------------------------------------
# Recipe mechanics: navigate an address tuple over a state through the same
# property/index verbs the model uses, so a recipe address reads like model code.
# ---------------------------------------------------------------------------

_recipe_step(cur, part::Symbol) = getproperty(cur, part)
_recipe_step(cur, part::Member) = getproperty(cur, Symbol(part))
_recipe_step(cur, part::Tuple) = getindex(cur, part...)   # N-D Cartesian index
_recipe_step(cur, part) = getindex(cur, part)             # Int index or dict key

function _recipe_parent(state, addr::Tuple)
    cur = state
    for i in 1:(length(addr) - 1)
        cur = _recipe_step(cur, addr[i])
    end
    return cur
end

function _recipe_get(state, addr::Tuple)
    parent = _recipe_parent(state, addr)
    return _recipe_step(parent, addr[end])
end

function _recipe_set!(state, addr::Tuple, v)
    parent = _recipe_parent(state, addr)
    part = addr[end]
    if part isa Symbol
        setproperty!(parent, part, v)
    elseif part isa Member
        setproperty!(parent, Symbol(part), v)
    elseif part isa Tuple
        setindex!(parent, v, part...)
    else
        setindex!(parent, v, part)
    end
    return nothing
end

_materialize_base(b::Function) = b()
_materialize_base(b::ObservedState.ObservedPhysical) = clone(b)
_materialize_base(b) = deepcopy(b)

function _recipe_sample(r::InitialRecipe, rng::AbstractRNG, θ)
    state = _materialize_base(r.base)
    for (addr, distfn) in r.components
        _recipe_set!(state, addr, rand(rng, distfn(θ)))
    end
    return state
end

function _recipe_logdensity(r::InitialRecipe, state, θ)
    # The init accumulator carries θ's eltype so a dual-valued θ flows through.
    total = zero(float(eltype(θ) === Any ? Float64 : eltype(θ)))
    for (addr, distfn) in r.components
        total += logpdf(distfn(θ), _recipe_get(state, addr))
    end
    return total
end

# ---------------------------------------------------------------------------
# The engine path: initialize from a law, mark everything changed.
# ---------------------------------------------------------------------------

function _install_initial_state!(sim::SimulationFSM{State}, x0) where {State}
    x0 isa State || throw(ArgumentError(
        "the initial law sampled a $(typeof(x0)), but this simulation's physical " *
        "state is a $State; a law must produce the same concrete state type the " *
        "SimulationFSM was constructed with"))
    # A state built by user code follows the same construction path as the one
    # given to the SimulationFSM constructor (the @observedphysical constructor
    # wires top-level container back-pointers; elements wire at insertion), so
    # installing it needs no re-wiring.
    sim.physical = x0
    return nothing
end

"""
    initialize!(sim::SimulationFSM, law)

Initialize the simulation from a declared initial law (Phase OB-2) — the
additive alternative to the write-to-seed initializer
`initialize!(init_evt, init_func, sim)`, which is unchanged. `law` is any rung
of the ladder ([`normalize_initial`](@ref)): a state value, a thunk,
`(rng) -> state`, `(rng, θ) -> state`, an [`InitialLaw`](@ref), or an
[`InitialRecipe`](@ref).

The engine samples x₀ from the law using the reserved initialization stream
(the same stream the write-to-seed path hands its callback, so a same-seed run
reproduces the initial condition exactly) with `sim.params` as θ, installs x₀
as the physical state, marks EVERY address changed ([`all_addresses`](@ref)),
and runs the standard generator reaction once. There is no write-to-seed
discipline: the everything-changed set proposes every event whose precondition
holds in x₀.

Simulation never refuses a law: a θ-dependent law without a density initializes
and runs fine (tier 0); only [`trace_likelihood`](@ref) refuses it.
"""
function initialize!(sim::SimulationFSM, law)
    nlaw = normalize_initial(law)
    # Mirror the write-to-seed initializer exactly: a fresh trajectory starts
    # with a clean fire-randomness verdict, a reset draw counter, and no banked
    # age; initialization draws come from the reserved init stream, never
    # through the CountingRNG (the initial condition is not fire-random).
    sim.fire_random = false
    reset_count!(sim.counting_rng)
    empty!(sim.banked_age)
    on_preinit(sim.policy, sim)
    init_rng = stream_for!(sim.fire_streams, _INIT_STREAM_KEY)
    x0 = sample_initial(nlaw, init_rng, sim.params)
    _install_initial_state!(sim, x0)
    # Everything changed at time zero: enumerate the current state's addresses
    # and let the standard generator reaction propose the first events.
    changed = all_addresses(sim.physical)
    deal_with_changes(sim, sim.event_dependency, nothing, changed)
    checksim(sim)
    on_init(sim.policy, sim, InitializeEvent(), changed)
    sim.observer(sim.physical, sim.when, InitializeEvent(), changed)
    return sim
end

"""
    run(sim::SimulationFSM, law::AbstractInitialLaw, stop_condition)

Initialize `sim` from a declared initial law (see
[`initialize!`](@ref initialize!(::SimulationFSM, ::Any))) and generate a
trajectory until `stop_condition(physical, step_idx, event, when)` returns
`true`. This is the law-path twin of `run(sim, initializer, stop_condition)`;
raw ladder forms that are themselves `Function`s (a thunk, `(rng) -> state`)
must be wrapped once with [`normalize_initial`](@ref) so they cannot be
mistaken for a write-to-seed initializer callback.
"""
function run(sim::SimulationFSM, law::AbstractInitialLaw, stop_condition::Function)
    initialize!(sim, law)
    stop_condition(sim.physical, 0, InitializeEvent(), sim.when) && return nothing
    return _step_loop!(sim, _SamplerNext(), _StopAdapter(stop_condition))
end

# ---------------------------------------------------------------------------
# The likelihood term.
# ---------------------------------------------------------------------------

# The exactly-one guard's trace probe: does the trace itself claim a scored
# initialization step? See the comment at the guard site.
_trace_claims_initialize(trace) =
    !isempty(trace) && begin
        key = first(trace)[2]
        # Either key representation can claim initialization: the tuple
        # convention's (:InitializeEvent,) or an InitializeEvent instance key.
        (key isa Tuple && !isempty(key) && key[1] === :InitializeEvent) ||
            key isa InitializeEvent
    end

"""
    trace_likelihood(sim::SimulationFSM, law::AbstractInitialLaw, trace; params=nothing)
        -> TraceEvaluation

Evaluate a recorded trace against a model whose time-zero state is a declared
initial law: initialize `sim` through the law path (see
[`initialize!`](@ref initialize!(::SimulationFSM, ::Any))), walk the trace
exactly as the base [`trace_likelihood`](@ref) does, and ADD the initial-state
term `log p(x₀; θ)` to a feasible trajectory's log-likelihood.

  * A law WITH a logdensity contributes `initial_logdensity(law, x₀, θ)`
    evaluated at the realized x₀ the initialization just installed. For a
    point mass this constant is exactly zero; for a θ-dependent law it is the
    term whose θ-derivative is the initial-state score (the ThetaInit finding:
    the constant is added, not dropped, because the VALUE of the likelihood
    should be the whole likelihood).
  * A θ-free law WITHOUT a logdensity (the `(rng) -> state` rung) contributes
    nothing: its term is a θ-constant, so every θ-derivative is unaffected;
    only the likelihood's constant offset is unknown.
  * A θ-dependent law WITHOUT a logdensity is REFUSED with an `ArgumentError`:
    "$(_DENSITYLESS_THETA_MSG)" Simulation itself never refuses — only the
    likelihood does.

`params=θ` threads through the θ seam (guarantee G4) exactly as in the base
method and is in force both for the initialization draw and the trace walk.
An infeasible trace stays `-Inf` with no initial term. Raw ladder forms that
are `Function`s must be wrapped with [`normalize_initial`](@ref) so this
method cannot collide with the initializer-callback overload.

!!! warning "Evaluate at the recording run's master seed"
    The law path RE-DRAWS x₀ from the reserved initialization stream, which is
    pinned to the simulation's construction seeding. To score a trace recorded
    from a random law, build the evaluation sim with the SAME master seed as
    the recording run — that redraws the identical x₀; a different seed draws a
    different x₀ and the trace comes back infeasible. A point-mass law needs no
    such care.
"""
function trace_likelihood(
    sim::SimulationFSM, law::AbstractInitialLaw, trace::AbstractVector; params=nothing,
)
    sim.step_likelihood || throw(ArgumentError(
        "trace_likelihood needs a simulation built with step_likelihood=true; " *
        "for gradients also pass likelihood_eltype=eltype(θ). " *
        "Example: SimulationFSM(physical, events; step_likelihood=true)"))
    nlaw = normalize_initial(law)
    if is_theta_dependent(nlaw) && !has_logdensity(nlaw)
        throw(ArgumentError(_DENSITYLESS_THETA_MSG))
    end
    if params !== nothing
        sim.params = params
    end
    Base.require_one_based_indexing(trace)
    L = sim.likelihood_eltype
    acc = _TraceAccumulator{L}()
    initialize!(sim, nlaw)
    # The initial term is a function of the REALIZED x₀, which is sim.physical
    # right now, before any firing mutates it.
    init_term = has_logdensity(nlaw) ?
        initial_logdensity(nlaw, sim.physical, sim.params) : zero(L)
    # Exactly-one guard (design doc Section 8): a trajectory likelihood may
    # contain EITHER this initial-logdensity term OR a scored InitializeEvent
    # step — never both, or the time-zero probability would be double-counted.
    # Today NO scored-InitializeEvent mechanism exists (initialization draws
    # bypass the sampler entirely, so an InitializeEvent can never appear as a
    # scored step), which makes this an assertion seam: if a future change lets
    # a trace claim a scored initialization step, this must become a real
    # either/or dispatch instead of an assert.
    @assert !_trace_claims_initialize(trace) (
        "exactly one of {initial-law logdensity, scored InitializeEvent step} " *
        "may contribute to a trajectory likelihood; this trace begins with an " *
        "InitializeEvent step while the initial law supplies the time-zero term")
    _step_loop!(sim, _TraceNext(trace), acc)
    loglikelihood = acc.feasible ?
        convert(L, init_term + sum(acc.steploglik; init=zero(L))) : convert(L, -Inf)
    return TraceEvaluation(
        loglikelihood, acc.feasible, length(acc.steploglik), acc.first_infeasible,
        acc.steploglik,
    )
end

"""
    trace_likelihood(sim, law::AbstractInitialLaw, rec::MinimalRecord;
                     params=nothing, censor=false)

Evaluate a [`MinimalRecord`](@ref) under a declared initial law; the record's
firings are transposed to the trace convention, and `censor=true` adds the
finite-horizon survival tail exactly as the initializer-path method does.

A record that carries its realized initial state (`rec.initial_state`, captured
by [`RecordMinimal`](@ref) at `on_init`) is SELF-CONTAINED: the evaluation
initializes from that recorded x₀ as a point mass and adds
`initial_logdensity(law, rec.initial_state, θ)` — the density of the RECORDED
draw, which is the object a score estimator needs at a (possibly dual-valued)
θ. No seed relationship between the evaluating sim and the recording run is
required. Only a record WITHOUT a realized state (`initial_state === nothing`,
e.g. the `TrajectorySkeleton` projection) falls back to re-drawing x₀ from the
pinned init stream, which reproduces the recorded x₀ only when the evaluating
sim carries the recording run's master seed (see the warning on the
vector-trace method).
"""
function trace_likelihood(
    sim::SimulationFSM, law::AbstractInitialLaw, rec::MinimalRecord;
    params=nothing, censor::Bool=false,
)
    _warn_if_fire_random(rec)
    nlaw = normalize_initial(law)
    ev = if rec.initial_state === nothing
        trace_likelihood(sim, nlaw, _minimal_trace(rec); params=params)
    else
        _recorded_initial_likelihood(sim, nlaw, rec; params=params)
    end
    return censor ? _censor_evaluation(sim, ev, rec.horizon) : ev
end

# The self-contained record path: initialize from the record's realized x₀ (a
# point mass, so the walk cannot silently score a re-drawn, different initial
# state) and add the LAW's logdensity at that recorded state. The θ-dependence
# refusal must fire here too — the point-mass installation would otherwise let
# a density-less θ-dependent law slip through with a wrong (constant) term.
function _recorded_initial_likelihood(
    sim::SimulationFSM, nlaw::NormalizedInitialLaw, rec::MinimalRecord; params=nothing,
)
    if is_theta_dependent(nlaw) && !has_logdensity(nlaw)
        throw(ArgumentError(_DENSITYLESS_THETA_MSG))
    end
    point = normalize_initial(rec.initial_state)
    ev = trace_likelihood(sim, point, _minimal_trace(rec); params=params)
    # The point mass contributed exactly 0.0; swap in the law's own term. A
    # θ-free density-less law contributes nothing (a θ-constant), matching the
    # vector-trace method; an infeasible walk stays -Inf with no initial term.
    (ev.feasible && has_logdensity(nlaw)) || return ev
    L = sim.likelihood_eltype
    init_term = initial_logdensity(nlaw, rec.initial_state, sim.params)
    return TraceEvaluation(
        convert(L, ev.loglikelihood + init_term), ev.feasible, ev.steps_evaluated,
        ev.first_infeasible, ev.steploglik,
    )
end

# ---------------------------------------------------------------------------
# The sample/logdensity audit.
# ---------------------------------------------------------------------------

"""
    InitialLawAudit

The result of [`audit_initial_law`](@ref): `passed` (the loud verdict),
`pvalue` and `statistic` of the goodness-of-fit test, its degrees of freedom
`dof`, the `nsamples` drawn, and the number of distinct realized states
observed (`support`).
"""
struct InitialLawAudit
    passed::Bool
    pvalue::Float64
    statistic::Float64
    dof::Int
    nsamples::Int
    support::Int
end

function Base.show(io::IO, a::InitialLawAudit)
    print(io, "InitialLawAudit(passed=", a.passed, ", pvalue=", a.pvalue,
        ", support=", a.support, ", nsamples=", a.nsamples, ")")
end

# A hashable content digest of a realized state, because states themselves may
# not hash by content. An observed state digests through the same scalar-leaf
# walk `clone`/`verify_clone` use (so two states equal leaf-for-leaf digest
# equal); note that walk carries no ObservedSet contents. Any other state must
# itself hash by content.
_state_digest(x::ObservedState.ObservedPhysical) =
    hash([l.rawget() for l in ObservedState._collect_leaves(x)])
_state_digest(x) = hash(x)

"""
    audit_initial_law(law, rng, θ; nsamples=4000, alpha=1e-4) -> InitialLawAudit

Debug check that a law's `sample` and `logdensity` describe the SAME
distribution: draw `nsamples` states from `sample`, group them by a content
digest, and run a chi-square goodness-of-fit of the empirical counts against
`exp(logdensity)` on the OBSERVED support, with one pooled tail category for
the probability mass of never-observed states. The verdict is loud:
`passed == false` when the p-value falls below `alpha` (or when the density
assigns an observed state probability zero). Requires a law with a logdensity.

This audit is only meaningful for a HAND-WRITTEN sample/logdensity pair
([`InitialLaw`](@ref)): an [`InitialRecipe`](@ref) derives both from one
description, so they cannot disagree (auditing one is a self-check of the
recipe mechanics, not of the model). The digest walks an observed state's
scalar leaves; a law over any other state type needs states that hash by
content. Meaningful for laws with (effectively) FINITE support — a law over a
continuum makes every draw its own category and the chi-square degenerates.
"""
function audit_initial_law(
    law, rng::AbstractRNG, θ; nsamples::Integer=4000, alpha::Real=1e-4,
)
    nlaw = normalize_initial(law)
    has_logdensity(nlaw) || throw(ArgumentError(
        "audit_initial_law compares empirical frequencies against " *
        "exp(logdensity), so the law must carry a logdensity"))
    nsamples > 0 || throw(ArgumentError("audit_initial_law needs nsamples > 0"))
    counts = Dict{UInt64,Int}()
    reps = Dict{UInt64,Any}()
    for _ in 1:nsamples
        x = sample_initial(nlaw, rng, θ)
        dg = _state_digest(x)
        counts[dg] = get(counts, dg, 0) + 1
        haskey(reps, dg) || (reps[dg] = x)
    end
    stat = 0.0
    ptotal = 0.0
    zero_prob_observed = false
    for (dg, c) in counts
        p = exp(float(initial_logdensity(nlaw, reps[dg], θ)))
        if !(isfinite(p) && p > 0.0)
            # The density says this realized state is impossible: an automatic,
            # loud failure — no test statistic needed.
            zero_prob_observed = true
            continue
        end
        ptotal += p
        expected = nsamples * p
        stat += (c - expected)^2 / expected
    end
    ncat = length(counts)
    prest = 1.0 - ptotal
    if prest > 1e-12
        # Pool all never-observed states into one category with 0 observations.
        stat += nsamples * prest
        ncat += 1
    end
    dof = max(ncat - 1, 0)
    pvalue = if zero_prob_observed
        0.0
    elseif dof == 0
        1.0
    else
        ccdf(Chisq(dof), stat)
    end
    passed = !zero_prob_observed && pvalue >= alpha
    return InitialLawAudit(passed, pvalue, stat, dof, nsamples, length(counts))
end
