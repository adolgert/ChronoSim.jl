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

---

## Check model invariants every step

[`@invariant`](@ref) declares named boolean safety properties of the physical
state; the [`CheckInvariants`](@ref) policy evaluates all of a module's
invariants after initialization and after every fired event, and throws a
structured [`InvariantViolation`](@ref) on the first failure — naming the
invariant, the firing event, and the addresses this fire wrote that the
invariant reads (the *guilty* addresses). Checking is opt-in and debug/test-tier:
zero cost when the policy is absent.

### How to invoke it

Declare invariants at the model module's top level, then pass
`policy=CheckInvariants(MyModel)` to `SimulationFSM` (`run` is not exported; call
it as `ChronoSim.run`). Compose with a [`RecordSkeleton`](@ref) — recorder first
— so the violation carries a replayable prefix:

```julia
using ChronoSim

# In the model module, at top level:
@invariant "person location xor elevator" function (physical)
    all((p.location > 0 && p.elevator == 0) || (p.location == 0 && p.elevator > 0)
        for p in physical.person)
end

# At run time:
rec = RecordSkeleton()
sim = SimulationFSM(physical, events; seed=42,
    policy=PolicyStack(rec, CheckInvariants(MyModel)))
ChronoSim.run(sim, InitEvent(), (p, i, e, w) -> w > 120.0)
```

Prefer one `@invariant` per logical clause: on violation the failing *name* is
the first diagnostic. An invariant must be a pure boolean function of `physical`
— one argument, no mutation, no randomness — because the checker re-evaluates it
on the failure path to recover the read set.

### What its output looks like

`showerror` on the thrown `InvariantViolation`, captured verbatim from an
elevator run under a test-local corruption event that sets a person's elevator
while leaving their floor nonzero:

```
InvariantViolation: invariant "person location xor elevator" is false
  model    : ChronoSimExamples.ElevatorExample
  declared : /Users/adolgert/dev/ChronoSimExamples.jl/src/elevator/elevator.jl:258
  step     : 95 (fires since init)
  event    : (:CorruptPerson,)
  when     : 85.79201980830436
  guilty   : 1 address(es) written by this fire AND read by the invariant
    (person, 1, elevator)
  reads    : 2 address(es) in the failing evaluation
    (person, 1, location)
    (person, 1, elevator)
  replay   : replay(sim_factory, skeleton; upto=94)   # reproduces the state one step before the violation
The invariant held after the previous step; the writes above broke it.
```

The `replay` line is the exact [`replay`](@ref) call that reconstructs the state
one step before the break; feed it the skeleton (`recorded_skeleton(rec)`) and a
factory that rebuilds the sim with the same constructor arguments.

### What each failure form means

  * `step : 0` — the initializer itself violated the invariant; fix init, not an
    event. `replay` reads `n/a` (re-run the initializer to reproduce the state).
  * `guilty : none identified` — no address this fire wrote is read by the
    invariant. The invariant reads state the tracker cannot see (e.g.
    `Param`-wrapped fields), or the corruption predates this step; use the
    `replay` command and step forward.
  * `WARNING : ... not a pure function` — re-evaluation under read capture
    returned `true`: the invariant gave different answers on the same state.
    Make it a pure function of `physical`.
  * `replay : no skeleton recorded` — no `RecordSkeleton` shared the policy
    stack. Compose `PolicyStack(RecordSkeleton(), CheckInvariants(MyModel))` to
    capture a replayable prefix.
  * `ArgumentError: no @invariant is registered for this module` — the module
    has no declarations, or was not loaded before the policy was constructed.
  * `@invariant "name" ... returned <T>, not Bool` — an invariant body returned a
    non-`Bool`; an invariant must be a boolean function of the physical state.

### How to turn it off

Construct `SimulationFSM` without the policy (the default `NoPolicy` checks
nothing and costs nothing), or leave a [`PolicyStack`](@ref) empty. In the
examples' entry points, `run_elevator()` / `run_sirvillage()` check only when
passed `policy=CheckInvariants(...)`; the test suites pass it, production callers
do not.

---

## Ask why an event did not fire

[`whynot`](@ref) takes a recorded [`TrajectorySkeleton`](@ref), a `sim_factory`
(the [`replay`](@ref) contract), and an event instance, and explains the event's
absence at the *furthest lifecycle stage it reached*: `:never_proposed`,
`:rejected`, `:enabled_never_fired`, or `:fired`. It returns a
[`WhynotReport`](@ref) whose `show` is a bounded (≤ 30 line) readout.

### How to invoke it

