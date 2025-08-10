# How Event States are Updated

The main loop of the framework for simulation will fire an event, look at changed places, and then update the events in the system. This turns is complicated, so let's discuss it here.

An event has

 * A key which identifies its relationship to physical state.
 * A set of places upon which its precondition depends.
 * A set of places upon which its rate depends.
 * A rate (distribution in time) that is set in the Sampler by the enable() function.

The same event key, when applied to a different physical state, may depend on different sets of places. This is not true for a traditional GSPN or GSMP, but it's how we think about events. For instance, a Move(agent_idx, right_direction) will depend on space to the right of the agent, but which space must be empty changes as the agent moves.

A simulation has:

 * A set of enabled events.
 * The event that just fired.
 * A set of states that were modified when the event fired.

The goal of the main loop of the simulation, once it has fired the event is to modify:

 * The set of enabled events, by disabling those with failed preconditions or enabling those generated.
 * The set of places upon which precondition or rates depends for affected events.
 * The rate of events for which their place dependencies changed in value or for which the set of places has changed.

Before and after this update, what can the states of an event be?

 * Disabled -> enabled and enabled -> disabled.
 * Sets of places can change.
 * Maybe just the rate is called again.

The notion of re-enabling is a little tough. I will define that any time an event with the same clock key is enabled before and after firing, and the rate-depending places have changed, it is re-enabled. That's a firm definition. Rate-depending places can be a different set of places or they can have been written to. Either way.

What sets of events do we have?

 * The set of all events that depend on ANY changed places.
 * The set of those events whose preconditions still hold.
 * The set of those whose preconditions hold but they depend on different places.
 * The set of those whose rates depend on ANY changed places.

Let's process the data this way, not an event at a time but a set of events at a time.

A question: When rules generate new events, they don't need to create existing events. If we just discovered an event is disabled, that too can be excluded. My question is whether the set of all generated events intersected with the set of enabled events is contained in the set of affected events.

  (generated events) ∩ (enabled events) ⊆ (affected event preconditions)

The practical answer is that there aren't restrictions on event generation. The generator functions could generate lots of extra events, so there is no guarantee that those related to the recent modified places are all we will see.
