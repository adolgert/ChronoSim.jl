# Runbook

This runbook is the operational reference for ChronoSim's debugging and
verification features. It is written to be followed mechanically, by a human or
an AI agent, with no context beyond this repository. Each entry documents one
feature and gives, in order:

1. **How to invoke it** — the exact call or command.
2. **What its output looks like** — a captured example, copied verbatim from a
   real run.
3. **What each failure form means** — how to read a non-success result.
4. **How to turn it off** — every debugging feature is opt-in; this says what
   "off" is.

Entries are added as each phase of the debugging-and-verification plan lands.

---

## Evaluate a recorded trace

Given a recorded trajectory (a list of `(when, clock_key)` pairs) and a model,
`trace_likelihood` walks the trace against the model, computes the trajectory's
log-likelihood, and reports whether the trace is feasible under the model. It
never throws on an infeasible trace; it returns a
[`TraceEvaluation`](@ref) that says what went wrong.

### How to invoke it

The evaluator needs a sampler that records the enabled-clock set at each step.
Wrap any base sampler in a `CompetingClocks.MemorySampler`:

```julia
using ChronoSim
using CompetingClocks: CombinedNextReaction, MemorySampler
using Random: Xoshiro

# 1. Record a trace with a forward run. The observer stores (when, clock_key).
trace = Tuple{Float64,Tuple}[]
observer = (physical, when, event, changed) -> begin
    event isa ChronoSim.InitializeEvent && return nothing
    push!(trace, (when, clock_key(event)))
end
fsim = SimulationFSM(
    MyBoard(1), [MyEventA, MyEventB];
    rng=Xoshiro(424242),
    sampler=CombinedNextReaction{Tuple,Float64}(),
    observer=observer,
)
ChronoSim.run(fsim, my_init!, (p, i, e, w) -> i > 20)

# 2. Evaluate the trace on a *fresh* sim whose sampler records enabled clocks.
esim = SimulationFSM(
    MyBoard(1), [MyEventA, MyEventB];
    rng=Xoshiro(7),
    sampler=MemorySampler(CombinedNextReaction{Tuple,Float64}()),
)
ev = trace_likelihood(esim, my_init!, trace)
```

The `initializer` (`my_init!` above) is either an initialization function
`(physical, when, rng) -> nothing` or a `SimEvent` whose `fire!` sets up the
state. The `trace` is an `AbstractVector` of `(when::Float64, clock_key::Tuple)`
pairs.

### What its output looks like

`trace_likelihood` returns a `TraceEvaluation`. For a **feasible** trace, the
`text/plain` display (what the REPL prints) is:

```
TraceEvaluation
  feasible         : true
  loglikelihood    : -2.295205868713304
  steps evaluated  : 20
  first infeasible : none
```

For an **infeasible** trace — here, a trace whose step 17 names an event key
`(:FireA, 99)` that is not enabled at that point — the display names the first
failing step:

```
TraceEvaluation
  feasible         : false
  loglikelihood    : -Inf
  steps evaluated  : 16
  first infeasible : step 17, event (:FireA, 99), reason not_enabled
```

The one-line form (used when a `TraceEvaluation` is printed inside another
structure) is:

```
TraceEvaluation(feasible=false, loglikelihood=-Inf, steps_evaluated=16)
```

The fields are:

  * `ev.loglikelihood` — the trajectory's log-likelihood, or `-Inf` if
    infeasible.
  * `ev.feasible` — `true` if every step named an enabled event at a
    strictly-increasing time.
  * `ev.steps_evaluated` — how many steps were scored before evaluation stopped;
    equals `length(ev.steploglik)`.
  * `ev.first_infeasible` — `nothing` if feasible, else
    `(step, event, reason)` for the first failing step.
  * `ev.steploglik` — the per-step log-likelihood contributions.

### What each failure form means

A trace is infeasible when a step cannot happen under the model. `reason` is:

  * `:not_enabled` — the step named a `clock_key` that was **not in the enabled
    set** when its turn came. The event either was never enabled or had already
    been disabled/consumed. Evaluation stops; `steps_evaluated` is the number of
    steps that fired cleanly before it.
  * `:time_order` — the step's `when` was **not strictly greater** than the
    previous event's time (`sim.when`). Times in a trace must strictly increase.
    An equal or earlier time is a `:time_order` failure.

`:not_enabled` is checked before `:time_order`: if both fail, the missing
enablement is the reported reason (the time comparison is only meaningful for a
step that could fire at all).

A separate, non-failure case: a trace entry with a **non-finite `when`** (e.g.
`Inf`) or a `nothing` key ends evaluation early *without* marking the trace
infeasible — `feasible` stays `true`, mirroring a forward run that exhausts its
events. This is the trace's normal end-of-data sentinel, not an error.

If `trace_likelihood` throws an `ArgumentError` reading
`trace_likelihood needs a sampler that records enabled clocks`, the evaluation
sampler was not wrapped in a `MemorySampler`. Wrap it as shown above.

### How to turn it off

There is nothing to turn off. Trace evaluation is a separate entry point
(`trace_likelihood`) that you call explicitly; it does not run during a normal
`run` and adds no cost to a production simulation. The only requirement is the
`MemorySampler` wrapper on the evaluation sim's sampler.
