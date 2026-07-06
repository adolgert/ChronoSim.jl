# Recording and replaying a run

A stochastic simulation that misbehaves on step 4,000 of a seeded run is hard to
study: you cannot pause it, you cannot step backward, and re-running from the top
to reach the interesting moment means waiting through everything before it. The
record/replay layer fixes all three. [`RecordSkeleton`](@ref) captures a run as a
replayable [`TrajectorySkeleton`](@ref); [`replay`](@ref) re-executes that
skeleton bit-for-bit and hands you the live simulation *positioned at any step you
name*, where you can inspect state, run [`guard_clauses`](@ref), or attach probes.
This is time-travel debugging for a GSMP. The
[runbook entry](@ref "Record a trajectory skeleton") is the terse reference; this
page is the narrative walkthrough of the whole workflow.

## The one workflow

Five pieces fit together:

* [`RecordSkeleton`](@ref) — an opt-in policy you pass to `SimulationFSM`. It
  observes a run and captures a [`TrajectorySkeleton`](@ref).
* [`recorded_skeleton`](@ref) / [`save_skeleton`](@ref) / `load_skeleton`
  — retrieve the skeleton after the run, and optionally persist it.
* [`replay`](@ref) — re-execute the skeleton exactly, returning the live sim.
* `upto=k` — stop the replay after step `k`, so you hold the state the original
  run had at that moment.
* `probes` and [`guard_clauses`](@ref) — observe every replayed step, and
  interrogate a precondition at the paused state.

## Recording is free when off

Recording is opt-in and costs a production run nothing: a `SimulationFSM` built
without the `policy` keyword records nothing and pays nothing (the default
`NoPolicy` compiles every hook to `return nothing`). The recorder only *observes*
— it never draws from the RNG and never mutates state — so a recorded run's
trajectory is byte-identical to the same-seed run unrecorded.

```julia
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks: CombinedNextReaction
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

using .Race: RaceBoard, FireA, FireB

# Record a 30-step run of the two-clock race.
rec = RecordSkeleton(metadata=(model="race", n=1, seed=12345))
sim = SimulationFSM(RaceBoard(1), [FireA, FireB];
    rng=Xoshiro(12345), sampler=CombinedNextReaction{Tuple,Float64}(), policy=rec)
ChronoSim.run(sim, Race.init!, (p, i, e, w) -> i > 30)
skel = recorded_skeleton(rec)
```

`metadata` is stored opaquely and never read by the framework — put model
identification there (module, constructor arguments, git SHA) so a persisted
skeleton is self-describing. `skel` displays as a five-line summary:

```
TrajectorySkeleton
  clock key  : Tuple
  steps      : 30
  time span  : 0.0 -> 5.5075583294278285
  top events : FireB 19 | FireA 11
```

and packs to one line inside another structure:
`TrajectorySkeleton(30 steps, t=0.0..5.5075583294278285)`. It is data, not a
transcript: per step it holds the fired clock key, firing time, changed
addresses, and the full enable/disable/proposal history. Persist it with
`save_skeleton("race.skel", skel)` and reload with `load_skeleton("race.skel")` —
but do not archive `.skel` files across Julia or package upgrades; the
serialization format is version-bound.

## The determinism contract

`replay` does not store state snapshots — it *re-runs* the model. To make that
re-run reproduce the original exactly, it restores the skeleton's pre-init RNG
state and drives the same executor kernel `run` uses, checking the fired
`(clock_key, when)` against the recording at every step. That only works if you
give it a **factory** that rebuilds the identical simulation:

```julia
factory = policy -> (SimulationFSM(RaceBoard(1), [FireA, FireB];
    rng=Xoshiro(12345), sampler=CombinedNextReaction{Tuple,Float64}(),
    policy=policy),
    Race.init!)
```

The contract on `sim_factory` is precise:

* It is called as `factory(policy)` and must **return `(sim, initializer)`** — a
  fresh `SimulationFSM` and the same initializer you handed `run`.
* It must **pass through the `policy` it is given** (`policy=policy`); `replay`
  installs its own probe/verification policy there. Dropping it is an
  `ArgumentError`.
* It must rebuild with the **same constructor arguments** as the recorded run.
  Any `seed`/`rng` it sets is overwritten — `replay` restores `skel.rng_state`,
  so the re-run consumes the identical random stream. Reproducing the constructor
  is the caller's job; this is why the constructor arguments belong in
  `skel.metadata`.

If the rebuilt run ever fires a different `(clock_key, when)` than the recording,
`replay` raises a [`ReplayDivergence`](@ref) — the determinism contract was
broken. There is no tolerance: replay is exact.

## Time-travel to just before a step

Now the payoff. Say step 10 is interesting and you want the state *the instant
before it fired*. Replay with `upto=9`:

```julia
sim9 = replay(factory, skel; upto=9)
sim9.physical.cell[1].a   # => 2
sim9.physical.cell[1].b   # => 7
sim9.when                 # => 1.4823489375249403
```

