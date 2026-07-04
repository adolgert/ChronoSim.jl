```@meta
CurrentModule = ChronoSim
```

# ChronoSim

[ChronoSim](https://github.com/adolgert/ChronoSim.jl) is a framework for
continuous-time, stochastic, discrete-event simulation. You describe a system
as a collection of events, where each event says when it makes sense to
happen, how long it waits before happening, and what it changes when it does.
The framework watches which parts of the state each event reads and writes,
and it uses that information to keep exactly the right set of events enabled
as the simulation runs.

Here is the shape of a single event, taken from a model of machines that
break and get repaired. A machine can only break while it is working, the
time until it breaks follows a Weibull distribution whose age is read from
the state, and breaking changes the machine's status.

```julia
struct Break <: SimEvent
    machine::Int64
end

@precondition function precondition(evt::Break, state)
    return state.machines[evt.machine].status == working
end

function enable(evt::Break, state, when)
    age = state.machines[evt.machine].work_age
    return (Weibull(2.0, 10.0), when - age)
end

function fire!(evt::Break, state, when, rng)
    state.machines[evt.machine].status = broken
end
```

That is the whole definition. The `@precondition` macro reads the enabling
rule and derives, automatically, the bookkeeping that tells the framework
when to reconsider this event: here, "whenever any machine's `status`
changes, check whether `Break` applies to that machine." You can also write
that bookkeeping by hand when you want precise control, and the
[Generators](generators.md) page of the manual explains both paths.

There are many good simulation tools, and the page
[Why Not Hand Made](not_chrono.md) discusses honestly when a hand-written
loop or another framework serves better. What ChronoSim contributes is the
combination of the following.

- **Exact sampling in continuous time.** Events fire one at a time at
  real-valued times drawn from the distributions you specify, including
  non-exponential ones, in the tradition of the generalized semi-Markov
  process and next-reaction samplers. Sampling is handled by
  [CompetingClocks.jl](https://github.com/adolgert/CompetingClocks.jl),
  which also makes trajectory likelihoods available for model fitting.
- **Automatic dependency tracking.** The state is observed, so the framework
  records every read a precondition makes and every write a firing makes. It
  re-examines an event only when something it actually depends on has
  changed, which is what makes many small, interacting events affordable.
- **Models compose through the state.** If one set of events moves people
  and another set spreads disease among them, the two sets coordinate
  through the shared state without either one naming the other.
- **The enabling logic is checkable.** Because every event carries an
  explicit precondition, the framework can verify invariants that hand-woven
  simulations leave implicit, and the model corresponds closely to a formal
  specification style such as TLA+.

## Where to go next

If you are new, read the [Introduction](intro.md) for the core concepts,
then work through [Getting Started](getting_started.md), which builds a
complete running simulation in about sixty lines. The
[Build an Elevator](elevator_tutorial.md) tutorial constructs a larger model
event by event and exercises every feature you would need to write a system
of your own. The Manual explains the [simulation state](observedphysical.md)
and [events and generators](events.md) precisely, and the Reference lists
every exported function and macro. The Development section documents the
internal contracts for contributors.
