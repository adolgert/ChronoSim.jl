# Generators

Every event type needs *generators*: rules that tell the framework which
changes of state make it worth checking that event's precondition. This page
explains why they exist, how to write them by hand with `@conditionsfor`,
how to have them derived automatically with `@precondition`, and how to
decide between the two.

## Why generators exist

A precondition-driven simulation faces an old problem. The classic
activity-scanning style of discrete-event simulation, described in Pidd's
*Computer Simulation in Management Science*, re-checks every conditional
activity after every event, which is simple and correct and much too slow
when the model has many events. Stochastic Petri nets solve the problem
structurally: every transition declares input arcs, so the simulator knows
exactly which transitions to reconsider when a place changes. ChronoSim
takes the Petri-net idea but gets the arcs from code instead of from a
drawn graph. A generator is, in effect, a declared set of input arcs for
one event type.

The contract for a generator is asymmetric, and the asymmetry is the most
important thing on this page. A generator may propose too much: every
proposal is filtered through the event's precondition, so an unnecessary
candidate costs one wasted boolean check. A generator must never propose
too little: an event that is never proposed can never become enabled, no
error is raised, and the model silently loses behavior. When in doubt,
generate.

## Writing generators by hand: `@conditionsfor`

A `@conditionsfor` block attaches one or more reaction rules to an event
type. Each rule begins with `@reactto` and reacts either to a change of
state or to the firing of another event.

```julia
@conditionsfor CallElevator begin
    @reactto changed(person[who].destination) do system
        generate(CallElevator(who))
    end
end
```

Read the pattern `person[who].destination` as follows: `person` is a field
of the state, the bracketed position is a wildcard index, and `destination`
is a field of the element. Whenever a write is recorded at any address
matching `(:person, <any index>, :destination)`, the rule's body runs with
the wildcard variable `who` bound to the concrete index from the address.
The body then calls `generate` with each candidate event it wants proposed.
A body may generate zero, one, or many events, and it may read the state
through its argument (here `system`) to decide:

```julia
@reactto changed(calls[callkey].requested) do system
    for elidx in 1:length(system.elevator)
        generate(OpenElevatorDoors(elidx))
    end
end
```

This second form is common when the changed address does not identify which
event instances are affected — a new call could matter to every elevator, so
the rule proposes them all and lets the precondition sort it out.

The other kind of rule reacts to an event firing rather than to a state
change:

```julia
@reactto fired(Departure(who)) do state
    generate(Arrival(who))
end
```

A `fired` rule expresses causal scheduling — this happening leads to that —
which is information that does not live in the state at all. Event-to-event
scheduling of this kind is the native vocabulary of Schruben's event graphs,
and it is the one kind of trigger that can never be derived from a
precondition, because a precondition only reads state.

## Deriving generators: `@precondition`

For most events the generators repeat information the precondition already
contains: each `@reactto changed(...)` names a place the precondition
reads. ChronoSim can therefore derive the generators. Declare the
precondition with the `@precondition` macro and do not write a
`@conditionsfor` block at all:

```julia
@precondition function precondition(evt::CallElevator, system)
    person = system.person[evt.person]
    return person.location != 0 &&
           person.location != person.destination &&
           !person.waiting
end
```

The macro emits the precondition unchanged, and it also emits generators
built from the body's reads: this example produces triggers on
`person[i].location`, `person[i].destination`, and `person[i].waiting`,
each proposing `CallElevator(i)`. Use either `@precondition` or
`@conditionsfor` for a given event type, not both, because each one defines
that type's complete generator set.

You can always inspect what was derived, and it is a good habit after
converting each event:

```julia
julia> derivation_report(CallElevator)
```

The report lists each trigger's address pattern, whether it binds the
event's fields precisely or proposes over a whole domain, and where each
domain came from.

### How the derivation reads a precondition

The macro analyzes the body's syntax. Understanding the few rules it
follows tells you how to write preconditions that derive well.

**Reads indexed by event fields derive precise triggers.** When the body
reads `system.person[evt.person].waiting`, the index is an event field, so
the derived trigger binds it: a change at `(:person, 4, :waiting)` proposes
exactly `CallElevator(4)`. Literal indices work too and become a runtime
check. Local variables that simply name an element, as `person` does in the
example above, are followed transparently.

