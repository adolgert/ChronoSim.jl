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

---

## Replay a recorded run

`replay` re-executes a [`TrajectorySkeleton`](@ref) bit-for-bit and returns the
live simulation for inspection. It restores the skeleton's pre-init RNG state,
re-runs through the same executor kernel `run` uses, and checks the fired
`(clock_key, when)` against the recording at every step — at the exact code
point where `run` evaluates its stop condition, so the random stream is
reproduced identically. `upto=k` stops after step `k` (so you can inspect the
state the original run had after its k-th event); `probes` observe each step
without perturbing it. It is opt-in: forward runs are untouched.

### How to invoke it

Record a run (see "Record a trajectory skeleton"), then hand `replay` a
*factory* that rebuilds the simulation with the SAME constructor arguments and
passes through the policy `replay` gives it. `run` and `replay` are not
exported; call `ChronoSim.run` / `replay` (the latter is exported):

```julia
using ChronoSim
using CompetingClocks: CombinedNextReaction
using Random: Xoshiro

# 1. Record.
rec = RecordSkeleton(metadata=(model="sirvillage", N=30, seed=2938423))
rng = Xoshiro(2938423)
physical = Village(30, 10, 1.0, rng)                 # ctor consumes rng
sim = SimulationFSM(physical, EVENTS; rng=rng, policy=rec)
ChronoSim.run(sim, InitEvent(), (p, i, e, w) -> w > 1.0)
skel = recorded_skeleton(rec)

# 2. Replay to step 200 and inspect the live state.
sim = replay(skel; upto=200) do policy
    rng = Xoshiro(2938423)                           # SAME ctor args as recorded
    physical = Village(30, 10, 1.0, rng)
    (SimulationFSM(physical, EVENTS; rng=rng, policy=policy), InitEvent())
end
sim.physical.actors[7].state                         # poke at the state
```

The factory is called as `factory(policy)` and must return
`(sim, initializer)`: a fresh `SimulationFSM` built with the given `policy`
passed through (`SimulationFSM(...; policy=policy)`) and the same initializer (a
`SimEvent` or an init function) given to `run`. Any `seed`/`rng` the factory
sets is overwritten — `replay` restores `skel.rng_state`, so the re-run consumes
the identical random stream. Model identification (constructor arguments, git
SHA) belongs in `skel.metadata` at record time; reproducing the constructor is
the caller's responsibility.

Watch an address across the whole run with a probe — a tuple of functions each
called `probe(sim, step, phase, event, when)`, with `phase` one of `:init`,
`:prefire`, `:postfire`:

```julia
vals = Tuple{Int,Any}[]
watch(sim, step, phase, event, when) =
    phase === :postfire && push!(vals, (step, sim.physical.actors[7].state))
replay(factory, skel; probes=(watch,))
```

`ProbePolicy` is usable directly on a forward run too:
`SimulationFSM(...; policy=ProbePolicy((watch,)))`.

### What its output looks like

`replay` returns the live `SimulationFSM`, positioned at the requested step. A
`:postfire` probe that records each step's fired-event name over the first five
steps of the sirvillage replay above prints:

```
  (1, :Travel)
  (2, :Travel)
  (3, :Travel)
  (4, :Travel)
  (5, :Travel)
```

A recorded 1,000-step sirvillage run replays in the same order of magnitude as
the original forward run (the replay hot path adds only a tuple compare and one
policy dispatch per step): original `0.115 s`, replay `0.113 s` for a
1,270-step run.

### What each failure form means

  * `ReplayDivergence at step k` — the rebuilt simulation fired a different
    `(clock_key, when)` than the skeleton recorded. Replay is exact (no
    tolerance), so any divergence means the re-run is not the recorded run:
    different constructor arguments, a different package/Julia version, or model
    code drawing randomness from outside `sim.rng`. The message names the
    expected and actual event; when only the time differs it prints
    `time differs by …`. An `actual : (no event; sampler exhausted before this
    step)` means the re-run ran out of events early — again a determinism break.
  * `ArgumentError: sim_factory must pass the policy it is given` — the factory
    dropped the `policy` argument. Pass `policy=policy` to `SimulationFSM`.
  * `ArgumentError: upto=… is outside this skeleton's 0:N steps` — `upto` was
    negative or larger than the recorded step count.
  * `ArgumentError: sim_factory(policy) must return (sim, initializer)` — the
    factory returned something other than the required 2-tuple.

