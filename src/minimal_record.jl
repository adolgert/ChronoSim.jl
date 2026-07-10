########## Minimal trajectory record + the pure-replay effect check
#
# Adoption steps 1 and 2 (design §"What this means for ChronoSim.jl"). Two
# deliverables live here:
#
#  * A PINNED MINIMAL RECORD SCHEMA (`MinimalRecord`): the least state a
#    record-derived derivative estimator needs to reconstruct a trajectory --
#    the initial condition's identity, the firing sequence `(clock_key, when)`,
#    the horizon, plus two provenance flags: an honest summary of which
#    re-evaluation coupling ran (`coupling`, guarantee G6 -- :redraw / :carry /
#    :mixed, derived from the couplings that actually ran) and whether any firing
#    drew randomness (`fire_random`, guarantee G3). The richer `TrajectorySkeleton`
#    stays; `minimal_record(::TrajectorySkeleton)` projects it down to the schema.
#
#  * THE PURE-REPLAY EFFECT CHECK (`effect_check`): for a draw-free model,
#    `trace_likelihood` of the engine's OWN trace must reproduce the
#    forward-accumulated log-likelihood EXACTLY (Float64 `==`, not `≈`), because
#    forward execution and trace replay share `_step_loop!` and the same enable
#    path, so both evaluate `steploglikelihood` on identical inputs. Any drift is
#    a silent incrementalization bug -- an under-declared read dependency once
#    produced a 34-standard-error bias that this exact-equality check caught on
#    20/20 trajectories where a tolerance-based check would not have.
#
# The forward log-likelihood is accumulated through the SAME code path the trace
# evaluator uses: `on_prefire` fires at the very top of `fire!`, before the
# clock is consumed and before `sim.when` advances -- the identical sampler state
# the trace evaluator's `_TraceAccumulator` sees just before it fires the step --
# so the per-step values, and their `sum(...; init=zero(L))` reduction, match bit
# for bit.

export MinimalRecord, RecordMinimal, minimal_record, effect_check,
    EffectCheckResult, forward_loglikelihood

"""
    MinimalRecord{CK}

The pinned minimal schema for a recorded trajectory -- everything a
record-derived derivative estimator needs and nothing more.

# Fields

  * `initializer::Any` — identity of the initial condition: the init `SimEvent`,
    an init function, or opaque metadata naming it. The framework never
    interprets this; it is handed back to `effect_check`/`trace_likelihood`.
  * `firings::Vector{Tuple{CK,Float64}}` — the firing sequence as
    `(clock_key, when)` pairs in firing order. (Note the order: clock first,
    time second, matching `TrajectorySkeleton`'s `SkeletonStep`; `trace_likelihood`
    consumes the transposed `(when, clock_key)` form, and the conversion is
    internal.)
  * `horizon::Float64` — the trajectory's end time. Defaults to the last firing's
    time when not given explicitly.
  * `coupling::Symbol` — an HONEST per-run summary of which re-evaluation coupling
    (guarantee G6) actually ran during the run: `:redraw` when every re-evaluation
    that ran used `:redraw` (and, by convention, when NO re-evaluation ran at all,
    since `:redraw` is the coupling any hypothetical re-evaluation would have used),
    `:carry` when every one used `:carry`, and `:mixed` when both couplings ran.
    A uniform-recovery estimator (see `proto_derived_draws.md`) needs the trace
    labeled with the coupling that produced it; `:mixed` is honest and simply marks
    per-event coupling labeling as a future refinement.
  * `fire_random::Bool` — `true` if any firing drew randomness (detected by the
    framework's [`CountingRNG`](@ref)). When `true`, the firing sequence is not a
    deterministic function of the initial condition, so record-derived estimators
    must not trust it; consumers warn.
"""
struct MinimalRecord{CK}
    initializer::Any
    firings::Vector{Tuple{CK,Float64}}
    horizon::Float64
    coupling::Symbol
    fire_random::Bool
