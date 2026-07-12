########## Path functionals over a recorded trajectory + the derived state fold
#
# Phase OB-1 (design doc "the model value", Section 4). Two deliverables:
#
#  * PATH FUNCTIONALS (`IntegratedOccupancy`, `TerminalObservable`,
#    `FirstPassageTime`): a model author declares what is being measured ONCE,
#    as an observable of states, and every estimator reads the same object. The
#    smoothness class of the functional lives in its TYPE — that is where "IPA
#    is invalid for a terminal observable" can be a property of the type rather
#    than folklore. The names and semantics deliberately DUPLICATE
#    ClockGradients' functionals (decision gate G-A): the dependency points
#    ClockGradients → ChronoSim, so ChronoSim cannot import them, and the
#    duplication is the price of keeping the dependency direction.
#
#  * THE DERIVED STATE FOLD (`states_at`): "the state after firing a clock" is
#    answered by cloning the state and applying `fire!` to the clone, immediate
#    cascades included, so from the outside firing looks like a pure function
#    even though mutation happens inside — mutation inside, value semantics
#    outside. The fold consumes a recorded trace, needs no sampler, and rebuilds
#    each firing's randomness from the master seed, so even a fire-random
#    trajectory reproduces exactly.
#
# ChronoSim's `value` is plain Float64 evaluation. There is deliberately NO
# `lower`/`evaluate` split here: that split exists only for dual-θ replay
# (differentiating through a times vector), which stays in ClockGradients.

export PathFunctional, IntegratedOccupancy, TerminalObservable, FirstPassageTime,
    StateFold, states_at, value

"""
    PathFunctional

Abstract supertype of a path functional: a scalar read off one trajectory, such
as a time integral, a terminal observable, or a hitting time. Its concrete
subtype encodes the functional's smoothness class, which determines whether
pathwise/IPA differentiation is valid for it (that consumer lives in
ClockGradients; ChronoSim evaluates values only, via [`value`](@ref)).
"""
abstract type PathFunctional end

"""
    IntegratedOccupancy(g)

The time integral `∫₀ᵀ g(x_t) dt` of a state observable `g` over the
trajectory's piecewise-constant path: `states[k]` holds between firing `k-1`
and firing `k`, and the final state holds from the last firing to the horizon.
The pathwise-smooth form: the integrand is a step function of time whose only
θ-dependence is the step LOCATIONS (the firing times).
"""
struct IntegratedOccupancy{F} <: PathFunctional
    g::F
end

"""
    TerminalObservable(g)

The state observable at the horizon, `g(x_T)`. The jumpy form: as θ varies the
firing times shift but `x_T` (a discrete state) is piecewise constant, so under
a fixed firing order a pathwise/IPA derivative sees a frozen constant and
reports zero — the score estimator is what recovers the true derivative for
this class.
"""
struct TerminalObservable{F} <: PathFunctional
    g::F
end

"""
    FirstPassageTime(pred)

The first FIRING time at which the state satisfies predicate `pred`,
`inf{t_k : pred(x_{t_k})}` over the recorded firing times. [`value`](@ref)
throws an `ArgumentError` when no state along the trajectory (after the initial
one) satisfies `pred`. Pathwise-smooth exactly when the hitting step is
θ-stable.
"""
struct FirstPassageTime{F} <: PathFunctional
    pred::F
end

# ---------------------------------------------------------------------------
# The state fold.
# ---------------------------------------------------------------------------

"""
    StateFold{P} <: AbstractVector{P}

The result of [`states_at`](@ref): the trajectory's state snapshots as a
read-only vector (`fold[1]` is the initial state, `fold[k+1]` the state after
firing `k`, so `length(fold) == n_firings + 1`), plus the provenance flag

  * `fire_random::Bool` — `true` when any `fire!` along the fold drew
    randomness (detected by [`CountingRNG`](@ref), the same detector the
    forward engine uses). The fold still reproduces such a trajectory exactly
    when it rebuilds the same keyed streams from the same master seed, but the
    firing SEQUENCE is not a deterministic function of the initial condition,
    so record-derived estimators must not trust it blindly.
"""
struct StateFold{P} <: AbstractVector{P}
    states::Vector{P}
    fire_random::Bool
end

Base.size(fold::StateFold) = size(fold.states)
Base.getindex(fold::StateFold, i::Int) = fold.states[i]

function Base.show(io::IO, fold::StateFold{P}) where {P}
    print(io, "StateFold{", P, "}(", length(fold.states) - 1, " firings",
        fold.fire_random ? ", FIRE-RANDOM" : "", ")")
end
# AbstractArray's 3-arg show would print every state; keep the summary form.
Base.show(io::IO, ::MIME"text/plain", fold::StateFold) = show(io, fold)

