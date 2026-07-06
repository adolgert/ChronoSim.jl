# Declaring and checking invariants

An invariant is a safety property that must hold in *every* state a run passes
through — "a person is either at a floor or in an elevator, never both", "an
elevator's floor is in range". [`@invariant`](@ref) declares one as a named,
pure boolean function of the physical state; the [`CheckInvariants`](@ref) policy
evaluates every declared invariant after initialization and after every fired
event, and throws a structured [`InvariantViolation`](@ref) the instant one turns
false — naming the invariant, the event that broke it, and the exact address the
fire wrote. Composed with a recorder, the violation even carries the `replay`
command that reconstructs the state one step before the break. The
[runbook entry](@ref "Check model invariants every step") is the terse reference;
this page is the narrative.

## The symptom

A run finishes, or throws deep in event code, and you suspect the *state* went
bad long before the crash surfaced — a counter went negative, two mutually
exclusive flags both got set, an index escaped its range. Without invariants you
find out only when something downstream trips over the corruption, far from where
it happened. An invariant turns "the state is wrong somewhere" into "invariant
*X* broke at step *k*, and *this event* wrote *this address* to break it".

## Declaration discipline

Declare invariants at the model module's top level. Each `@invariant` takes a
string name and an anonymous one-argument function of `physical`:

```julia
@invariant "a xor b" function (physical)
    all(c.a == 0 || c.b == 0 for c in physical.cell)
end
```

Two rules make the diagnostics sharp:

* **One `@invariant` per logical clause.** On violation the failing *name* is the
  first thing you read, so a narrow name localizes the bug. A single monolithic
  invariant that ANDs ten conditions only ever tells you "something is wrong".
* **A pure boolean function of `physical`.** One argument, no mutation, no
  randomness, returns `Bool`. The checker *re-evaluates* the invariant on the
  failure path to recover which addresses it read (to name the guilty ones), so a
  non-pure invariant gives inconsistent answers and the checker warns. A body
  that returns a non-`Bool` is a declaration error.

## The port-from-validator story

This discipline usually formalizes a validator you already wrote by hand. The
elevator example is the real case: it once had a `check_safety_invariant`
function that walked the state pushing human-readable strings onto a `violations`
list —

```julia
if !found_person
    push!(violations, "Elevator $eidx has button $floor_button pressed but no passenger going there")
end
```

That validator became **eight** named `@invariant`s, one per sub-check, each a
pure boolean of `physical`:

```
person location xor elevator     person destination in range
person elevator exists           elevator floor in range
elevator buttons in range        pressed button has passenger
passenger direction consistent   no ghost calls
```

The `push!(violations, "...")` string check above is now
`@invariant "pressed button has passenger"`. The payoff over the string-list
validator: instead of a batch of messages at the end of a run, you get a throw at
the exact step and event that first broke a named property — and, with a
recorder, a replay command to stand at that moment. (The old validator stays in
the source as the regression oracle for the port.)

## A worked violation

A minimal two-flag model makes the mechanics visible. Each cell has fields `a`
and `b`; the safety property is "a xor b" — at most one nonzero. `Tick` (fast)
sets `a=1` on a fresh cell; `Corrupt` (slow) sets `b=1`. A cell that was already
Ticked and is then Corrupted breaks the invariant, and the guilty write is
exactly `cell[idx].b`.

```julia
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks: CombinedNextReaction
using Distributions
using Random: Xoshiro
import ChronoSim: precondition, generators, enable, fire!
import ChronoSim: PolicyStack

module TwinFlag
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

const RATE_FAST = 100.0
const RATE_SLOW = 0.05

@keyedby FlagCell Int64 begin
    a::Int64
    b::Int64
end

@observedphysical FlagBoard begin
    cell::ObservedVector{FlagCell,Member}
end

function FlagBoard(n::Int)
    cells = ObservedArray{FlagCell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = FlagCell(0, 0)
    end
    return FlagBoard(cells)
end

struct Tick <: SimEvent
    idx::Int64
end
@precondition precondition(evt::Tick, state) = state.cell[evt.idx].a == 0
enable(::Tick, state, when) = (Exponential(1 / RATE_FAST), when)
fire!(evt::Tick, state, when, rng) = (state.cell[evt.idx].a = 1; nothing)

struct Corrupt <: SimEvent
    idx::Int64
end
@precondition precondition(evt::Corrupt, state) = state.cell[evt.idx].b == 0
enable(::Corrupt, state, when) = (Exponential(1 / RATE_SLOW), when)
fire!(evt::Corrupt, state, when, rng) = (state.cell[evt.idx].b = 1; nothing)

function init!(state, when, rng)
    for i in eachindex(state.cell)
        state.cell[i].a = 0
        state.cell[i].b = 0
    end
    return nothing
end

@invariant "a xor b" function (physical)
    all(c.a == 0 || c.b == 0 for c in physical.cell)
end

@invariant "counts nonnegative" function (physical)
    all(c.a >= 0 && c.b >= 0 for c in physical.cell)
end
end # module

using .TwinFlag: FlagBoard, Tick, Corrupt
```

## Compose the recorder underneath the checker

Run under a [`PolicyStack`](@ref) with the [`RecordSkeleton`](@ref) **first** and
[`CheckInvariants`](@ref) second. Order matters: the recorder must capture the
prefix *before* the checker throws, so the violation can carry a replay command.

