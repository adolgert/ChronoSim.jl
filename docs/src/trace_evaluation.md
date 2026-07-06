# Evaluating a trace against a model

A trajectory is just a list of `(when, clock_key)` pairs — a recording of which
event fired, and at what time. Once you have one, a natural question is: *how
likely is this trajectory under my model?* [`trace_likelihood`](@ref) answers
it. It walks a recorded trace against a model, scores each step's contribution to
the trajectory's log-likelihood, and reports whether the trace is even
*feasible* — whether every step named an event the model had enabled at a
strictly-increasing time. It never throws on a bad trace; it returns a
[`TraceEvaluation`](@ref) that says what went wrong and where. The
[runbook entry](@ref "Evaluate a recorded trace") is the terse reference; this
page is the narrative.

## When you would reach for it

Three situations bring a modeler here:

* **Likelihood of an observed trajectory.** You have field data — an observed
  sequence of events with timestamps — and a candidate model. `trace_likelihood`
  gives you `log P(trajectory | model)`, the ingredient for inference.
* **Model comparison.** Score the same observed trace under two models and
  compare their log-likelihoods; the larger number is the trajectory the model
  found less surprising.
* **Feasibility checking.** Before you trust a likelihood, you need to know the
  trace is a legal path at all. A trace produced by a *different* model — or a
  hand-edited one — may name an event the model never enabled. `trace_likelihood`
  catches that as an infeasible verdict rather than silently returning a number.

## The MemorySampler requirement

Scoring a step means asking the model *which clocks were enabled, with what
distributions, at this instant* — the competing-clock set. A plain sampler does
not keep that set queryable after the fact, so the evaluation simulation's
sampler must be wrapped in a `CompetingClocks.MemorySampler`. This is the one
setup rule; forget it and `trace_likelihood` throws an `ArgumentError` reading
*"trace_likelihood needs a sampler that records enabled clocks"*. The
`MemorySampler` is only needed on the **evaluation** sim — the run that produced
the trace can use any sampler.

## A worked example: the two-clock race

The cleanest model to build intuition on is a competing exponential race, because
its likelihood has a closed form you can check by hand. Two clocks, `FireA` and
`FireB`, are perpetually enabled (their preconditions are trivially true); each
firing bumps its own field, which re-proposes it through its derived generator,
so the survivor keeps racing. `FireA` has rate `LA = 2.0`, `FireB` has rate
`LB = 3.0`.

```julia
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks: CombinedNextReaction, MemorySampler
using Distributions
using Random: Xoshiro
import ChronoSim: precondition, generators, enable, fire!

module Race
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

const LA = 2.0
const LB = 3.0

@keyedby RaceCell Int64 begin
    a::Int64
    b::Int64
end

@observedphysical RaceBoard begin
    cell::ObservedVector{RaceCell,Member}
end

function RaceBoard(n::Int)
    cells = ObservedArray{RaceCell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = RaceCell(0, 0)
    end
    return RaceBoard(cells)
end

struct FireA <: SimEvent
    idx::Int64
end
@precondition precondition(evt::FireA, state) = state.cell[evt.idx].a >= 0
enable(::FireA, state, when) = (Exponential(1 / LA), when)
fire!(evt::FireA, state, when, rng) = (state.cell[evt.idx].a += 1; nothing)

struct FireB <: SimEvent
    idx::Int64
end
@precondition precondition(evt::FireB, state) = state.cell[evt.idx].b >= 0
enable(::FireB, state, when) = (Exponential(1 / LB), when)
fire!(evt::FireB, state, when, rng) = (state.cell[evt.idx].b += 1; nothing)

function init!(state, when, rng)
    state.cell[1].a = 0
    state.cell[1].b = 0
    return nothing
end
end # module

using .Race: RaceBoard, FireA, FireB, LA, LB

# 1. Record a forward trace. The observer stores (when, clock_key).
trace = Tuple{Float64,Tuple}[]
observer = (physical, when, event, changed) -> begin
    event isa ChronoSim.InitializeEvent && return nothing
    push!(trace, (when, clock_key(event)))
end
fsim = SimulationFSM(RaceBoard(1), [FireA, FireB];
    rng=Xoshiro(424242),
    sampler=CombinedNextReaction{Tuple,Float64}(),
    observer=observer)
ChronoSim.run(fsim, Race.init!, (p, i, e, w) -> i > 20)

# 2. Evaluate on a *fresh* sim whose sampler records enabled clocks.
esim = SimulationFSM(RaceBoard(1), [FireA, FireB];
    rng=Xoshiro(7), sampler=MemorySampler(CombinedNextReaction{Tuple,Float64}()))
ev = trace_likelihood(esim, Race.init!, trace)
```

The `initializer` (`Race.init!`) is either an init function
`(physical, when, rng) -> nothing` or a `SimEvent` whose `fire!` sets up the
state — exactly what you would hand `ChronoSim.run`. The `trace` is any
`AbstractVector` of `(when::Float64, clock_key::Tuple)` pairs.

## Reading a feasible verdict

`ev` displays as:

```
TraceEvaluation
  feasible         : true
  loglikelihood    : -2.295205868713304
  steps evaluated  : 20
  first infeasible : none
```

* **`feasible : true`** — every one of the 20 steps named an enabled event at a
  strictly-increasing time. This is the precondition for trusting the number
  above it.