end
# `CK` is inferred from `firings` by the default constructor, so callers write
# `MinimalRecord(init, firings, horizon, coupling, fire_random)` without the
# type parameter.

function Base.show(io::IO, rec::MinimalRecord{CK}) where {CK}
    print(io, "MinimalRecord{", CK, "}(", length(rec.firings), " firings, horizon=",
        rec.horizon, ", coupling=:", rec.coupling,
        rec.fire_random ? ", FIRE-RANDOM" : "", ")")
end

Base.:(==)(a::MinimalRecord, b::MinimalRecord) =
    isequal(a.initializer, b.initializer) && a.firings == b.firings &&
    a.horizon == b.horizon && a.coupling == b.coupling && a.fire_random == b.fire_random

# Convert to `trace_likelihood`'s `(when, clock_key)` convention.
_minimal_trace(rec::MinimalRecord{CK}) where {CK} =
    Tuple{Float64,CK}[(when, clock) for (clock, when) in rec.firings]

_resolve_horizon(h::Real, firings, fallback::Float64) = Float64(h)
_resolve_horizon(::Nothing, firings, fallback::Float64) =
    isempty(firings) ? fallback : Float64(firings[end][2])

########## RecordMinimal: produce a MinimalRecord (and the forward log-likelihood)
##########               directly during a forward run.

# CK/L-typed accumulation behind a function barrier, exactly as RecordSkeleton
# does: the policy field is abstract because CK and L are unknown until the sim
# is in hand at on_preinit, so each hook makes one dynamic dispatch into a
# _rec_min_* method inside which every push! is type-stable.
mutable struct _MinimalRecorder{CK,L}
    firings::Vector{Tuple{CK,Float64}}
    forward_steploglik::Vector{L}
    fire_random::Bool
    # G6: the set of re-evaluation couplings that actually RAN during the run,
    # unioned from `sim.couplings_ran` after each firing. Projected into the record's
    # honest `coupling` summary (:redraw / :carry / :mixed) by `_coupling_label`.
    couplings::Set{Symbol}
end

"""
    _coupling_label(couplings::Set{Symbol}) -> Symbol

Project the set of re-evaluation couplings that RAN into the record's honest
per-run summary (guarantee G6): `:redraw` when the set is empty (no re-evaluation
ran, so the default coupling any hypothetical re-evaluation would have used) or
contains only `:redraw`, `:carry` when it contains only `:carry`, and `:mixed`
when both ran.
"""
function _coupling_label(couplings::Set{Symbol})
    has_carry = :carry in couplings
    has_redraw = :redraw in couplings
    if has_carry && has_redraw
        return :mixed
    elseif has_carry
        return :carry
    else
        # Empty set (no re-evaluation ran) or only :redraw both label :redraw.
        return :redraw
    end
end

"""
    RecordMinimal(; initializer=nothing)

An [`ExecutionPolicy`](@ref) that records a [`MinimalRecord`](@ref) of a forward
run and, when the simulation was built with `step_likelihood=true`, accumulates
the forward log-likelihood through the same `steploglikelihood` call the trace
evaluator uses. Recording is opt-in and observation-only: pass
`policy=RecordMinimal()` to [`SimulationFSM`](@ref); a sim without it pays
nothing. `initializer` is stored in the produced record's `initializer` field as
the identity of the initial condition. After `run` returns, project the schema
with [`minimal_record`](@ref) and read the forward log-likelihood with
[`forward_loglikelihood`](@ref); [`effect_check`](@ref) consumes the policy
directly. The produced record's `coupling` summary (guarantee G6) is derived from
the re-evaluation couplings that actually ran during the run, not a constant.

```julia
pol = RecordMinimal(; initializer=MyInit())
sim = SimulationFSM(phys, EVENTS; seed=1, step_likelihood=true, policy=pol)
ChronoSim.run(sim, MyInit(), stop)
rec = minimal_record(pol; horizon=10.0)
res = effect_check(() -> SimulationFSM(phys, EVENTS; step_likelihood=true), MyInit(), pol)
```
"""
mutable struct RecordMinimal <: ExecutionPolicy
    initializer::Any
    recorder::Union{Nothing,_MinimalRecorder}   # bound at on_preinit
