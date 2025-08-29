# Introduction

## Core scheduling paradigm

Every simulation framework has a way to decide what events happen next, a core scheduling paradigm. For ChronoSim, every event has one rule for when it is eligible to happen, a `precondition`. Here's an example for a movement event.

```julia
function precondition(event::Move, state)
	loc = state.agents[event.agent].location
	return state.location[loc + event.direction] == 0
end
```
As soon as that event returns `true`, the event becomes enabled, which means it will fire at a future time determined by a probability distribution. If that `precondition` later becomes `false`, the event becomes disabled. The precondition associated with an event determines whether it can fire, and the moment that's true, it calls `enable`.

```julia
enable(event::Move, state, time) = (Weibull(2, 1.0), time)
```
That tells the framework that the the time between enabling this event and firing it will follow a Weibull distribution.


## Event proposal generation

It may sound like this framework checks the precondition for every event every time a previous event fires, but it is careful about when it checks preconditions. You have to provide an event with an event generator that proposes when a precondition could possibly be true.

```julia
@conditionsfor Move begin
	@reactto changed(agent[who].location) do state
		for direction in ALLDIRECTIONS
			generate(Move(who, direction))
		end
	end
end
```

This event generator watches the state, in a subject-observer pattern, to see when an agent's location changed. In this example, the generator creates new possible events for that specific agent. The generator can be over-eager when it suggests possible events because each possible event's precondition will make the right call.


## Automatic dependency inference

The framework tracks how causality moves from event to event through the state. When an event fires, such as our Move event, it changes the state.

```julia
function fire!(event::Move, state, when, rng)
	state.location[state.agent[event.who].location] = 0
	state.agent[event.who].location += event.direction
	state.location[state.agent[event.who].location] = event.who
end
```

Each time this `fire!` function sets a value in the state, the address of that part of the state is recorded, here `(:location, <locindex>)` and `(:agent, <agentidx>, :location)`. Any other event whose generator is listening for modifications at these addresses will generate relevant events.

Similarly, the framework watches each call to read the state during a `precondition()` in order to know which state changes should trigger a re-check on whether that `precondition()` remains true. The framework watches each call to an `enable()` to determine which changes of the state at a later time might require re-evaluating the rate of the distribution for when the event fires.


## Put it together

In order to define a single event in a system, you have to provide:

 * An immutable struct for that event that derives from `ChronoSim.SimEvent`. This struct can be empty but usually contains integers, symbols, enums, or strings that identify actors and resources.

 * A generator that watches for changes to state or previously-fired events that indicate that this event might possible be enabled.

 * A precondition for this event.

 * An enabling rate, which returns a continuous, univariate distribution from Distributions.jl. There can be an optional re-enabling function defined if that's significantly different.

 * A `fire!` function to change the state when this event happens.


## Challenges

 * That's a lot to define if you're doing a simple simulation.

 * There isn't a slow-start learning curve for this.

 * If the simulation doesn't run as planned, there are lots of moving parts that could be wrong.

 * Maybe generating extra events is costly?

This style of simulation has the same number of possible problems as other simulations, but they are more visible. You'll see it's easier to check correctness when the logic of discrete events is separated into the parts above.

The generation of extra events isn't any worse than a normal for-loop when you create a new event. It's just broken into a generator and a separate checker, so it feels like it costs more.

## Advantages

 - Model checking. The set of preconditions defines what events should be enabled at any time in the simulation. Checking all preconditions is a great correctness check. The model itself also has a strong correspondence to TLA+ models.

 - Canceling ghost events. There are cases where firing one event makes another event no longer relevant. Some simulations deal with these ghost events by ignoring them later, but they can create confusion when an event is enabled, then ghosted, then should be enabled again. This simulation is clear about canceling events whose preconditions are no longer met.

 - Composition of models through the state dependencies. If you make a model of how people move and then a model of how disease spreads, you don't need to modify those models in order to compose them. Because each model's events are enabled by state changes, they will implicitly share resources correctly, where in this example the resources are the location and health states of people.

 - This framework can calculate log-likelihood for model-fitting and uncertainty quantification, Bayesian inference, and rare event simulation. It defines a stochastic process.