# Fresh keyed fire streams derived from the sim's master seed, EXACTLY as
# `_apply_seeds!` derives them: first UInt64 out of Xoshiro(master_seed) seeds
# the sampler family (not ours — drawn and discarded to keep the derivation
# aligned), the second seeds the fire family. The sim's LIVE `fire_streams`
# cannot be reused: the forward run already consumed them, and per-key streams
# replay from the family seed alone (KeyedStreams seeds each key's generator
# from `hash((seed, key))` lazily), so a fresh family reproduces every firing's
# draws in trace order.
function _fold_fire_streams(sim::SimulationFSM)
    seedgen = Xoshiro(sim.seed)
    rand(seedgen, UInt64)                       # the sampler family's seed
    return KeyedStreams{Tuple}(rand(seedgen, UInt64))
end

# One composite firing step applied to a FOREIGN physical state. This MIRRORS
# `modify_state!` (framework.jl) rather than calling it, because `modify_state!`
# is welded to the live sim: it fires against `sim.physical`, advances the
# sim-owned CountingRNG/fire_streams, and latches `sim.fire_random` — none of
# which a pure fold may touch. The mirrored parts, kept in the engine's order:
# re-point the counting proxy at THIS event's own keyed stream, fire, then run
# the immediate-event cascade where each immediate draws from ITS OWN clock-key
# stream and its changed places merge element-wise into the step's set. Returns
# whether the composite step drew randomness.
function _fold_step!(immediategen, event_types, physical, key, when::Float64,
                     crng::CountingRNG, fire_streams::KeyedStreams)
    event = key_clock(key, event_types)
    ckey = clock_key(event)
    count_before = crng.count
    crng.rng = stream_for!(fire_streams, ckey)
    changes_result = capture_state_changes(physical) do
        fire!(event, physical, when, crng)
    end
    changed_places = changes_result.changes
    seen_immediate = SimEvent[]
    over_generated_events(immediategen, physical, ckey, changed_places) do newevent
        if newevent ∉ seen_immediate && precondition(newevent, physical)
            push!(seen_immediate, newevent)
            crng.rng = stream_for!(fire_streams, clock_key(newevent))
            ans = capture_state_changes(physical) do
                fire!(newevent, physical, when, crng)
            end
            union!(changed_places, ans.changes)
        end
    end
    return crng.count != count_before
end

"""
    states_at(sim, initial_physical, trace) -> StateFold

The derived pure state fold (design doc Section 4): reconstruct the sequence of
physical states a recorded trajectory visited by cloning `initial_physical` and
applying each trace entry's `fire!` to the clone, snapshotting (cloning) after
every firing. Mutation inside, value semantics outside: the returned
[`StateFold`](@ref) owns every state it holds (element 1 is a clone of the
initial state, element `k+1` the state after firing `k`) and shares no mutable
object with `initial_physical` or with `sim`.

  * `trace` is an `AbstractVector` of `(when::Float64, clock_key::Tuple)` pairs
    in firing order — the same convention [`trace_likelihood`](@ref) consumes —
    or a [`MinimalRecord`](@ref), whose `(clock_key, when)` firings are
    transposed internally. Clock keys follow the standard [`clock_key`](@ref)
    tuple convention `(:TypeName, fields...)`, or are event INSTANCES when the
    run used instance keys (see [`event_key_union`](@ref)); the fold rebuilds
    each event with [`key_clock`](@ref) from the event types the sim was
    constructed with (the identity for an instance key). Either way the fold's
    fire-draw streams are addressed by the tuple, so both representations of
    one trajectory replay identical draws.
  * `initial_physical` is the REALIZED initial state (after the run's
    initializer), because a [`MinimalRecord`](@ref) does not store it — it
    records only the initializer's identity. Capture it as
    `clone(sim.physical)` right after `initialize!`, or from an observer's
    init callback.
  * Firing is the COMPOSITE step the engine applies: immediate events
    triggered by a firing are applied inline, in the engine's deterministic
    order, so "fire `Break(3)`" means the whole composite change and immediate
    events cost nothing here.
  * Randomness inside `fire!` is reproduced, not forbidden: each firing draws
    from a fresh per-clock keyed stream family derived from `sim.seed` exactly
    as the forward run's was, so a fold over the trace THIS sim's run produced
    replays every draw bit-for-bit. The returned fold's `fire_random` flag
    reports whether any draw occurred.

The fold needs no sampler and computes no likelihood: it answers only "which
states did this trajectory visit", which is what a [`PathFunctional`](@ref)
consumes via [`value`](@ref).
"""
function states_at(sim::SimulationFSM, initial_physical, trace::AbstractVector)
    Base.require_one_based_indexing(trace)
    work = clone(initial_physical)
    states = [clone(initial_physical)]
    sizehint!(states, length(trace) + 1)
    # The inner generator is a placeholder; `_fold_step!` re-points it at each
    # firing's own keyed stream before any draw, matching `modify_state!`.
    crng = CountingRNG(Xoshiro(0))
    fire_streams = _fold_fire_streams(sim)
    fire_random = false
    for (when, key) in trace
        fire_random |= _fold_step!(
            sim.immediategen, sim.event_types, work, key, Float64(when),
            crng, fire_streams,
        )
        push!(states, clone(work))
    end
    return StateFold(states, fire_random)