end
RecordMinimal(; initializer=nothing) = RecordMinimal(initializer, nothing)

function on_preinit(p::RecordMinimal, sim)
    CK = keytype(sim.enabled_events)      # CompetingClocks extends Base.keytype
    L = sim.likelihood_eltype
    p.recorder = _MinimalRecorder{CK,L}(Tuple{CK,Float64}[], L[], false, Set{Symbol}())
    return nothing
end

# on_prefire: identical sampler state to the trace evaluator's per-step gate.
on_prefire(p::RecordMinimal, sim, clock, event, when) =
    _rec_min_prefire(p.recorder, sim, clock, when)
# on_postfire: the firing is sealed, sim.fire_random reflects this firing, and
# sim.couplings_ran holds every re-evaluation coupling that ran up to here.
on_postfire(p::RecordMinimal, sim, clock, event, when, changed) =
    _rec_min_postfire(p.recorder, clock, when, sim.fire_random, sim.couplings_ran)

# Guards: a hook before on_preinit (impossible through run) is a silent no-op.
_rec_min_prefire(::Nothing, sim, clock, when) = nothing
_rec_min_postfire(::Nothing, clock, when, fr, couplings) = nothing

function _rec_min_prefire(r::_MinimalRecorder{CK,L}, sim, clock, when) where {CK,L}
    # Only accumulate when the sampler records step likelihoods; otherwise the
    # forward log-likelihood is simply unavailable and effect_check will say so.
    if sim.step_likelihood
        push!(r.forward_steploglik, steploglikelihood(sim.sampler, when, clock))
    end
    return nothing
end
function _rec_min_postfire(r::_MinimalRecorder{CK,L}, clock, when, fr::Bool,
                           couplings::Set{Symbol}) where {CK,L}
    push!(r.firings, (clock, when))
    r.fire_random |= fr
    # Track which couplings actually RAN (not a static scan) so the record can be
    # labeled with the coupling that produced it.
    union!(r.couplings, couplings)
    return nothing
end

function _require_recorder(p::RecordMinimal)
    r = p.recorder
    r === nothing && throw(ArgumentError(
        "this RecordMinimal has not observed a run; pass it as " *
        "`policy=RecordMinimal()` to SimulationFSM and run the simulation first"))
    return r
end

"""
    minimal_record(p::RecordMinimal; horizon=nothing) -> MinimalRecord

Project the pinned [`MinimalRecord`](@ref) schema out of a `RecordMinimal` policy
that has observed a forward run. `horizon` defaults to the last firing's time.
"""
function minimal_record(p::RecordMinimal; horizon::Union{Nothing,Real}=nothing)
    r = _require_recorder(p)
    h = _resolve_horizon(horizon, r.firings, 0.0)
    return MinimalRecord(p.initializer, copy(r.firings), h, _coupling_label(r.couplings),
        r.fire_random)
end

"""
    minimal_record(skel::TrajectorySkeleton; horizon=nothing, coupling=:redraw,
                   initializer=nothing, fire_random=false) -> MinimalRecord

Project a rich [`TrajectorySkeleton`](@ref) down to the pinned
[`MinimalRecord`](@ref) schema: the firing sequence is `(step.clock, step.when)`
for each recorded step. `horizon` defaults to the last step's time. The skeleton
carries no fire-randomness flag, so pass `fire_random` if known (a skeleton
recorded alongside the framework's detector can supply it). A `TrajectorySkeleton`
does not observe which re-evaluation couplings ran, so `coupling` is a caller-
supplied label; it defaults to `:redraw`, the same convention `RecordMinimal`
applies to a run in which no re-evaluation ran (guarantee G6).
"""
function minimal_record(
    skel::TrajectorySkeleton{CK}; horizon::Union{Nothing,Real}=nothing,
    coupling::Symbol=:redraw, initializer=nothing, fire_random::Bool=false,
) where {CK}
    firings = Tuple{CK,Float64}[(s.clock, s.when) for s in skel.steps]
    h = _resolve_horizon(horizon, firings, skel.init.when)
    return MinimalRecord{CK}(initializer, firings, h, coupling, fire_random)