```julia
using ChronoSim

# 1. Record the run whose missing event you want to explain.
rec = RecordSkeleton()
sim = SimulationFSM(physical, EVENTS;
    sampler=CombinedNextReaction{Tuple,Float64}(), rng=Xoshiro(seed), policy=rec)
ChronoSim.run(sim, init_physical, stop)
skel = recorded_skeleton(rec)

# 2. A factory that rebuilds the same sim (rng is overwritten by replay).
factory = policy -> (SimulationFSM(physical_ctor_args..., EVENTS;
    sampler=CombinedNextReaction{Tuple,Float64}(), rng=Xoshiro(seed), policy=policy),
    init_physical)

# 3. Ask.
rep = whynot(skel, factory, StopElevator(2))
```

### What its output looks like

The `:never_proposed` readout — the historical `StopElevator` missing-trigger
bug (the hand-written trigger set omits `direction`, so dispatching an elevator
already at a boundary floor never proposes the stop):

```
whynot (:StopElevator, 2): NEVER PROPOSED over 4 recorded steps
  declared triggers (hand_written):
    (elevator, _index, floor) | (elevator, _index, doors_open)
  fired-event triggers : none
  precondition at final replayed state : true
    !! the precondition holds now, yet the event was never proposed:
    !! a trigger for one of the MISSING addresses below is required
  precondition reads (true trigger set) :
    (elevator, 2, direction) | (elevator, 2, floor) | (elevator, 2, buttons_pressed)
    (elevator, 2, doors_open)
  MISSING triggers (reads no declared trigger covers) :
    (elevator, 2, direction) | (elevator, 2, buttons_pressed)
  near-miss writes (same container, different index/leaf) : 2 total
    step 4 (:DispatchElevator, 3, Up) wrote (elevator, 1, direction)  [container_near_miss]
    step 4 (:DispatchElevator, 3, Up) wrote (elevator, 1, floor)  [index_near_miss]
  note: trigger-set analysis is one precondition evaluation at the final replayed state; short-circuited reads may be missing. fired() triggers (if any) can cover reads without a place trigger. Full per-claus…
```

Address lists print packed (`addr | addr | addr`), capped per section with an
explicit `... and N more` overflow line, so the whole readout stays within 30
lines even for wide trigger sets. A `!! N recorded write(s) exactly matched a
declared trigger ...` line, if present, is an anomaly: a write matched a
declared trigger yet nothing proposed the event — report it as a framework bug.

The `:rejected` readout — `OpenElevatorDoors` proposed 57 times, always failing
the same conjunct because the boarding person pressed no button and no call was
requested:

```
whynot (:OpenElevatorDoors, 2): PROPOSED BUT REJECTED over 113 recorded steps
  proposals : 57, all rejected (steps 2, 3, 4, 5, 6, 8 ...)
  examined  : 6 replayed case(s); showing first and last
  -- rejection at step 2, t=0.5439169374413173 --
  failing clause : call_exists || button_pressed
  clauses : !(elevator.doors_open) = true | call_exists || button_pressed = false
  reads (whole precondition evaluation):
    (elevator, 2, direction) = Stationary | writer: none
    (elevator, 2, floor) = 1 | writer: none
    (elevator, 2, buttons_pressed) = Set{Int64}() | writer: none
    (elevator, 2, doors_open) = false | writer: none
  -- rejection at step 112, t=59.211385790742284 --
  ...
```

### What each failure form means

  * `stage = :fired` — the premise was wrong; the event did fire. The readout
    lists when.
  * `ReplayDivergence` (raised by the internal `replay`) — the factory does not
    rebuild the recorded run (different constructor args, package versions, or
    randomness outside `sim.rng`). See the replay entry.
  * `GuardEvalError` never escapes: for a hand-written (non-`@precondition`)
    event, stage `:rejected` falls back to whole-precondition analysis
    (`clause_analysis = :whole_precondition`) instead of per-clause values.
  * A `near-miss` line with class `:index_near_miss` (same container/leaf,
    different index) or `:container_near_miss` (same container, different leaf)
    is the write that *should* have been a trigger — the missed-trigger diagnostic.

### How to turn it off

`whynot` is a diagnostic function; there is nothing to turn off — just do not
call it. It runs entirely offline on a finished skeleton and never touches a
live run.

---

## Ask why the run has not stopped

[`whyrunning`](@ref) evaluates a stop predicate on the current state inside read
capture and reports every address it read, that address's value and last writer,
plus a recurrence summary of the last `nsteps` recorded steps — the dominant
event types, the addresses they rewrite, and whether any of them is an address
the predicate reads. It returns a [`WhyrunningReport`](@ref).