`upto=9` stops after step 9, so `sim9` holds exactly the state the original run
had when step 10 was about to fire (two `FireA`s and seven `FireB`s have
happened). `upto=0` returns the freshly-initialized sim; omitting `upto` replays
the whole skeleton. The recording tells you what fires next:

```julia
skel.steps[10].clock   # => (:FireA, 1)
skel.steps[10].when    # => 1.530787664150075
```

## Interrogating the paused state

At a paused state you can run any read-only diagnostic. [`guard_clauses`](@ref)
evaluates a derived event's `@precondition` conjunct by conjunct against the live
state — the tool for asking *why* the event that fired next was (or was not)
fireable here:

```julia
guard_clauses(FireA(1), sim9.physical)
```

```
  ("(state.cell[evt.idx]).a >= 0", true)
```

`FireA`'s single guard is `true` at this state, consistent with it being the
event that fires at step 10. On a model with a compound precondition each
top-level `&&` conjunct prints on its own line, and the verdict is the first
non-`true` value in source order — see the
[runbook entry](@ref "Explain a precondition clause by clause") for reading a
multi-clause guard and its failure forms.

## Watching the whole run with probes

To observe every step instead of pausing at one, pass `probes` — a tuple of
functions each called `probe(sim, step, phase, event, when)`, with `phase` one of
`:init`, `:prefire`, `:postfire`:

```julia
vals = Tuple{Int,Symbol,Float64}[]
watch(s, step, phase, event, when) =
    phase === :postfire && step <= 5 && push!(vals, (step, clock_key(event)[1], when))
replay(factory, skel; probes=(watch,))
```

```
(1, :FireB, 0.26521642934417394)
(2, :FireB, 0.41819747975031385)
(3, :FireB, 0.504107517742944)
(4, :FireB, 0.8380454671783777)
(5, :FireB, 0.8819792933503997)
```

Probes never perturb the replay — two replays with different probes fire the
identical sequence. The same `ProbePolicy` works on a *forward* run too:
`SimulationFSM(...; policy=ProbePolicy((watch,)))`.

## Failure forms

The determinism contract surfaces as clear errors:

* **`ReplayDivergence at step k`** — the rebuilt sim fired a different
  `(clock_key, when)` than the skeleton recorded. Because replay is exact, any
  divergence means the re-run is not the recorded run. Here, tampering step 9's
  recorded clock key produces one:

  ```
  ReplayDivergence at step 9
    expected : (:FireB, 1) at t=1.4823489375249403
    actual   : (:FireA, 1) at t=1.4823489375249403
  Replay is exact: this rebuilt simulation is not the recorded run.
  Check: same constructor args; same package/Julia versions; no randomness outside sim.rng.
  ```

  In real use the three causes are exactly those the message names: different
  constructor arguments, a different package/Julia version, or model code drawing
  randomness from outside `sim.rng`. When only the time differs the message reads
  `time differs by …`; an `actual : (no event; sampler exhausted before this
  step)` means the re-run ran out of events early — again a determinism break.
* **`ArgumentError: sim_factory must pass the policy it is given`** — the factory
  dropped the `policy` argument. Add `policy=policy` to the `SimulationFSM` call.
* **`ArgumentError: upto=… is outside this skeleton's 0:N steps`** — `upto` was
  negative or larger than the recorded step count.
* **`ArgumentError: sim_factory(policy) must return (sim, initializer)`** — the
  factory returned something other than the required 2-tuple.
* **`ArgumentError: this RecordSkeleton has not observed a run`** — you called
  `recorded_skeleton` before `run`. Record first.

## What to do with it

* **Bisect a bad run.** Binary-search `upto=k` until the paused state first shows
  the corruption; the step that produced it is your suspect.
* **Feed replay to other verbs.** The `sim_factory` here is exactly the one
  [`whynot`](@ref) and [`validate_trace`](@ref) take, and the skeleton is what
  [`whystopped`](@ref) reads. Record once, and every offline diagnostic runs on
  the same artifact.
* **Reproduce for a colleague.** A saved `.skel` plus the constructor arguments
  in its metadata is a complete, replayable bug report.

## Related

* [Runbook: Record a trajectory skeleton](@ref "Record a trajectory skeleton"),
  [Replay a recorded run](@ref "Replay a recorded run"), and
  [Explain a precondition clause by clause](@ref "Explain a precondition clause by clause")
  — the mechanical references.
* [Declaring and checking invariants](@ref "Declaring and checking invariants") —
  compose [`RecordSkeleton`](@ref) with [`CheckInvariants`](@ref) so a violation
  carries a replayable prefix.
* [Debugging a simulation](@ref "Debugging a simulation") — the why-verbs that
  read a recorded skeleton.
* [Debugging & Verification](@ref) — the overview and symptom-to-technique table.