### How to turn it off

There is nothing running to turn off. `replay` is a separate entry point you
call explicitly; a forward `run` without a `ProbePolicy` executes the identical
instructions it did before this feature existed.

---

## Explain a precondition clause by clause

`guard_clauses` evaluates a derived event's `@precondition` body one conjunct at
a time against live state, without `eval`, and returns a
`Vector{Tuple{String,Any}}` of `(source_text, value)` pairs — the ingredient for
saying *which* guard rejected a proposed event. It reads state and never mutates
it. It works only on events defined with `@precondition` (the derivable
fragment); hand-written `@conditionsfor` events are not registered and raise a
[`GuardEvalError`](@ref).

### How to invoke it

Call it with an event instance and the physical state (typically a state you
reached with `replay(...; upto=k)`):

```julia
using ChronoSim

guard_clauses(OpenElevatorDoors(1), system)
```

There is also a type-first method,
`guard_clauses(EvtType, evt, physical; mod=parentmodule(EvtType))`; pass `mod=`
only if the event type's parent module is not where its `@precondition` was
expanded.

### What its output looks like

Each entry is one top-level `&&` conjunct of the precondition, in source order
(a top-level `||` is a single clause). For a freshly built elevator system
(stationary, no calls requested, no buttons pressed), `OpenElevatorDoors(1)` is
rejected on its second clause:

```
  ("!(elevator.doors_open)", true)
  ("call_exists || button_pressed", false)
```

For a replayed sirvillage state, an `Infect(1, 2)` proposed between two actors
who are not a valid infectious→susceptible co-located pair reports which guards
fail:

```
  ("source_state == Infectious", true)
  ("sink_state == Susceptible", false)
  ("source_loc == sink_loc", false)
```

Read the real precondition's verdict as **the first non-`true` value in source
order**: `false` ⇒ the precondition is rejected there; all `true` ⇒ accepted; an
exception value *before* any `false` ⇒ the real precondition would itself throw
on this state. A clause value that is an exception object (e.g. a `KeyError`)
means that clause's read failed — and if an earlier clause is already `false`,
the real short-circuiting precondition never reached it, so the exception is an
artifact of independent evaluation, not a bug. Every clause is evaluated
independently (from a fresh copy of the post-prelude environment), which is why
you get a value for every clause even after one is `false`.

### What each failure form means

`guard_clauses` throws a [`GuardEvalError`](@ref) (never a silent degradation)
whose `kind` names the problem:

  * `:no_precondition` — the event has no `@precondition` (it uses hand-written
    `@conditionsfor` generators, or is unregistered). `guard_clauses` needs a
    `@precondition` event. For a hand-written event, use the precondition's
    boolean and `capture_state_reads` instead.
  * `:unsupported_call` / `:unsupported_node` — the precondition uses a
    construct outside the interpreter's fragment (the error names it and its
    source text). The derivable fragment is the same one `@precondition` accepts;
    an opaque call like `sqrt(2.0)` (state-free, so the macro tolerates it) is
    the one construct the interpreter refuses.
  * `:mutating_call` — the precondition calls `get!`, which would insert a
    default into live state; guard evaluation is read-only.
  * `:early_return` — a `return` sits inside a branch or loop; the fragment must
    be a straight-line prelude followed by one returned expression.
  * `:prelude_threw` — a statement before the returned expression threw (the
    error carries the offending source and the causing exception). The real
    precondition throws on this state too.

### How to turn it off

There is nothing to turn off. `guard_clauses` is a diagnostic verb you call
explicitly; it never runs during `run` and adds no cost to a simulation.
