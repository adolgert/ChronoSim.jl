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

Entries are added as each debugging-and-verification feature lands. For the
narrative behind each feature — when to reach for it and how to read its
answer — see the [overview](@ref "Debugging & Verification") and its linked
guides.

---

## Evaluate a recorded trace

Given a recorded trajectory (a list of `(when, clock_key)` pairs) and a model,
`trace_likelihood` walks the trace against the model, computes the trajectory's
log-likelihood, and reports whether the trace is feasible under the model. It
never throws on an infeasible trace; it returns a
[`TraceEvaluation`](@ref) that says what went wrong.

### How to invoke it

The evaluator needs a sim that records the enabled-clock set at each step.
Build the evaluation sim with `step_likelihood=true`:

```julia
using ChronoSim
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
    observer=observer,
)
ChronoSim.run(fsim, my_init!, (p, i, e, w) -> i > 20)

# 2. Evaluate the trace on a *fresh* sim built with step_likelihood=true.
esim = SimulationFSM(
    MyBoard(1), [MyEventA, MyEventB];
    rng=Xoshiro(7),
    step_likelihood=true,
)
ev = trace_likelihood(esim, my_init!, trace)
```

To differentiate the trace log-likelihood with `ForwardDiff`, pass
`likelihood_eltype=eltype(θ)` in addition to `step_likelihood=true`; see
[Differentiating a trace likelihood](@ref).

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
`trace_likelihood needs a simulation built with step_likelihood=true`, the
evaluation sim was built without that flag. Add `step_likelihood=true` as shown
above.

### How to turn it off

There is nothing to turn off. Trace evaluation is a separate entry point
(`trace_likelihood`) that you call explicitly; it does not run during a normal
`run` and adds no cost to a production simulation. The only requirement is
building the evaluation sim with `step_likelihood=true`.

---

## Record a trajectory skeleton

The `RecordSkeleton` policy captures a replayable record of a run — the
pre-initialization RNG state and, per fired event, its clock key, firing time,
changed addresses, and enable/disable/proposal history. It is opt-in: a
simulation constructed without the policy records nothing and pays nothing.
Retrieve the result with [`recorded_skeleton`](@ref) and, optionally, persist it
with [`save_skeleton`](@ref) / [`load_skeleton`](@ref ChronoSim.load_skeleton).

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

