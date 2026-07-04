# Where ChronoSim Fits

ChronoSim does not sit squarely inside any one of the traditional categories
of simulation. This page places it relative to the styles and results it
draws on, for readers who know some of that literature and want to orient
themselves. Nothing here is needed to write a model.

## Exact, stochastic, continuous time

The sampling is exact continuous-time sampling of competing clocks. This
family of algorithms is often called Gillespie sampling, though first-to-fire
sampling from a heap predates Gillespie's papers, and the method is not
specific to chemistry. ChronoSim delegates sampling to
[CompetingClocks.jl](https://github.com/adolgert/CompetingClocks.jl), which
implements several exact samplers, including next-reaction variants in the
lineage of Gibson and Bruck (2000).

## The generalized semi-Markov process

The stochastic process a ChronoSim model defines is closest to a generalized
semi-Markov process (GSMP), the formalism surveyed by Glynn (1989). A GSMP
has a physical state and a set of clocks, each clock running down toward a
transition at a rate that may depend on the state, and each transition
changing part of the state. ChronoSim borrows the GSMP's separation between
physical state and clock state, and even the phrase "physical state." Where
a classical GSMP fixes the dependency structure between states and clocks in
advance, ChronoSim discovers it while the simulation runs, by observing what
each precondition and rate function actually reads.

Anderson and Kurtz's treatment of continuous-time processes as coupled
counting processes (*Stochastic Analysis of Biochemical Systems*, Springer,
2015) showed that the sampling machinery can be separated cleanly from the
model: a sampler needs only the enabling times and distributions of the
clocks. That observation is what allows CompetingClocks.jl to exist as an
independent, testable package, with all model logic remaining in ChronoSim.

## Stochastic Petri nets

A generalized stochastic Petri net (GSPN) declares its dependency structure
graphically: transitions consume and produce tokens at places, so the net
itself says which transitions to reconsider when a place changes, and
properties such as reachability can be computed from the graph. The cost is
that the graph must be constructed up front, which becomes burdensome when
the state is large and heterogeneous — a population stratified by age, sex,
location, and disease state multiplies into a very large net. ChronoSim
keeps the useful part of the GSPN idea, the place-to-transition dependency
graph, but builds it dynamically from observed reads and writes, and it
allows immediate transitions in the same sense a GSPN does. What it gives up
is the ability to analyze the whole graph before running.

## Survival analysis, actuarial and reliability modeling

Actuaries and reliability engineers care that simulated event times honor
estimated hazard rates, including hazards that accumulate with age or
exposure. ChronoSim's `enable` function returns a distribution together with
the time from which it is measured, which is the mechanism for expressing
accumulated hazard, and the framework's likelihood support exists so that a
simulation can be fit to data with the same seriousness those fields apply.
One way to describe the project is as survival analysis run forward.

## Agent-based simulation

Agent-based modeling is a way of stating invariants — an agent persists, is
somewhere, and acts — rather than a distinct mathematical object, and
agent-based models can be written in ChronoSim by making events that respect
those invariants. If your model is naturally a synchronous-update agent
model, a dedicated framework such as
[Agents.jl](https://juliadynamics.github.io/Agents.jl/stable/) will serve
you better; the comparison page [Why Not Hand Made](not_chrono.md) says more
about when ChronoSim is and is not the right tool.

## Formal specification

An event defined by a precondition and an action reads very much like a TLA+
action, and the resemblance is useful rather than accidental: both designs
take the position that a system is best described by when its transitions
are allowed and what they change. The elevator example in the test suite
exports its trajectories for checking against a TLA+ specification, which is
a practical benefit of keeping the two vocabularies close.

## Summary

ChronoSim is exact, stochastic, continuous-time simulation with time-varying
hazards and immediate transitions, over a GSMP-style state, with the
GSPN-style dependency graph recovered dynamically from ordinary model code
rather than declared up front.