* **`loglikelihood : -2.295…`** — the trajectory's log-likelihood under the
  model. On its own it is only meaningful *relative* to another model's score for
  the same trace; that is what makes it a model-comparison tool.
* **`steps evaluated : 20`** — how many steps were scored. For a feasible trace
  this equals the trace length; for an infeasible one it is the count of steps
  that scored cleanly before evaluation stopped. It always equals
  `length(ev.steploglik)`, and `sum(ev.steploglik)` equals `ev.loglikelihood`.
* **`first infeasible : none`** — no failing step. On an infeasible trace this
  line names the culprit instead.

## Checking the number by hand

The two-clock race is worth its keep because the likelihood is analytic. In a
competing exponential race where both clocks stay enabled, each inter-event gap
`Δt` contributes the winner's density times the loser's survival —
`λ_win · e^{-λ_win Δt} · e^{-λ_lose Δt} = λ_win · e^{-(λA+λB) Δt}` — and
memorylessness means nothing carries across firings. Multiply over all steps and
the survival exponents telescope to the final time `tN`:

```math
\log L = n_A \log \lambda_A + n_B \log \lambda_B - (\lambda_A + \lambda_B)\, t_N
```

This recorded trace fired `FireA` 10 times and `FireB` 10 times, ending at
`tN = 4.042560112198771`. So:

```julia
na, nb, tN = 10, 10, 4.042560112198771
na*log(LA) + nb*log(LB) - (LA + LB)*tN   # = -2.2952058687133032
```

which matches `ev.loglikelihood = -2.295205868713304` to floating-point
tolerance — the evaluator's per-step scoring reproduces the closed form. A tiny
fixed trace makes the arithmetic fully manual:

```julia
fixed = Tuple{Float64,Tuple}[(0.3, (:FireA, 1)), (0.7, (:FireB, 1)), (1.1, (:FireA, 1))]
trace_likelihood(esim, Race.init!, fixed).loglikelihood   # = -3.015093350212
```

Two `FireA` and one `FireB` ending at `t = 1.1` give
`2 log 2 + log 3 − 5·1.1 = -3.0150933502119996`. The evaluator agrees.

## Reading an infeasible verdict

Corrupt step 17 to name a clock the model never enabled — `(:FireA, 99)`, an
index with no cell:

```julia
bad = copy(trace)
bad[17] = (bad[17][1], (:FireA, 99))
trace_likelihood(esim, Race.init!, bad)
```

```
TraceEvaluation
  feasible         : false
  loglikelihood    : -Inf
  steps evaluated  : 16
  first infeasible : step 17, event (:FireA, 99), reason not_enabled
```

The verdict flips: `feasible : false`, the likelihood collapses to `-Inf`, and
`steps evaluated : 16` says the first sixteen steps scored cleanly before step 17
named an event that was not in the enabled set. The `first infeasible` line — the
same data as `ev.first_infeasible == (17, (:FireA, 99), :not_enabled)` — points
you straight at the offending step. Inside a larger structure the same value
prints on one line: `TraceEvaluation(feasible=false, loglikelihood=-Inf,
steps_evaluated=16)`.

## Failure forms

A trace is *infeasible* when a step cannot happen under the model. `reason` is
one of two symbols:

* **`:not_enabled`** — the step named a `clock_key` that was **not enabled** when
  its turn came: the event was never enabled, or had already been disabled or
  consumed. This is the verdict for a trace produced by a different model, or a
  hand-edit like the `(:FireA, 99)` above.
* **`:time_order`** — the step's `when` was **not strictly greater** than the
  previous event's time. Trace times must strictly increase; an equal or earlier
  time is a `:time_order` failure.

`:not_enabled` is checked first: if both fail, the missing enablement is reported
(the time comparison only means something for a step that could fire at all).

Two non-failure endings are worth knowing:

* A trace entry with a **non-finite `when`** (e.g. `Inf`) or a `nothing` key ends
  evaluation early *without* marking the trace infeasible — `feasible` stays
  `true`. This is the trace's normal end-of-data sentinel, mirroring a forward
  run that exhausts its events.
* An **empty trace** is feasible with `loglikelihood = 0.0` and zero steps.

And the one setup error: an `ArgumentError` reading *"trace_likelihood needs a
sampler that records enabled clocks"* means the evaluation sim's sampler was not
wrapped in a `MemorySampler`. Wrap it as shown above.

## What to do with the answer

* An **infeasible** verdict on a trace your own model produced is a red flag:
  either the trace came from a different model version, or the evaluation sim was
  built differently from the recording sim. Line the two constructions up.
* A **feasible** likelihood is the number you compare across models. Score the
  same observed trace under each candidate; the least-negative wins.
* Feasibility is also a cheap conformance check: run a trajectory recorded from
  model *A* through model *B*'s evaluator, and an infeasible step localizes the
  first place the two models disagree about what is enabled.

## Related

* [Runbook: Evaluate a recorded trace](@ref "Evaluate a recorded trace") — the
  mechanical reference and field list.
* [Recording and replaying a run](@ref "Recording and replaying a run") —
  produces the richer [`TrajectorySkeleton`](@ref) when you need enable/disable
  history, not just `(when, clock_key)` pairs.
* [Model checking a simulation](@ref "Model checking a simulation") — a
  discrete, exhaustive check of a recorded trace against a compiled spec, the
  qualitative counterpart to this quantitative one.
* [Debugging & Verification](@ref) — the overview and symptom-to-technique table.