The recorded fields are `skel.seed` (the simulation's master seed, from which
replay re-derives every random stream family), `skel.metadata` (the opaque
value above), `skel.init` (the
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
sets is overwritten — `replay` reseeds every stream family from `skel.seed`, so
the re-run consumes the identical randomness. Model identification (constructor
arguments, git
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
    rng=Xoshiro(seed), policy=rec)
ChronoSim.run(sim, init_physical, stop)
skel = recorded_skeleton(rec)

# 2. A factory that rebuilds the same sim (rng is overwritten by replay).
factory = policy -> (SimulationFSM(physical_ctor_args..., EVENTS;
    rng=Xoshiro(seed), policy=policy),
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

The last line is a stub: the static "no event can ever write what the
predicate reads" verdict needs effect-analysis reachability
(`can_stop_change`) wired into `whyrunning`, which is not yet done. Until
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
    rng=Xoshiro(seed))
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

---

## Check that events only write what they declare (`@fire` + `CheckEffects`)

[`@fire`](@ref) derives each event's static write set (`effect_spec(EvtType)`) by
a syntactic taint pass over its `fire!` body — the write-side mirror of
[`@precondition`](@ref). The [`CheckEffects`](@ref) policy then verifies, after
initialization and after every fired event, that each captured changed address
matches a declared write mask. It is opt-in, read-only, and consumes no
randomness, so a trajectory with it on equals one with it off; it costs a
production run nothing when absent.

### How to invoke it

Annotate `fire!` with `@fire` (byte-identical runtime behavior) and pass the
policy to the simulation:

```julia
@fire function fire!(evt::Infect, physical, when, rng)
    physical.actors[evt.sink].strain = physical.actors[evt.source].strain
    physical.actors[evt.sink].state = Infectious
end

sim = SimulationFSM(physical, events; seed=42, policy=CheckEffects(events))
ChronoSim.run(sim, InitEvent(), stop)
derivation_report(Infect)     # includes the WRITES section
```

`CheckEffects(events)` also unions in the `WriteSpec`s of any `isimmediate` event
types in `events`, since immediate-event writes merge into the same
`changed_places`. Compose it with other policies via `PolicyStack`.

### What its output looks like

The `WRITES` section of `derivation_report` (captured verbatim), showing each
write site's mask, index cleanliness (with the widened-write count), operation,
and rhs classification, then the rhs mix and any walker notes:

```
Derivation report for Infect
  event fields: source, sink
  triggers: none derived (hand-written generators)
  WRITES (2 sites, 0 widened)
    WRITE [actors, ℤ, strain]  CLEAN  binds: sink  op: assign  rhs: state_expr
    WRITE [actors, ℤ, state]  CLEAN  binds: sink  op: assign  rhs: evt_pure
  rhs mix: evt_pure 1, state_expr 1, stochastic 0, opaque 0
```

On a violation the oracle throws an [`EffectCoverageError`](@ref) (captured
verbatim from a `fire!` that hid a write to `locations` behind an opaque helper):

```
EffectCoverageError: event Infect wrote an address not
covered by any WriteSpec.
  changed address: (locations, 3, cnt)
  masked to      : (locations, _index, cnt)
  classified     : missing_container — no WriteSpec names this top-level field (an undeclared effect)
  declared writes (masked):
    (actors, _index, strain)
    (actors, _index, state)
This event performed a write its @fire analysis did not declare — either the write hides behind an opaque helper (register it with @fragment or use a recognized mutation form) or the walker misclassified the address shape.
```

### What each failure form means

  * `:missing_container` — an undeclared effect: the changed address's top-level
    field is named by no `WriteSpec`. Usually a helper the walker could not see
    (register it with `@fragment` or use a recognized mutation form) or a state
    write on a container the body never assigns directly.
  * `:shape_mismatch` — the container is declared but the leaf/index shape
    differs. Check for an observed-container-valued field assignment (out of
    fragment) or report a walker bug.
  * A macro-time `@fire` error naming a `!` call — the mutation form is not in
    the recognized table; register the helper with `@fragment` or rewrite the
    mutation with a recognized form. See the Static Effect Analysis guide.

### How to turn it off

Diagnostic only. Construct the `SimulationFSM` without the policy (or leave it
out of the `PolicyStack`); `@fire` itself only adds analysis metadata and never
changes runtime behavior.

---

## Lint a model's footprints (interference, races, missed triggers)

**What:** `lint(events; physical=...)` intersects every event's static write
masks (`@fire`) with every event's static guard-read masks (`@precondition` or
`@guard`) and reports: missed-trigger warnings (a write can flip a guard whose
event has no trigger on that address), write→write races (info), dead addresses
(info). Write→rate edges are NOT analyzed in v1 and the report says so. The
analysis is static and over-approximate: it sees address masks, not expression
semantics. See the "Linting a model's footprints" guide.

### How to invoke it

```julia
using ChronoSim
report = ChronoSim.lint([Travel, Infect, Recover, Reset, Mutate, InitEvent];
                        physical=Village(30, 10, 1.0, Xoshiro(2938423)))
report                                 # bounded summary (show)
ChronoSim.print_lint(stdout, report)   # every edge, greppable

# In tests:
ChronoSim.assert_lint_clean(report; allow=[
    ChronoSim.LintAllow(reader=:PickNewDestination, mask="[person, ℤ, waiting]",
                        reason="reachability: waiting flips only with location"),
])
```

Hand-written models must opt in: prefix each `precondition` with `@guard`
(analysis-only; runtime behavior is byte-identical) and mark state-receiving
helpers `@fragment`. Derived (`@precondition`) events need nothing.

### What its output looks like

Captured verbatim from the SIRVillage model
(`lint([InitEvent, Travel, Infect, Recover, Reset, Mutate]; physical=Village(30,10,1.0,Xoshiro(2938423)))`).
This report was reviewed by a human once and is archived here as the reference
output:

```
LintReport: 6 events
  write→guard: 18 edges over 2 addresses (0 warnings in 0 groups, 18 info)
  write→write: 17 shared-address pairs (info)
  write→rate edges: not analyzed (enable-time reads are runtime-only in v1; the depnet tracks them dynamically)
  dead addresses: none
  unanalyzed guards: InitEvent    unanalyzed effects: none
  caps: none
```