**Any other index widens the trigger.** If the body reads a container at an
index computed from state, or inside a loop over the container, the
derivation cannot know from the address which event instance is affected,
so it proposes the event over the whole domain of its fields — precisely
what the hand-written scan-all-elevators rule above did. Widening is always
sound, because generators are licensed to over-propose; what it costs is
extra filtered candidates, discussed below.

**Loops, `if`, boolean operators, and comparisons are all fine.** Scans
such as `for pidx in 1:length(system.person)` are analyzed, with the
loop-indexed reads widened as just described. The reducers `any`, `all`,
`count`, `sum`, `prod`, `minimum`, and `maximum` over a generator
expression, such as `any(p.waiting for p in ...)`, are analyzed the same
way as loops.

**Helper functions must be marked.** A call that passes state to an
ordinary function is rejected at macro time, because the analysis cannot
see the reads inside a function it only knows by name, and guessing would
risk the silent under-proposal failure. Mark the helper with `@fragment`
and it participates:

```julia
@fragment function people_waiting(people, floor, dirn)
    ...
end
```

`@fragment` defines the function exactly as written and additionally
registers its body, so that when a `@precondition` calls it, the analysis
inlines the body with the caller's arguments substituted. Define helpers
before the preconditions that call them. One precondition may also call
another — `precondition(EnterElevator(pidx), system)` inside a body is
analyzed by inlining the registered precondition of `EnterElevator` — which
is useful when one event's enabling rule is naturally phrased in terms of
another's.

**Free fields need domains.** A widened trigger, or a clean read that binds
only some of the event's fields, must propose the event over every value
the unbound fields could take. The domain of each field is resolved
automatically where possible: a field that the body uses as a container
index gets that container's indices or keys, and a field whose type is an
`@enum` or `Bool` gets its instances. When neither rule applies, you
declare the domain once:

```julia
@domain Move.direction = ALLDIRECTIONS
```

The right-hand side is evaluated against the live state under the name
`physical`. If a needed domain is missing, constructing the simulation
fails with a message that names the field and shows the exact `@domain`
line to write. In the three example models shipped with
ChronoSimExamples.jl, every domain was inferred and no `@domain`
declaration was needed.

**Out-of-fragment constructs fail loudly.** Anything the analysis cannot
handle — an unmarked helper receiving state, a precondition that reads no
state at all — is a macro-time error with a message naming the offending
expression and the fix. The derivation never silently drops a read, because
a dropped read is exactly the under-proposal failure the whole mechanism
exists to prevent.

## When you still write `@conditionsfor` by hand

Three situations call for hand-written generators, and they are worth
recognizing in advance.

**Rate-driven events with trivial preconditions.** Some events are always
eligible and are governed entirely by their rate. In the SIRVillage example
model, individuals travel between locations at stochastic intervals, and
travel is always possible:

```julia
precondition(event::Travel, physical) = true

@conditionsfor Travel begin
    @reactto changed(actors[who].haunt) do physical
        generate(Travel(who))
    end
end
```

There is nothing to derive from `true`, and the `@precondition` macro will
say so. The generator here reacts to the event's own effect — each move
proposes the next move — which is causal knowledge the modeler supplies.

**Event-to-event scheduling.** Any trigger of the `fired(...)` kind is by
nature hand-written, as described above.

**Precision worth paying for.** A derived widened trigger proposes over a
whole domain, and sometimes the modeler knows a much smaller set. The
clearest case in the example models is infection in SIRVillage: the event
`Infect(source, sink)` is derived with triggers that propose every
(infectious person, any person) pair, while the hand-written generator
proposes only pairs that are at the same location. Both are correct, and
the measured difference on a 30-person village was about thirty times as
many proposals, all filtered. If profiling shows that filtering dominates,
writing the tighter generator by hand is the remedy, and the two styles
coexist freely across the events of one model.

## Checking your generators

Two runtime tools verify the relationship between preconditions and
generators, and both are worth turning on in a model's tests.

```julia
ChronoSim.check_derivation_coverage(true)
```

makes every precondition evaluation of a derived event assert that each
address it actually read is covered by some derived trigger. A violation
throws, with the offending address, and indicates a bug in the derivation
rather than in your model, so please report one if you see it.

```julia
ChronoSim.collect_generation_stats(true)
```

counts, per event type, how many candidates the generators proposed and how
many were admitted by their preconditions. The ratio is the price of
over-proposal. In the shipped examples the ratio is exactly one for events
whose reads are all keyed by event fields, and it grows where widening or
free-field domains are involved, which is what the statistics are for: they
tell you where a hand-written generator would actually pay.
