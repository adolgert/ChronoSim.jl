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

---

## Record a trajectory skeleton

The `RecordSkeleton` policy captures a replayable record of a run — the
pre-initialization RNG state and, per fired event, its clock key, firing time,
changed addresses, and enable/disable/proposal history. It is opt-in: a
simulation constructed without the policy records nothing and pays nothing.
Retrieve the result with [`recorded_skeleton`](@ref) and, optionally, persist it
with [`save_skeleton`](@ref) / [`load_skeleton`](@ref).

### How to invoke it

Pass `policy=RecordSkeleton()` to `SimulationFSM` and read the skeleton back
after `run` returns (`run` is not exported; call it as `ChronoSim.run`):

```julia
using ChronoSim

rec = RecordSkeleton(metadata=(model="sirvillage", N=30, seed=2938423))
sim = SimulationFSM(physical, events; seed=2938423, policy=rec)
ChronoSim.run(sim, InitEvent(), (p, i, e, w) -> w > 15.0)
skel = recorded_skeleton(rec)
save_skeleton("smoke.skel", skel)
```

`metadata` is stored opaquely in the skeleton and is never read by the
framework; put model identification (module, constructor arguments, git SHA)
there. The policy only observes — it never draws from the RNG and never mutates
state — so a recorded run's trajectory is identical to the same-seed run
unrecorded.

### What its output looks like

`show(stdout, MIME"text/plain"(), skel)` prints a five-line summary. Captured
verbatim from the sirvillage smoke run above:

```
TrajectorySkeleton
  clock key  : Tuple{Symbol, Vararg{Int64}}
  steps      : 16003
  time span  : 0.0 -> 14.998863194116215
  top events : Travel 15917 | Recover 36 | Infect 33 | Reset 15 | Mutate 2
```

The one-line form (used when a skeleton is printed inside another structure) is:

```
TrajectorySkeleton(16003 steps, t=0.0..14.998863194116215)
```

The recorded fields are `skel.rng_state` (a copy of the RNG taken before the
initializer ran), `skel.metadata` (the opaque value above), `skel.init` (the
initialization record: `when`, `changed`, `enabled`, `disabled`, `proposed`),
and `skel.steps` (one `SkeletonStep` per fired event, in firing order, each with
`clock`, `when`, `changed`, `enabled`, `disabled`, `proposed`).

### What each failure form means

  * `ArgumentError: this RecordSkeleton has not observed a run` — you called
    `recorded_skeleton` before `run`. Pass the policy to `SimulationFSM` and run
    the simulation first.
  * `load_skeleton` throws a deserialization or `TypeError` — the file was
    written under a different Julia or package version (the `Serialization`
    format is version-bound), or is not a skeleton file. Re-record; do not
    archive `.skel` files across upgrades.
  * Steps look truncated after a second `run` on the same sim —
    re-initializing discards the previous recording. Save the skeleton before
    re-running.

### How to turn it off

Construct `SimulationFSM` without the `policy` keyword. The default `NoPolicy`
records nothing and adds zero time and zero allocation: every hook, including
the once-per-run `on_preinit` that snapshots the RNG, compiles to `return
nothing`.