end

states_at(sim::SimulationFSM, initial_physical, rec::MinimalRecord) =
    states_at(sim, initial_physical, _minimal_trace(rec))

# ---------------------------------------------------------------------------
# Evaluating a functional on a fold.
# ---------------------------------------------------------------------------

function _check_fold_lengths(states, times)
    length(states) == length(times) + 1 || throw(ArgumentError(
        "a state fold must hold one more state than firing times " *
        "(states[1] is the initial state); got $(length(states)) states " *
        "for $(length(times)) times"))
    return nothing
end

function _check_horizon(fn, times, horizon)
    isfinite(horizon) || throw(ArgumentError(
        "$(nameof(typeof(fn))) needs a finite horizon"))
    if !isempty(times) && horizon < times[end]
        throw(ArgumentError(
            "$(nameof(typeof(fn))) needs a horizon at or after the last firing " *
            "time; horizon=$horizon precedes times[end]=$(times[end])"))
    end
    return nothing
end

"""
    value(fn::PathFunctional, states, times, horizon) -> Float64
    value(fn::PathFunctional, sim, initial_physical, trace; horizon=nothing) -> Float64

Evaluate a path functional on one recorded trajectory, as a plain `Float64`.
`states` is the trajectory's state fold (a [`StateFold`](@ref) from
[`states_at`](@ref), or any `AbstractVector` with `states[1]` the initial state
and `states[k+1]` the state after firing `k`), `times` the firing times in
order, and `horizon` the end of the observation window. `states[k]` holds
between `times[k-1]` and `times[k]`; the final state holds to the horizon.

  * [`IntegratedOccupancy`](@ref)`(g)`: `Σₖ g(states[k])·(times[k]−times[k-1])
    + g(states[end])·(horizon−times[end])`. Requires a finite
    `horizon ≥ times[end]`.
  * [`TerminalObservable`](@ref)`(g)`: `g(states[end])`, the value held at the
    horizon. Requires a finite `horizon ≥ times[end]`.
  * [`FirstPassageTime`](@ref)`(pred)`: the first `times[k]` with
    `pred(states[k+1])` true; throws an `ArgumentError` naming the functional
    when the trajectory never hits. Ignores `horizon`.

The convenience form folds the states itself via [`states_at`](@ref) and reads
the firing times off the trace; `horizon=nothing` defaults to the record's own
`horizon` when `trace` is a [`MinimalRecord`](@ref) and to the last firing time
for a raw `(when, clock_key)` trace.
"""
function value(fn::IntegratedOccupancy, states::AbstractVector,
               times::AbstractVector, horizon::Real)
    _check_fold_lengths(states, times)
    _check_horizon(fn, times, horizon)
    total = 0.0
    tprev = 0.0
    for k in eachindex(times)
        total += Float64(fn.g(states[k])) * (Float64(times[k]) - tprev)
        tprev = Float64(times[k])
    end
    return total + Float64(fn.g(states[end])) * (Float64(horizon) - tprev)
end

function value(fn::TerminalObservable, states::AbstractVector,
               times::AbstractVector, horizon::Real)
    _check_fold_lengths(states, times)
    _check_horizon(fn, times, horizon)
    return Float64(fn.g(states[end]))
end

function value(fn::FirstPassageTime, states::AbstractVector,
               times::AbstractVector, horizon::Real=Inf)
    _check_fold_lengths(states, times)
    for k in eachindex(times)
        fn.pred(states[k + 1]) && return Float64(times[k])
    end
    throw(ArgumentError(
        "the trajectory never satisfies the FirstPassageTime predicate over its " *
        "$(length(times)) firings"))
end

function value(fn::PathFunctional, sim::SimulationFSM, initial_physical,
               trace::AbstractVector; horizon::Union{Nothing,Real}=nothing)
    fold = states_at(sim, initial_physical, trace)
    times = Float64[Float64(step[1]) for step in trace]
    h = _functional_horizon(horizon, nothing, times)
    return value(fn, fold, times, h)
end

function value(fn::PathFunctional, sim::SimulationFSM, initial_physical,
               rec::MinimalRecord; horizon::Union{Nothing,Real}=nothing)
    fold = states_at(sim, initial_physical, rec)
    times = Float64[when for (clock, when) in rec.firings]
    h = _functional_horizon(horizon, rec.horizon, times)
    return value(fn, fold, times, h)
end

# The convenience form's horizon default: an explicit horizon wins; a
# MinimalRecord supplies its own; a raw trace falls back to its last firing time
# (matching `minimal_record`'s own default).
_functional_horizon(h::Real, record_horizon, times) = Float64(h)
_functional_horizon(::Nothing, record_horizon::Real, times) = Float64(record_horizon)
_functional_horizon(::Nothing, ::Nothing, times) =
    isempty(times) ? 0.0 : Float64(times[end])