### How to invoke it

`sim` must be at the skeleton's final state — the recording sim after `run`, or
`replay(factory, skel)`:

```julia
rep = whyrunning(sim, skel, physical -> physical.next_strain_id > 10)
```

The predicate is called as `stop_predicate(physical)` when that method exists,
else as `stop_predicate(physical, step, clock, when)` (the `run` stop-condition
form).

### What its output looks like

A sirvillage run whose stop predicate reads `next_strain_id` — a counter that
`Mutate` would advance, but `Mutate` was excluded, so nothing in the step window
touches it:

```
whyrunning over window 2160:2209; stop predicate is false
  predicate reads:
    (next_strain_id,) = 4 | writer: init
  recurrence over steps 2160:2209:
    Travel  50 | writes (locations, _index, individual_cnt), (actors, _index, haunt) | predicate: untouched
  predicate reads written in this window : none
  reachability analysis requires effect analysis (not yet run)
```

The last line is a Phase-2 stub: the static "no event can ever write what the
predicate reads" verdict needs effect analysis, which is not yet built. Until
then the report says only that nothing wrote those addresses *recently*.

### What each failure form means

  * `ArgumentError: sim.when = ... but the skeleton's last step is at ...` — the
    sim is not at the skeleton's final state. Replay it fully first
    (`replay(factory, skel)`) or pass the recording sim straight from `run`.
  * `error: the stop predicate returned <T>, not Bool` — the predicate must
    return `Bool`.
  * `predicate reads written in this window : none` — nothing the predicate
    looks at changed in the last `nsteps` steps: a strong hint the run is stuck
    on state the stop condition cannot see.

### How to turn it off

Diagnostic only; do not call it. It performs one predicate evaluation (the same
cost the stop condition already pays each step) and single passes over the
window.

---

## Read out why the run stopped

[`whystopped`](@ref) has two methods. Given an [`InvariantViolation`](@ref)
caught from a [`CheckInvariants`](@ref) run, it prints the forensic readout: the
invariant, the breaking event, each guilty address with its last and prior
writers, and the exact `replay(...)` command. Given a plain
[`TrajectorySkeleton`](@ref), it reads out a normal ending — the final step and
whether clocks were still enabled (stopped by the stop condition) or none were
(the sampler exhausted). Both return a [`WhystoppedReport`](@ref).

### How to invoke it

Compose the recorder **before** the checker so the violation carries a replayable
prefix (order matters):

```julia
rec = RecordSkeleton()
sim = SimulationFSM(physical, EVENTS;
    policy=PolicyStack(rec, CheckInvariants(MyModel)),
    sampler=CombinedNextReaction{Tuple,Float64}(), rng=Xoshiro(seed))
err = try
    ChronoSim.run(sim, init_physical, stop); nothing
catch e; e end

rep = whystopped(err)                        # violation forensics
# or, for a run that ended without an exception:
rep = whystopped(recorded_skeleton(rec))     # end-of-run readout
```

### What its output looks like

A seeded corruption that sets `person[1].elevator` while `location` is nonzero,
breaking the xor invariant — `whystopped` names the guilty writer event:

```
whystopped: invariant "person location xor elevator" is false
  step   : 1 (fires since init)
  event  : (:CorruptPerson,)
  when   : 0.00461990380084346
  guilty : 1 address(es)
    (person, 1, elevator)
      last writer  : step 1 (:CorruptPerson,) t=0.00461990380084346
      prior writer : init
  replay : replay(sim_factory, skeleton; upto=0)
```

The end-of-run readout for a run stopped by its stop condition with clocks still
live:

```
whystopped: the run ended without an exception
  steps  : 2209
  last event : (:Travel, 14)
  when   : 1.9999360141028282
  60 clock(s) were still enabled; the run ended by its stop condition
    (:Recover, 1)
    ...
  replay : replay(sim_factory, skeleton)
```

### What each failure form means

  * `last writer : none` — no skeleton was recorded in the violation (no
    `RecordSkeleton` in the stack). Compose the recorder to capture writers.
  * `guilty : 0 address(es)` — inherited from the violation: no address this
    fire wrote is read by the invariant (untracked reads, or corruption that
    predates the step).
  * `verdict :no_events_enabled` (end-of-run) — the sampler exhausted; nothing
    was enabled when the run ended. `:stopped_while_events_enabled` — the stop
    condition ended a run that still had live clocks.

### How to turn it off

Diagnostic only. The violation method reads the exception the checker already
built; the skeleton method reads a finished skeleton. Neither touches a live run.
