# Introduction

This page explains the ideas you need before you write a model. Every
simulation framework has a way to decide what happens next, and understanding
ChronoSim's way — preconditions, competing clocks, and observed state — makes
everything else in the documentation follow naturally.

## Events are enabled by preconditions

In ChronoSim, an event is a small value, such as `Move(agent=7,
direction=Up)`, together with a handful of functions that give it meaning.
The most important of these is the `precondition`, which looks at the current
state and answers one question: could this event happen right now? Here is a
precondition for a movement event, which says an agent may move in some
direction only when the square it would move into is empty.

```julia
function precondition(event::Move, state)
    loc = state.agents[event.agent].location
    return state.location[loc + event.direction] == 0
end
```

The moment a precondition becomes true, the event becomes *enabled*. An
enabled event will fire at some future time, and that time is drawn from a
probability distribution that you supply through the `enable` function.

```julia
enable(event::Move, state, time) = (Weibull(2, 1.0), time)
```

This says that the waiting time between enabling the event and firing it
follows a Weibull distribution. Every enabled event holds its own running
clock like this, and the framework always fires the event whose clock rings
first. If, before the clock rings, some other event changes the state so that
the precondition becomes false, the event is disabled and its clock is
discarded. There is no possibility of a stale event firing out of a state
where it no longer makes sense.

## The framework does not scan every event

It may sound as though the framework must check every precondition every time
anything fires, and in a naive implementation it would. ChronoSim avoids the
scan by requiring each event type to have *generators*: rules that say which
changes of state make it worth checking this event's precondition at all. You
can write generators by hand with the `@conditionsfor` macro:

```julia
@conditionsfor Move begin
    @reactto changed(agents[who].location) do state
        for direction in ALLDIRECTIONS
            generate(Move(who, direction))
        end
    end
end
```

This generator says that whenever any agent's `location` field changes, the
framework should propose `Move` events for that specific agent in every
direction. Proposed events are only candidates. Each one still has its
precondition checked, so a generator is allowed to propose too much; the cost
of an extra proposal is one wasted precondition call. What a generator must
never do is propose too little, because an event that is never proposed can
never become enabled, and the failure is silent.

Because the generator is really just the precondition's reads written
backwards, ChronoSim can usually write it for you. If you declare the
precondition with the `@precondition` macro instead of as a plain function,
the framework analyzes the body and derives the generators itself:

```julia
@precondition function precondition(event::Move, state)
    loc = state.agents[event.agent].location
    return state.location[loc + event.direction] == 0
end
```

For most events this removes the second artifact entirely, and it removes the
class of bugs where the precondition and its generators drift apart. The
[Generators](generators.md) page explains when the derivation applies, when
you still write `@conditionsfor` by hand, and how to write preconditions so
that the derivation does a precise job.

## The state is observed

Both of the mechanisms above depend on the framework knowing which parts of
the state are touched. ChronoSim therefore asks you to build your simulation
state from observed containers, declared with the `@observedphysical` and
`@keyedby` macros. Every field of the state then has an *address*, which is a
tuple naming the path to it, and every read or write of a field is recorded
under that address. When a firing function runs,

```julia
function fire!(event::Move, state, when, rng)
    state.location[state.agents[event.agent].location] = 0
    state.agents[event.agent].location += event.direction
    state.location[state.agents[event.agent].location] = event.agent
end
```

the framework records that addresses like `(:location, 12)` and
`(:agents, 7, :location)` were written. It compares those writes against the
recorded reads of every enabled event's precondition, so it knows exactly
which events to re-examine, and it hands the writes to the generators, so it
knows exactly which new events to propose. Nothing else in the simulation is
looked at. The [Simulation State](observedphysical.md) page shows how to
declare state, and it summarizes the small contract the containers uphold so
that this tracking is trustworthy.

## What you write for each event

To define one event type in a ChronoSim model, you provide the following
pieces.

- An immutable struct that subtypes `ChronoSim.SimEvent`. Its fields identify
  the actors and resources involved, so they are usually integers, symbols,
  enums, or strings. The struct can also be empty when the event concerns the
  system as a whole.
- A `precondition` function returning `Bool`. Declaring it with
  `@precondition` also produces the event's generators; declaring it plain
  means you must also write a `@conditionsfor` block by hand.
- An `enable` function that returns a distribution from Distributions.jl and
  the time from which that distribution is measured. There is an optional
  `reenable` for events whose rate should be recomputed when the state
  changes underneath them.
- A `fire!` function that changes the state when the event happens.

## Costs and payoffs

It is fair to say that this is more structure than a small hand-written
simulation needs, and the learning curve arrives all at once rather than
gradually. When a model misbehaves, there are several distinct pieces —
precondition, generator, rate, firing — where the mistake could live. The
compensation is that each piece is small, single-purpose, and checkable on
its own, and the framework can verify the pieces against each other: the set
of preconditions defines exactly which events should be enabled in any state,
which makes a strong global correctness check, and derived generators
eliminate the most silent failure mode outright.

The structure also pays for itself in ways that are hard to retrofit into a
hand-written loop. Events that stop making sense are cancelled exactly, not
ignored later, so there are no ghost firings. Independent models compose by
sharing state, with no glue code, because enabling flows through the state
rather than through direct calls. And because a ChronoSim model defines a
proper stochastic process, the framework can compute the log-likelihood of a
trajectory, which opens the door to model fitting, Bayesian inference, and
rare-event methods.
