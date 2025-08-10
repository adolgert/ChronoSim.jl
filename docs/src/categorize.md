# Category of Simulation

## Introduction

The ChronoSim.jl simulation framework doesn't fit exactly into some of the major categories of simulation. For those who want to understand ChronoSim.jl in relation to other simulation styles, and for those who think about how we express simulations, this section places ChronoSim.jl in the context of known simulation styles.

## Exact, Stochastic, Continuous-time

The sampling algorithms used are exact, continuous-time sampling. Wikipedia calls these algorithms [Gillsepie Algorithms](https://en.wikipedia.org/wiki/Gillespie_algorithm), but I would argue that is a misnomer because a simple heap-based first-to-fire style of sampling is an exact sampling of one of these systems, and this method was known well before Gillespie. It was known before Doob's algorithm, which was also before Gillespie.

## The Generalized Semi-Markov Process

Simulations in ChronoSim.jl define a stochastic process. The closest analog to that stochastic process is a Generalized Semi-Markov Process (GSMP). A GSMP defines a set of states, ``p_i``, indexed by ``i``. It defines a set of stochastic processes where each stochastic process depends on a subset of the ``p_i``. We would now call these individual counting processes. In the GSMP, each counting process proceeds according to a clock rate, which is the hazard rate of a distribution.

Each event in an GSMP changes a subset of the state. If you zoom out, you can ask how the whole state, all of the ``p_i``, change when a single process fires. This defines a transition for the system as a whole. Zooming out like this shows the GSMP defines a semi-Markov process, which is a Markov process that doesn't limit the distribution of times between jumps to being Exponentially-distributed.

The state of a GSMP is its *physical states*, the ``p_i``, and the state of each clock, which is the time it has run down. ChronoSim borrows this name "physical state."

The GSMP was a fantastic invention in its day. It used the crutch of the substates, ``p_i``, to give the processes a way to be long-lived when other processes in the system fired. The dependency graph between substates and transitions became what Gibson and Bruck called a reaction graph in the Next Reaction method in 2000.

## Using Anderson and Kurtz to Pull Out Samplers

There is a book by Anderson and Kurtz, called <i>Stochastic Analysis of Biochemical Systems</i>, Springer 2015, that clarifies what defines a minimal continuous-time process and its sampler. In that book, they take all of the history of how to define the state of a continuous-time stochastic simulation and throw it out the window. All that's left is the sequence of events and times that record jumps in a set of counting processes. They call it a "filtration" in this probabilistic context.

What was important for ChronoSim.jl is that Anderson and Kurtz showed that all of the sampling machinery can be pulled out of the simulation. Only the states and times of each counting process need to be known to the sampler. That's enough to make a complete, highly-optimized sampler in CompetingClocks.jl while pulling out into the ChronoSim framework the logic of what happens when an event fires.

## Generalized Stochastic Petri Nets

The Generalized Stochastic Petri Net (GSPN) was popular in the 1990's and more popular after 2000 when Gibson and Bruck's work (and the uncited work of Kurtz) contributed to the speed of sampling.

A GSPN is a set of Places where a place can hold one or more Tokens. A token can be represent presence or absence at a place, or a token can be "colored," which means it carries state. Think of it as a struct. The placement of tokens on places defines a Marking, and a Marking defines the physical state of the system. Transitions take tokens as input and produce tokens. They specify which tokens they consume and produce through a graph that connects transitions to places and an annotation on that graph indicating how many tokens are consumed or produced from each place.

You can use a GSPN to define a chemical simulation. It doesn't take much work. You need to use a specific formula for how the rate of a reaction (transition) depends on the number of molecules (tokens) of each chemical species (place).

Theoreticians love GSPN because the whole graph of the simulation is laid bare. It's created and initialized before the simulation runs. It's a simple mathematical trick to calculate *reachability* of a future state from the current state. For instance, given the current state, it is possible for the system to arrive in a state that is a failure mode? It's great for safety guarantees.

The big problem with GSPN is that they are burdensome to create. To quote Bryan Grenfell, "We tried that back then and it was awful." If you create a model with individuals stratified by age, by sex, by location, and by disease state, you've created a combinatorially large simulation with lots of careful coding required.


## Letting go of some rules

If we agree that we don't necessarily need to compute an exact reachability graph for a simulation, then we can let go of a lot of the pain of a GSPN.

ChronoSim.jl builds a GSPN-style bipartite graph of places and events on the fly as it computes a simulation. It watches the `precondition()` functions to record what state a event depends on. It watches the `enable()` functions to record what events the rate of a event depends on. When a event fires, the list of changes to state are compared against the list of dependencies of all existing, currently-enabled events in order to update their enabling and rates. ChronoSim.jl tries to side-step the pain points of GSPN by making generation of dependencies *dynamic.*

It also becomes easy to implement immediate events. These are events that fire at the same time as the timed event. If we think of the system as one semi-Markov process, the transition of that semi-Markov state is calculated from the timed event and all immediate events together.

In a GSPN, the enabling of transitions depends only on the state. That's the only way to do it. If we instead take Anderson and Kurtz as our guide, it's clear that the events are the least, complete description of the history of the system. There is no reason not to include the ability to trigger the next event based on the previous event, so that is included in ChronoSim.jl as a possibility.

## Agent-based

From the perspective above, agent-based simulation can be done with any of the above methods. What makes a simulation agent-based is the imposition of the invariants on the system. For instance, if we make a rule that a rabbit is in a field, the invariant that makes the simulation agent-based would be that the rabbit doesn't disappear and reappear.

Whether a simulation made with ChronoSim.jl is agent-based depends on what you define in the simulation. It's not intrinsic to the simulation framewor. It's also not difficult to implement.

## Formal methods

The way ChronoSim.jl defines events looks so much like [TLA+](https://learntla.com/) that it looks like a transliteration. It started from Anderson and Kurtz's probability theory, not from TLA+. The convergence is just a sign of similar good taste.

## Conclusion

ChronoSim.jl is

 * Exact, stochastic, continuous-time sampling.
 * Process-interaction models, maybe more properly called state-mediated.
 * With time-varying hazards and immediate transitions.
 * Generating transitions dynamically.
