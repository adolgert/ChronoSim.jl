# Events

This page defines each piece of an event precisely. The
[Getting Started](getting_started.md) example shows the same pieces in the
flow of a working program, so it can help to read the two side by side.

## The event struct

An event type is an immutable struct that subtypes `SimEvent`. Its fields
identify which instance of the event this is — which person, which machine,
which pair of individuals — and the framework calls these the *identifying
fields*.

```julia
struct Repair <: SimEvent
    machine::Int64
end
```

Internally the framework refers to an event by its *clock key*, which is a
tuple of the type name followed by the field values, such as
`(:Repair, 3)`. Clock keys appear in logs and diagnostics, and they are the
identity under which an event's clock lives in the sampler. Two event values
with equal fields are the same event, so fields should be plain values with
sensible equality: integers, symbols, strings, enums, or tuples of these.

An event struct may also be empty, when the event concerns the system as a
whole rather than any particular entity.

## `precondition`

```julia
precondition(event, state)::Bool
```

The precondition answers whether the event could happen in the current
state. It must be a pure test: it reads the state and returns a boolean, and
it must not modify anything. The framework records which addresses it reads
and re-evaluates the precondition when any of them changes, so the
precondition is also, implicitly, a declaration of what the event depends
on.

Write preconditions to be *self-contained*, meaning the precondition itself
excludes every state in which `fire!` would misbehave. It is tempting to
rely on the fact that generators only propose an event in reasonable
circumstances, but that coupling is fragile, and the derivation machinery
assumes the precondition tells the whole truth. If firing requires that a
person be on a floor, the precondition should test that the person is on a
floor.

Declaring the precondition with the `@precondition` macro, rather than as a
plain function, additionally derives the event's generators from its body.
The [Generators](generators.md) page describes that in full.

## `enable` and `reenable`

```julia
enable(event, state, when) -> (distribution, te)
```

When a precondition first becomes true, the framework calls `enable` to
learn the distribution of the event's firing time. The return value is a
tuple of a continuous univariate distribution from Distributions.jl and a
time `te` from which the distribution is measured. In the common case you
return `(dist, when)`, meaning the waiting time starts now. Returning an
earlier `te` shifts the distribution's origin into the past, which expresses
an event whose hazard has already been accumulating — for example, a machine
whose failure clock started when it began working, not when you happened to
enable the event.

The framework records which addresses `enable` reads, and those reads are
the event's *rate dependencies*. If a later firing changes one of them while
the event remains enabled, the framework calls `reenable`:

```julia
reenable(event, state, first_enabled, when)
```

The default `reenable` returns `nothing`, which means "keep the clock I
already have." If the event's rate genuinely tracks the state — a repair
rate that depends on how many repair crews are free, say — forward it to
`enable` so the distribution is recomputed:

```julia
reenable(evt::Repair, state, _, when) = enable(evt, state, when)
```

This treatment of long-lived clocks with state-dependent rates follows the
generalized semi-Markov process view of discrete-event systems, and readers
who want the theory can start with Glynn's 1989 survey of the GSMP
formalism.

## `fire!`

```julia
fire!(event, state, when, rng)
```

Firing is the only place the model changes the state. The framework records
every address written during `fire!` and uses that set to decide which
events to re-examine and which new candidates to propose; nothing else
triggers a re-examination, which is why all mutation must happen here (or in
the initializer, described below). If `fire!` draws random numbers — to
choose a destination, say — it must use the `rng` argument rather than a
global generator, both for reproducibility and because the drawn values are
then part of the trajectory's likelihood.

## Immediate events

An event type can declare itself *immediate*:

```julia
isimmediate(::Type{OpenValve}) = true
```

An immediate event fires at the same instant as the timed event that made
its precondition true, with no waiting time and no `enable` call. Chains of
immediate events are resolved before the next timed event is sampled. Use
them for consequences that are logically instantaneous, such as a valve that
opens the moment pressure crosses a threshold. This is the same distinction
that generalized stochastic Petri nets draw between timed and immediate
transitions.

## Running a simulation

A model's event types, plus an initial state, are assembled into a
simulation like this:

```julia
sim = SimulationFSM(physical, event_types; seed=838109, observer=callback)
ChronoSim.run(sim, initializer, stop_condition)
```

`SimulationFSM` takes the physical state and a vector of the event *types*
in the model. By default it builds the historical next-reaction sampler from
CompetingClocks.jl; you can select a different one by passing a sampler method
spec via the `sampler` keyword (e.g. `sampler=FirstReactionMethod()` after
`using CompetingClocks: FirstReactionMethod`), and either a `seed` or an
explicit `rng`.

The `initializer` is a function that sets up the state at time zero. Writes
it makes are recorded exactly like the writes of a firing, and those writes
are what propose the first candidate events, so every part of the state that
events depend on should be written (not merely constructed) during
initialization.

The `stop_condition` is a function
`(physical, step_idx, event, when) -> Bool` that is consulted with the event
that is about to fire, before it fires. Returning `true` stops the run, so a
condition like `when > 100.0` stops the clock strictly between events.

The `observer` keyword accepts a function
`(physical, when, event, changed_places) -> nothing` that the framework
calls after each firing. This is the intended place to record trajectories,
compute summary statistics, or check invariants; the examples in this
documentation use it to save `(event, time)` sequences.
