# Debugging a simulation

Most simulation bugs do not crash. The run completes, the numbers come back, and
they are quietly wrong: an event that should have fired never did, or a run spins
forever on state the stop condition cannot see. This guide walks one real bug end
to end — from the symptom to the fix — using the three *why-verbs*
([`whynot`](@ref), [`whyrunning`](@ref), [`whystopped`](@ref)) built on the
recorded [`TrajectorySkeleton`](@ref). The [runbook](@ref Runbook) is the terse
reference; this page is the narrative.

## The symptom

An elevator that reaches the top or bottom floor should *park* — its
`StopElevator` event fires and its direction becomes `Stationary`. In one model
it never does. Elevators ride to a boundary floor and sit there with a stale
direction; people keep waiting. Nothing throws. There is no stack trace, no
assertion, no `NaN` — the executor simply never proposes the event, so from the
outside the run looks like a slightly-too-idle elevator system.

This is the **missed-trigger** bug class, and it is invisible to exceptions: a
hand-written generator's trigger set omits an address the precondition depends
on, so a change to that address flips the precondition to `true` without any
generator noticing. The event that should now be enabled is never even proposed.

## Record what happened

The why-verbs work on a recorded skeleton, not on a live run. Recording is
opt-in and costs a production run nothing; you turn it on by passing a
[`RecordSkeleton`](@ref) policy:

```julia
using ChronoSim
using CompetingClocks: CombinedNextReaction
using Random: Xoshiro

rec = RecordSkeleton()
sim = SimulationFSM(ElevatorSystem(3, 2, 5), EVENTS;
    sampler=CombinedNextReaction{Tuple,Float64}(), rng=Xoshiro(93472934), policy=rec)
s = 5    # a correct twin of this model first fires StopElevator(2) at step 5,
         # so stop this run just before that step: the state where the stop is due
ChronoSim.run(sim, init_physical, (p, i, e, w) -> i >= s)
skel = recorded_skeleton(rec)
show(skel)                                                  # a replayable artifact
```

`skel` is a replayable artifact: the pre-init RNG state, every fired event, and
the enable/disable/proposal history — not a transcript you squint at, but data
the verbs query.

## Ask the direct question

You suspect `StopElevator` for elevator 2 never fired. Ask why. `whynot` needs
the skeleton, a `sim_factory` that rebuilds the same simulation (the
[`replay`](@ref) contract), and the event instance:

```julia
factory = policy -> (SimulationFSM(ElevatorSystem(3, 2, 5), EVENTS;
    sampler=CombinedNextReaction{Tuple,Float64}(), rng=Xoshiro(93472934), policy=policy),
    init_physical)

rep = whynot(skel, factory, StopElevator(2))
```

The readout:

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

## Reading the output, line by line

* **`NEVER PROPOSED`** — the furthest lifecycle stage the event reached. It was
  not rejected (proposed then filtered) and not outraced (enabled then beaten):
  no generator ever proposed it. That already tells you the bug is in the
  *trigger set*, not in the precondition or the rates.

* **`declared triggers (hand_written)`** — the two addresses the hand-written
  generator reacts to: `elevator[_index].floor` and `elevator[_index].doors_open`
  (`_index` is the wildcard the generator matches any elevator on). This is the
  suspect list.

* **`precondition at final replayed state : true`** followed by the `!!` lines —
  the strongest possible finding. `whynot` replayed the skeleton and evaluated
  `StopElevator(2)`'s real precondition: it is **true right now**. The event is
  fireable at this very state, yet nothing will ever propose it. A trigger gap is
  now certain.

* **`precondition reads (true trigger set)`** — the addresses the precondition
  actually read at that state: `direction`, `floor`, `buttons_pressed`,
  `doors_open`. *These* are the addresses whose changes should propose the event.

* **`MISSING triggers`** — the reads that no declared trigger covers:
  `(elevator, 2, direction)` and `(elevator, 2, buttons_pressed)`. The generator
  reacts to `floor` and `doors_open`, but the precondition also depends on
  `direction` and `buttons_pressed`. A change to either can flip the precondition
  with no generator watching.

* **`near-miss writes`** — the smoking gun. At step 4 `DispatchElevator` wrote
  `(elevator, 1, direction)` — a `container_near_miss` against the trigger set
  (same container `elevator`, different leaf `direction` instead of `floor`).
  `DispatchElevator` writes `direction`, `direction` is a missing trigger, and the
  precondition reads it. That write should have been a trigger.

## The fix

Add the missing triggers to the hand-written generator (this is exactly the fix
commit `53c18d2` applied to the elevator example):

```julia
@conditionsfor StopElevator begin
    @reactto changed(elevator[elidx].floor) do system
        generate(StopElevator(elidx))
    end
    @reactto changed(elevator[elidx].doors_open) do system
        generate(StopElevator(elidx))
    end
    @reactto changed(elevator[elidx].direction) do system      # <- added
        generate(StopElevator(elidx))
    end
    @reactto changed(elevator[elidx].buttons_pressed) do system # <- added
        generate(StopElevator(elidx))
    end
    @reactto changed(calls[callkey].requested) do system        # <- added
        for elidx in 1:length(system.elevator)
            generate(StopElevator(elidx))
        end
    end
end
```

Better still: delete the hand-written block and derive the generators from the
precondition with `@precondition`, which reads the trigger set off the body and
cannot omit an address it depends on — see the derivation guide. The derived twin
is what caught this bug in the first place: it proposed `StopElevator` where the
hand-written twin never did, and the differential test diverged.

## Verify

Re-run with the trigger added and ask again: `whynot` now answers `:fired`, and
the differential twin agrees. The fix is confirmed by the same tool that found
the bug.

## Which verb answers which question

The three verbs partition the questions you ask about a run that finished but
looks wrong:

| Question | Verb | Reads |
|---|---|---|
| Why did event *X* never fire? | [`whynot`](@ref) | skeleton + factory + event |
| Why won't the run stop? | [`whyrunning`](@ref) | final sim + skeleton + stop predicate |
| Why did the run stop (or break)? | [`whystopped`](@ref) | an `InvariantViolation`, or a skeleton |

* A **rejected** event — proposed but always filtered — is `whynot`'s
  `:rejected` stage: it replays to the rejection steps, runs
  [`guard_clauses`](@ref), and names the failing conjunct with the values and
  last writers of its reads. See the [runbook](@ref Runbook) entry *"Ask why an
  event did not fire"*.

* A **run that will not stop** is [`whyrunning`](@ref): it shows the stop
  predicate's reads, their values and writers, and whether the recent event churn
  touches any of them. Its static "can never stop" verdict is a Phase-2 stub for
  now (it carries the line *reachability analysis requires effect analysis (not
  yet run)*). See *"Ask why the run has not stopped"*.

* A **violated invariant** is [`whystopped`](@ref): it names the guilty writer
  event, the guilty addresses with their last and prior writers, and the exact
  `replay(...)` command that reproduces the state one step before the break. Run
  under `PolicyStack(RecordSkeleton(), CheckInvariants(Model))` — recorder first —
  so the violation carries a replayable prefix. See *"Read out why the run
  stopped"*.