end

"""
    forward_loglikelihood(p::RecordMinimal)

The forward-accumulated log-likelihood of the run `p` observed, summed with the
same `sum(...; init=zero(L))` reduction [`trace_likelihood`](@ref) uses. Requires
the sim to have been built with `step_likelihood=true`; otherwise no per-step
contributions were recorded and this returns `zero(L)`.
"""
function forward_loglikelihood(p::RecordMinimal)
    r = _require_recorder(p)
    L = eltype(r.forward_steploglik)
    return sum(r.forward_steploglik; init=zero(L))
end

########## trace_likelihood over a MinimalRecord (warns when fire-random)

function _warn_if_fire_random(rec::MinimalRecord)
    if rec.fire_random
        @warn "Consuming a fire-random MinimalRecord: at least one firing drew " *
            "randomness, so the recorded firing sequence is not a deterministic " *
            "function of the initial condition. A record-derived likelihood need " *
            "not correspond to the trajectory that produced it."
    end
    return nothing
end

"""
    trace_likelihood(sim, initializer, rec::MinimalRecord; params=nothing, censor=false)

Evaluate a [`MinimalRecord`](@ref) against `sim` (see the base
[`trace_likelihood`](@ref) for the trace convention and the `params=` θ seam).

The `params=` kwarg threads through to the θ seam (Milestone 2, G4): a
record-derived estimator replays the record at an explicit (possibly dual-valued)
parameter vector without re-instantiating global state.

The `censor=` kwarg opts into HORIZON-AWARE evaluation. A `MinimalRecord` carries
its own `horizon`; with `censor=true` the returned evaluation's `loglikelihood`
adds [`censoring_loglikelihood`](@ref)`(sim, rec.horizon)` -- the survival of every
still-enabled clock from the last firing to `horizon` -- so the trajectory scores
over the closed window `[0, horizon]` rather than ending at its last event. A score
estimator for a finite-horizon functional needs this term; without it the horizon
contribution is silently dropped. In `censor=true` mode `loglikelihood` is the
censored total and no longer equals `sum(steploglik)` (the tail is a survival term,
not a firing step); the other fields are unchanged, and an infeasible trace is not
censored (it stays `-Inf`).

Censoring is OPT-IN, not default-on, to keep symmetry with the M1 pure-replay
[`effect_check`](@ref): that check compares forward accumulation against replay, and
forward accumulation has no censoring term, so defaulting the horizon on here would
break the bit-for-bit equality the check relies on. The three G1 tiers -- the
`derivation_spec` declarations, the read-verification audit
([`with_read_verification`](@ref enable_read_verification!)), and this pure-replay check -- all read the same
record; horizon censoring is a scoring choice layered on top, never a change to what
replay reproduces.
"""
function trace_likelihood(sim::SimulationFSM, initializer::SimEvent, rec::MinimalRecord;
                          params=nothing, censor::Bool=false)
    _warn_if_fire_random(rec)
    ev = trace_likelihood(sim, initializer, _minimal_trace(rec); params=params)
    return censor ? _censor_evaluation(sim, ev, rec.horizon) : ev
end
function trace_likelihood(sim::SimulationFSM, initializer::Function, rec::MinimalRecord;
                          params=nothing, censor::Bool=false)
    _warn_if_fire_random(rec)
    ev = trace_likelihood(sim, initializer, _minimal_trace(rec); params=params)
    return censor ? _censor_evaluation(sim, ev, rec.horizon) : ev
end

