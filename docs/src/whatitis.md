# What This Simulation Framework Does

## High-level of what defines an event

This is a continuous-time simulation, which means only one event happens at
at time. This simulation framework structures the firing of an event so that each event maintains responsibility for its own correct behavior given the state of the system.

 1. The next event is chosen by a Sampler. That event contains a type and a tuple of event-specific identifiers.
 1. The `fire!()` function for that event is called. This `fire!()` function modifies the state.
 1. All events register to react to specific previous events or specific changes to the state of the system. It's an observer pattern where each field within the state gets its own key. Each event registered to respond to the actions of the `fire!()` function will be called.
 1. For each of those events, it runs its `precondition()` function to see whether it really should be enabled. If so,
 1. All enabled events decide, given the current state and time, the distribution of future times at which they could `fire!()`.
 1. The system returns to the top of the loop.

As a result, for each event we define:

 * An immutable struct type that functions as an Event Key.
 * A `@conditionsfor` macro that says which events and states this event reacts to.
 * A `precondition()` function that returns `true` if this event could fire.
 * An `enable()` function that returns a distribution of times.
 * An optional `reenable()` function for events that change their rates if the state changes.
 * A `fire!()` function where the event changes the state.

## Components in the ChronoSim framework

There are four main components of the ChronoSim framework that make simulations possible.

 1. `ObservedState` gives you a way to define a struct containing vectors or dictionaries of structs so that any read from or write to that struct can be observed with a subject-observer kind of pattern.

 1. `EventGenerator` is a small macro language to make it easier to observe changes to the state or previous events and generate candidate events that might be enableable.

 1. [CompetingClocks.jl](https://github.com/adolgert/CompetingClocks.jl) handles sampling which event is next, optimizing this process for different types of distributions. This also provides the ability to compute likelihoods so that you can do Markov Chain Monte Carlo with a simulation.

 1. The main ChronoSim `SimulationFSM` is a [finite-state machine](https://en.wikipedia.org/wiki/Moore_machine) for firing an event, applying immediate events, tracking state changes, updating reenabled events, disabling events whose precondition no longer is true, and enabling new events.