```julia
rec = RecordSkeleton()
sim = SimulationFSM(FlagBoard(1), [Tick, Corrupt];
    rng=Xoshiro(1234), sampler=CombinedNextReaction{Tuple,Float64}(),
    policy=PolicyStack(rec, CheckInvariants(TwinFlag)))
err = try
    ChronoSim.run(sim, TwinFlag.init!, (p, i, e, w) -> false)
    nothing
catch e
    e
end
```

`CheckInvariants(TwinFlag)` is constructed from the *module* holding the
declarations; it errors at construction if the module registers no invariant. It
is opt-in and debug/test-tier — a sim built without the policy checks nothing and
costs nothing, so production callers leave it off and test suites turn it on.

## Reading an InvariantViolation

`showerror(err)` prints the forensic readout:

```
InvariantViolation: invariant "a xor b" is false
  model    : Main.TwinFlag
  declared : /path/to/TwinFlag.jl:57
  step     : 2 (fires since init)
  event    : (:Corrupt, 1)
  when     : 11.136634449684795
  guilty   : 1 address(es) written by this fire AND read by the invariant
    (cell, 1, b)
  reads    : 2 address(es) in the failing evaluation
    (cell, 1, a)
    (cell, 1, b)
  replay   : replay(sim_factory, skeleton; upto=1)   # reproduces the state one step before the violation
The invariant held after the previous step; the writes above broke it.
```

Line by line:

* **`invariant "a xor b" is false`** and **`declared : …:57`** — the failing
  property and where you wrote it. With one invariant per clause, the name alone
  says what broke.
* **`step : 2` / `event : (:Corrupt, 1)`** — the fire that broke it. The
  invariant held after step 1; `Corrupt` on cell 1 at step 2 broke it.
* **`guilty : … (cell, 1, b)`** — the *guilty address*: the one address this fire
  wrote **and** the invariant reads. This is the smoking gun — `Corrupt` set
  `cell[1].b`, and the invariant reads `b`. When several addresses changed, only
  those the invariant actually reads appear here.
* **`reads : (cell, 1, a), (cell, 1, b)`** — every address the invariant touched
  in the failing evaluation, the superset the guilty set is filtered from.
* **`replay : replay(sim_factory, skeleton; upto=1)`** — because a
  `RecordSkeleton` shared the stack, the violation carries the exact
  [`replay`](@ref) call that reconstructs the state one step *before* the break.
  Feed it `recorded_skeleton(rec)` and the same factory replay takes, and you are
  standing at step 1, about to fire the event that breaks the invariant.

## whystopped is the readout

You do not have to hand-parse the exception. Pass it to [`whystopped`](@ref),
which turns a caught `InvariantViolation` into the same forensics plus each
guilty address's *last and prior writers*:

```julia
whystopped(err)
```

```
whystopped: invariant "a xor b" is false
  step   : 2 (fires since init)
  event  : (:Corrupt, 1)
  when   : 11.136634449684795
  guilty : 1 address(es)
    (cell, 1, b)
      last writer  : step 2 (:Corrupt, 1) t=11.136634449684795
      prior writer : init
  replay : replay(sim_factory, skeleton; upto=1)
```

The writer chain — `last writer : step 2 (:Corrupt, 1)`, `prior writer : init` —
tells you `Corrupt` overwrote a value that had stood untouched since
initialization. `whystopped` also has a plain-skeleton method for reading out a
run that ended *without* a violation; see
[Debugging a simulation](@ref "Debugging a simulation").

## Failure forms

The readout degrades gracefully, and each form tells you what to fix:

* **`step : 0`** — the initializer itself violated the invariant. Fix `init`, not
  an event; `replay` reads `n/a` (re-run the initializer to reproduce the state).
* **`guilty : none identified`** — no address this fire wrote is read by the
  invariant. Either the invariant reads state the tracker cannot see (e.g.
  `Param`-wrapped fields), or the corruption predates this step. Use the `replay`
  command and step forward.
* **`replay : no skeleton recorded`** — no `RecordSkeleton` in the stack. Compose
  `PolicyStack(RecordSkeleton(), CheckInvariants(MyModel))` to get a replayable
  prefix.
* **`WARNING : … not a pure function`** — re-evaluation under read capture
  returned `true`: the invariant gave two answers on the same state. Make it a
  pure function of `physical`.
* **`ArgumentError: no @invariant is registered for this module`** — the module
  has no declarations, or was not loaded before the policy was constructed.
* **`@invariant "name" … returned <T>, not Bool`** — an invariant body returned a
  non-boolean. An invariant must be a `Bool`-valued function of the physical
  state.

## What to do with the answer

* The **guilty address** names the field to look at and the **event** names the
  `fire!` that wrote it — start your fix there.
* The **replay command** puts you one step before the break so you can inspect
  the pre-violation state and run [`guard_clauses`](@ref) on the breaking event.
* An invariant that fires in a *test* under `CheckInvariants` but is expensive is
  exactly why the policy is opt-in: keep it in the test suite, leave it out of
  production replicates.

## Related

* [Runbook: Check model invariants every step](@ref "Check model invariants every step")
  and [Read out why the run stopped](@ref "Read out why the run stopped") — the
  mechanical references.
* [Recording and replaying a run](@ref "Recording and replaying a run") — the
  [`RecordSkeleton`](@ref)/[`replay`](@ref) machinery the replay command uses.
* [Model checking a simulation](@ref "Model checking a simulation") — proves the
  same `@invariant`s hold over *every* reachable state to a bounded depth, not
  just the states one run visited.
* [Debugging & Verification](@ref) — the overview and symptom-to-technique table.