# Fold the finite-horizon censoring tail into a feasible trace evaluation. The tail
# (survival of every still-enabled clock from the last firing to `horizon`) is a
# path-likelihood term, not a firing step, so it lands in `loglikelihood` while
# `steploglik` keeps the per-firing contributions. An infeasible evaluation is
# returned untouched: -Inf stays -Inf.
function _censor_evaluation(sim::SimulationFSM, ev::TraceEvaluation{L}, horizon) where {L}
    ev.feasible || return ev
    tail = censoring_loglikelihood(sim, horizon)
    return TraceEvaluation{L}(
        ev.loglikelihood + tail, ev.feasible, ev.steps_evaluated,
        ev.first_infeasible, ev.steploglik,
    )
end

########## The effect check

"""
    EffectCheckResult{L}

The outcome of [`effect_check`](@ref).

# Fields

  * `applicable::Bool` — `false` when the record is fire-random, in which case the
    pure-replay check does not apply and `passed` is meaningless.
  * `passed::Bool` — `true` when the replay log-likelihood equals the forward
    accumulation EXACTLY (`==`) and the check was applicable.
  * `forward::L` — the forward-accumulated log-likelihood.
  * `replay::L` — the log-likelihood from re-evaluating the record via
    [`trace_likelihood`](@ref).
  * `evaluation::TraceEvaluation{L}` — the full replay evaluation.
"""
struct EffectCheckResult{L<:Real}
    applicable::Bool
    passed::Bool
    forward::L
    replay::L
    evaluation::TraceEvaluation{L}
end

function Base.show(io::IO, r::EffectCheckResult)
    print(io, "EffectCheckResult(applicable=", r.applicable, ", passed=", r.passed,
        ", forward=", r.forward, ", replay=", r.replay, ")")
end

"""
    effect_check(sim_factory, initializer, p::RecordMinimal; horizon=nothing)
        -> EffectCheckResult

Re-evaluate the record produced by a forward run against a freshly built sim and
assert that the replay log-likelihood reproduces the forward accumulation
EXACTLY. `sim_factory()` must return a fresh [`SimulationFSM`](@ref) built with
`step_likelihood=true` and the same events/state as the forward run;
`initializer` is the same init `SimEvent` or init function `run` was given.

Returns an [`EffectCheckResult`](@ref) rather than throwing, so a caller can
inspect both numbers on failure. When the record is fire-random the check does
not apply: a warning is emitted and `applicable=false` is returned (the two
numbers are still reported for information).

This is the PURE-REPLAY tier of guarantee G1's three-tier defense (see the
`coverage.jl` module header). The first tier is the `derivation_spec` DECLARATIONS
the engine prunes by; the second is the DYNAMIC-CAPTURE audit
([`with_read_verification`](@ref enable_read_verification!)) that asserts, per evaluation, that every read is
declared; this third tier is the production check that forward accumulation and
replay agree to the last bit. The three are complementary: declarations are fast
and always on, read verification localizes an under-declaration to the offending
evaluation, and this exact-equality replay catches any residual incrementalization
drift in a whole trajectory's score.
"""
function effect_check(
    sim_factory::Function, initializer, p::RecordMinimal; horizon::Union{Nothing,Real}=nothing
)
    r = _require_recorder(p)
    if !isempty(r.firings) && isempty(r.forward_steploglik)
        throw(ArgumentError(
            "effect_check needs the forward run's log-likelihood, which is only " *
            "accumulated when the forward sim was built with step_likelihood=true"))
    end
    L = eltype(r.forward_steploglik)
    forward = sum(r.forward_steploglik; init=zero(L))
    rec = minimal_record(p; horizon=horizon)
    applicable = !rec.fire_random
    if !applicable
        @warn "effect_check: the record is fire-random (a firing drew randomness), " *
            "so the pure-replay effect check does not apply; returning applicable=false."
    end
    sim = sim_factory()
    sim.step_likelihood || throw(ArgumentError(
        "effect_check's sim_factory must build the sim with step_likelihood=true"))
    ev = trace_likelihood(sim, initializer, _minimal_trace(rec))
    replay = ev.loglikelihood
    passed = applicable && (replay == forward)
    return EffectCheckResult{L}(applicable, passed, forward, replay, ev)
end
