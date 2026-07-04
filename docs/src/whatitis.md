# What This Framework Does

This page describes what actually happens when a ChronoSim simulation runs.
It is worth reading once before you write a model, because every piece you
write — the event structs, the preconditions, the rates, the firing
functions — corresponds to one step of the loop described here.

## One pass through the main loop

A ChronoSim simulation is a continuous-time simulation, which means events
fire one at a time at increasing real-valued times, and the state changes
only at those moments. Each pass through the main loop does the following.

1. The sampler chooses the next event. Every enabled event owns a clock whose
   ring time was drawn from the distribution its `enable` function supplied,
   and the sampler simply picks the clock that rings first. The chosen event
   is a small immutable value, such as `Repair(machine=3)`.
2. The framework calls that event's `fire!` function, which modifies the
   state. Because the state is built from observed containers, the framework
   comes away with the exact list of addresses that were written, such as
   `(:machines, 3, :status)`.
3. The framework then asks which events might care about those writes. Two
   groups answer. First, every currently enabled event whose precondition or
   rate previously read one of the changed addresses is re-examined. Second,
   the generators — whether written by hand with `@conditionsfor` or derived
   from a `@precondition` — propose brand-new candidate events that the
   changed addresses might have made possible.
4. Every event in those two groups has its `precondition` evaluated against
   the new state. An event that was enabled and is no longer justified is
   disabled and its clock discarded. An event that is newly justified is
   enabled, its `enable` function is called, and a fresh firing time is
   drawn. An event that remains enabled keeps its clock, unless the state it
   reads for its *rate* changed, in which case `reenable` lets it adjust its
   distribution without losing the time it has already waited.
5. The loop returns to step one.

The essential property of this loop is that nothing is scanned. The framework
never walks a list of all conceivable events. It touches exactly the events
that the changed addresses implicate, which is what lets a model consist of
many small events without the bookkeeping cost growing with the size of the
state.

## The pieces you provide

For each kind of event in your model, you define the following, and the list
maps one-to-one onto the loop above.

- An immutable struct subtyping `SimEvent`, whose fields identify which
  actor, place, or resource this instance of the event concerns. This is what
  the sampler chooses and what `fire!` receives.
- Generators, which serve step three. With `@precondition` they are derived
  from the enabling rule; with `@conditionsfor` you state them yourself.
- A `precondition` function, which serves step four by deciding enabling.
- An `enable` function returning a distribution and a reference time, which
  serves the sampler in step one, and optionally a `reenable` function for
  events whose rate must track a changing state.
- A `fire!` function, which serves step two.

## The components underneath

Four components implement the loop, and knowing their names helps when
reading the rest of the documentation.

1. **`ObservedState`** provides the containers and macros
   (`@observedphysical`, `@keyedby`, `ObservedArray`, `ObservedDict`,
   `ObservedSet`) that give every part of the state an address and report
   every read and write. This is what makes steps two and three possible.
2. **The generator machinery** (`@conditionsfor`, `@reactto`,
   `@precondition`, `@fragment`, `@domain`) turns changed addresses into
   proposed candidate events.
3. **[CompetingClocks.jl](https://github.com/adolgert/CompetingClocks.jl)**
   is the sampler. It holds one clock per enabled event, supports
   non-exponential distributions efficiently, and can report the likelihood
   of the trajectory it sampled, which is what enables statistical inference
   on top of a simulation.
4. **`SimulationFSM`** is the machine that runs the loop: it fires the event,
   applies any immediate events, collects the changed addresses, reconciles
   the enabled set, and hands control back to the sampler.