Reading it: the two write→guard addresses are `[actors, ℤ, state]` (16 edges —
Infect/Recover/Reset/InitEvent write the state field all four guards read) and
`[actors, ℤ, haunt]` (2 edges — InitEvent/Travel write the haunt field Infect's
guard reads); all 18 are info because every SIRVillage reader has a
`changed(actors[who].state)` (or `.haunt`) trigger that covers them (no missed
proposals). The 17 write→write pairs span `actors` (state/strain/haunt),
`locations`, `strains`, and `next_strain_id` — `actors.strain` shows up only
here, since no guard reads it. `InitEvent` appears under
*unanalyzed guards* because it has no precondition (it is the bootstrap event),
not because anything is wrong. The `Mutate → Infect` rate dependence (Mutate
writes `strains[*].infectivity`, Infect's `enable` reads it) appears in NO edge —
it is a write→rate edge, and the fixed rate line is the honest disclosure that v1
does not analyze it.

### What each failure form means

  * **WARNING missed trigger** — reader `R` has no trigger on the printed mask,
    so a writer can flip `R`'s precondition without `R` ever being proposed.
    Either add the `@reactto changed(...)` trigger (the fix for a real bug — the
    historical `doors_open`/`StopElevator` gaps) or add a `LintAllow` entry with
    a written reason (an intended trigger narrowing).
  * **`LintFailure` from `assert_lint_clean`** — an unallowed warning; the
    message shows the exact `reader`/`mask`/`writer` to allow if intended. A
    stale (unused) `LintAllow` prints a notice but does not fail.
  * **`caps:` lines** — enumeration or dead-address reflection was skipped or hit
    a cap; pass a live `physical=` instance or add `@domain` as named. Never
    silent.
  * **dead address** — a physical field written by no event and read by no guard
    (rate reads are not analyzed, so a rate-only input like landspread's
    `distance` appears here by design).

### How to turn it off

Diagnostic only — nothing runs unless you call `lint`. The `LintHarvest` policy
is opt-in and used only by the static⊇dynamic CI test; leave it out of the
`PolicyStack` for production replicates.

## Compile a model to Quint (`compile_quint`)

Print a model's registered guards, effects, helpers, and invariants as a Quint
module for model checking. Pure Julia — no toolchain needed to emit.

### How to invoke it

```julia
using ChronoSim
qm = compile_quint(MyModel, EVENTS, physical_snapshot;
                   name="mymodel", invariants=InvariantModule)
write_quint("mymodel.qnt", qm)
show(stdout, MIME"text/plain"(), qm.report)
```

`EVENTS` is the same event-type vector passed to `SimulationFSM`; the physical
snapshot supplies `init` literals and array extents. `invariants` names the module
holding the `@invariant`s (default: the events module). Opt-outs: `skip_events`
drops an event (module marked PARTIAL); `assume_true_guards` compiles an event
whose `precondition` is literally `true` (reliability `StartDay`, sirvillage
`Travel`).

### What its output looks like

```
quint compilation: elevator (9 events)
  clean   : PickNewDestination CallElevator OpenElevatorDoors ...
  widened : (none)
  assumed : (none)
  skipped : (none)
  refused : (none)
constants promoted: floor_cnt
records collapsed : ElevatorCall -> requested
fields erased     : (none)
invariants        : 8 compiled, 0 refused
widenings total   : 0 (v1 refuses where the design allowed widening; `// WIDENED:` markers reserved)
```

### What each failure form means

`compile_quint` gathers *all* problems and throws one `QuintCompileError`, each
entry naming the event, construct, and source:

* **`:no_precondition` / `:no_fire`** — annotate `@precondition` / `@fire`, or opt
  out with `assume_true_guards` / `skip_events`.
* **`:float_read`** — a guard/invariant/index reads a `Float64`. The spec is the
  integer jump skeleton; model the gate as an integer/enum field or skip the event.
* **`:unclassified_loop`** — a loop matching none of the five idioms
  (filter-accumulate, existential flag, universal flag, count/sum, min-by /
  capped scan). Rewrite it as one of those, or as a reducer over a generator.
* **`:loop_read_write_overlap`** — a `fire!` loop reads a variable the same loop
  writes in a way independent per-variable folds cannot express (e.g. an element
  write reading a scalar the loop increments). Use a local counter (compiled as
  one ordered `foldl`), or make the read field-disjoint / loop-indexed.
* **`:unordered_fold`** — a min-by or capped scan over dict keys: no defined
  iteration order. Iterate an array index range instead.

v1 refuses every case the design allowed to widen, so a compiled module is exact
on the integer fragment; `// WIDENED:` markers and `report.widenings` are the
reserved surface for a future opt-in widening mode (the reconciliation test pins
both at 0).

### How to turn it off

Nothing is default-on; compilation is an offline call you make explicitly.

## Verify invariants with Apalache (`quint verify`)

Prove a compiled model's invariants hold over every reachable state to a bounded
depth.

### How to invoke it

The compiled module names its invariants `inv_<declared name>` plus the grouping
`val inv` (the conjunction of all of them — the usual target).

```bash
export JAVA_HOME=".../temurin-17/Contents/Home"; export PATH="$JAVA_HOME/bin:$PATH"
npx quint verify --max-steps=5 --invariant=inv mymodel.qnt
# localize a violation one invariant at a time:
npx quint verify --max-steps=5 --invariant=inv_no_ghost_calls mymodel.qnt
```

The first `verify` downloads Apalache 0.56.1 into `~/.quint` (~1 min, one-time).

### What its output looks like

```
State 0: state invariant 0 holds.
...
The outcome is: NoError
[ok] No violation found
```

Wall-clocks scale with depth and instance size: on the 3-person elevator the
compiled `inv` proves at depth 5 in ≈ 25 s; an early hand translation's type
invariant at depth 10 took ≈ 10 min and its safety invariant at depth 8 ≈ 1.5 min
(`quint_spike/RESULTS.md`). Start small and grow the depth.

### What each failure form means

`The outcome is: Error` with a counterexample trace means an invariant was
violated at some reachable state. Analyze *which side is wrong* — a translation
bug (the spec is stricter or looser than the model) or a genuine model finding —
by re-deriving the compiled action by hand against the Julia source. `NoError`
means proved to that depth (not a proof at greater depths).

### How to turn it off

Don't call it — verification is a manual, offline step.

## Validate a recorded trace (`validate_trace`)

Check that a recorded trajectory is a legal path of the compiled spec: every state
satisfies the invariants, and every transition is accepted by the recorded event's
compiled action.

### How to invoke it

```julia
rec = RecordSkeleton()
sim, init = factory(rec)                 # factory(policy) -> (sim, initializer)
ChronoSim.run(sim, init, stop)
skel = recorded_skeleton(rec)

qm  = compile_quint(model, EVENTS, physical; invariants=InvModule)
rep = validate_trace(qm, skel, factory)  # factory is exactly replay's factory
show(stdout, MIME"text/plain"(), rep)
```

### What its output looks like

A pass (captured from the elevator, 4 recorded steps):

```
trace validation: elevator
  steps        : 4 checked / 4 total
  invariants   : PASSED
  transitions  : PASSED
  log[invariants]  : /tmp/quint_trace_xyz/stage1_run.log
  log[transitions]  : /tmp/quint_trace_xyz/stage2_verify.log
  wall-clock   : 14.0 s
```

A stage-2 failure (captured: the same trajectory checked against a module whose
CallElevator guard was mis-emitted with `mutate_for_test`) — the ascending
localization loop names the exact rejected transition:

```
trace validation: elevator
  steps        : 4 checked / 4 total
  invariants   : PASSED
  transitions  : FAILED
  first failure: step 3 event CallElevator at when=3.0204157240506944 (transitions stage)
  log[invariants]  : .../stage1_run.log
  log[localize]  : .../stage2_localize_4.log
  log[transitions]  : .../stage2_verify.log
  wall-clock   : 49.17 s
```

### What each failure form means

* **`invariants: FAILED`** (stage 1, `quint run`) — a reconstructed state violates
  a compiled invariant: the simulator and the spec disagree on which states are
  legal. `first_failure` names the violating state's step and event (parsed from
  the deterministic counterexample's `t_i`).
* **`transitions: FAILED`** (stage 2, `quint verify`, reported as Apalache
  `Deadlock`) — a recorded transition is rejected by the compiled guard/effect: the
  guard the simulator ran and the guard the spec models disagree. This is the
  thesis case; the mutation test (`mutate_for_test`) proves the loop has teeth,
  and the `notReach_k` localization loop pins the first rejected step.
* **`:skipped`** — the toolchain is absent (`invariants` needs Node; `transitions`
  needs a JVM), or the trace fires an event omitted by `skip_events` (a PARTIAL
  module cannot force that transition — `skip_reason` names the step). The report
  quotes the exact install commands from `quint_spike/VERSIONS.md`. Steps beyond
  `maxsteps` are reported, never silently dropped.
* **`:error`** — the checker crashed or printed unrecognizable output; the log
  tail is in `skip_reason` and the full log at the reported path. Distinct from
  `:failed` by construction.

### How to turn it off

Nothing is default-on. A `ReplayDivergence` raised during reconstruction is a
pre-existing determinism bug (different constructor args or package versions),
surfaced as-is, not swallowed.
