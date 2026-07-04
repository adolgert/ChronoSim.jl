# Derived Event Generators

ChronoSim can derive an event's generators from its precondition, so the
modeler writes the enabling rule once instead of twice. This page is the
modeler's guide; the contract behind it is on the
[State Contract](state_contract.md) page.

## The two-artifact problem

Written by hand, every event needs a `precondition` (is this event sensible
now?) and a `@conditionsfor` block (when should the framework even *consider*
this event?). The second is the first read backwards: each trigger names a
place the precondition reads, with the event's identity abstracted into a
pattern. Keeping them consistent is on you, and the failure mode is silent —
a missing trigger means an event that never wakes up, not an error.

## `@precondition`

Wrap the ordinary method definition:

```julia
@precondition function precondition(evt::Break, physical)
    return physical.actors[evt.actor_idx].state == working
end
```

This emits the method exactly as written, **and** a
`generators(::Type{Break})` method derived from the body. The derived
generators are ordinary `EventGenerator`s; the runtime does not know the
difference.

How the derivation reads the body:

- A read like `actors[evt.actor_idx].state` whose index uses only event
  fields and literals is a **clean** read: it becomes a trigger on
  `actors[i].state` that constructs `Break(i)` when that place changes.
- A read whose index depends on anything else — another state value, a loop
  variable, an arithmetic combination — **widens**: the trigger still fires
  on the place pattern, but proposes the event over its whole field domain.
  Over-proposing is safe; the precondition filters. Under-proposing is the
  bug derivation exists to prevent.
- Locals work as you would expect: `person = physical.person[evt.person]`
  followed by `person.waiting` is a read of `person[evt.person].waiting`.
  Loops and `if` are supported; a loop-indexed read widens.

Inspect what was derived — worth doing once for every converted event:

```julia
derivation_report(Break)
```

prints each trigger's pattern, whether it is CLEAN (and which fields it
binds) or WIDENED (and why), literal guards, and where each field's domain
came from.

## Helper functions: `@fragment`

A call that passes state to an ordinary function is rejected — the analysis
cannot see reads inside a function it only knows by name, and guessing would
under-trigger. Mark the helper instead:

```julia
@fragment function people_waiting(people, floor, dirn)
    waiters = Int[]
    for pidx in eachindex(people)
        p = people[pidx]
        if p.location == floor && p.waiting && get_direction(p.location, p.destination) == dirn
            push!(waiters, pidx)
        end
    end
    return waiters
end
```

`@fragment` defines the function unchanged and registers its body; when a
`@precondition` body calls it, the call is inlined for analysis (only for
analysis — the runtime still calls your function). Rules:

- Define the helper before the `@precondition` that calls it.
- One method per name, positional arguments only.
- Helpers may call other `@fragment` helpers (bounded depth; recursion is an
  error).
- A helper's *return value* used as a container index widens the trigger —
  the analysis does not track values through returns.
- One precondition may call another: `precondition(EnterElevator(pidx), system)`
  inlines the registered body for `EnterElevator` with the constructor
  arguments substituted for its event fields.
- `any`/`all`/`count`/`sum`/`prod`/`minimum`/`maximum` over a generator
  expression are analyzed like loops:
  `any(can_board(system.person[p]) for p in eachindex(system.person))` is in
  the fragment when `can_board` is `@fragment`.

## Domains for free fields

A widened trigger, or a clean read that binds only some of an event's fields,
must enumerate the unbound fields. Domains resolve automatically:

1. a field used as a container index gets that container's keys
   (`eachindex` for arrays, `keys` for dicts, projected components for tuple
   keys);
2. `@enum` and `Bool` fields get their instances;
3. otherwise declare one:

```julia
@domain Move.direction = ALLDIRECTIONS
```

The right-hand side is evaluated against the live state as `physical`. If no
domain resolves, `generators()` fails at setup with the exact `@domain` line
to add. In practice the three example models needed none.

## What stays manual

Two cases keep hand-written `@conditionsfor`, by design:

- **Zero-read preconditions** (`precondition(evt, s) = true`): rate-driven
  events have nothing to derive from. The macro rejects them loudly.
- **`fired(...)` triggers**: event-causes-event scheduling is causal
  knowledge, not state-reading; it cannot come from a precondition.

Use either `@precondition` or `@conditionsfor` for a given event type, not
both — each defines that event's `generators` method.

## The safety net

Two mechanical checks back the derivation:

- `ChronoSim.check_derivation_coverage(true)` makes every precondition
  evaluation assert that each captured read matches a derived trigger
  pattern. Run it in your tests; a violation is a derivation bug surfaced
  with the offending address.
- `ChronoSim.collect_generation_stats(true)` counts proposed vs. admitted
  candidates per event type, so you can see what widening costs on your
  model before deciding whether a hand-written generator is worth its risk.
