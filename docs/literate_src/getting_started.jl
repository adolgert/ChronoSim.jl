# # Getting Started
#
# This page builds a complete, running simulation of five machines that
# break down and get repaired. It is short, but nothing is left out: by the
# end you will have declared observed state, defined two events, run the
# simulation, and looked at the trajectory it produced. The
# [Build an Elevator](elevator_tutorial.md) tutorial then does the same
# thing for a larger model with more kinds of events.
#
# First the imports. A model imports the framework, the state-declaration
# module, and the specific functions it will add methods to. Distributions
# supplies the waiting-time distributions, and Random supplies the seeded
# generator.

using ChronoSim
using ChronoSim.ObservedState
import ChronoSim: precondition, enable, fire!, generators
using Distributions
using Random

# ## The state
#
# A machine is either working or broken. The state of the whole factory is
# a vector of machines. We declare the element type with `@keyedby`, naming
# the type, the index type it will have inside its container, and its
# fields. Then we declare the state itself with `@observedphysical`. These
# macros are what let the framework observe every read and write, which is
# how it knows which events to reconsider after each firing.

@enum MachineStatus working broken

@keyedby Machine Int64 begin
    status::MachineStatus
end

@observedphysical Factory begin
    machines::ObservedVector{Machine,Member}
end

# The vector of machines has a fixed length for the whole run, which is
# exactly what an `ObservedVector` requires. We allocate it, fill it, and
# wrap it in the state.

function make_factory(machine_count)
    machines = ObservedArray{Machine,Member}(undef, machine_count)
    for i in eachindex(machines)
        machines[i] = Machine(working)
    end
    return Factory(machines)
end
nothing #hide

# ## The events
#
# A machine that is working can break. The precondition states exactly
# that, and nothing else. Because we declare it with `@precondition`, the
# framework derives the event's generators from the body: any change to any
# machine's `status` field will propose a `Break` event for that machine.

struct Break <: SimEvent
    machine::Int64
end

@precondition precondition(evt::Break, factory) = factory.machines[evt.machine].status == working

# The `enable` function gives the waiting time until the event fires,
# counted from the moment the precondition became true. A Weibull
# distribution with shape greater than one means machines fail more often
# as they age since their last repair.

enable(evt::Break, factory, when) = (Weibull(2.0, 5.0), when)

# Firing is the only place the state changes.

fire!(evt::Break, factory, when, rng) = factory.machines[evt.machine].status = broken

# A machine that is broken can be repaired. The three definitions have the
# same shape.

struct Repair <: SimEvent
    machine::Int64
end

@precondition precondition(evt::Repair, factory) = factory.machines[evt.machine].status == broken

enable(evt::Repair, factory, when) = (Exponential(1.0), when)

fire!(evt::Repair, factory, when, rng) = factory.machines[evt.machine].status = working

# ## Running
#
# The simulation is assembled from the state and the list of event types.
# The observer is a function the framework calls after every firing; here
# it appends the event and its time to a record.

trajectory = Tuple{Tuple,Float64}[]
observe(factory, when, event, changed) = push!(trajectory, (clock_key(event), when))

factory = make_factory(5)
sim = SimulationFSM(factory, [Break, Repair]; seed=979797, observer=observe)
nothing #hide

# The initializer runs at time zero. It must *write* the parts of the state
# that events depend on, not merely rely on the constructor having set
# them, because it is these initial writes that propose the first candidate
# events. Here, writing every machine's status proposes a `Break` for every
# machine, each precondition passes, and five failure clocks start running.

start_all_working(factory, when, rng) =
    for i in eachindex(factory.machines)
        factory.machines[i].status = working
    end
nothing #hide

# The stop condition sees the event that is about to fire, before it fires,
# so stopping at a time boundary is exact.

stopping(factory, step, event, when) = when > 20.0

ChronoSim.run(sim, start_all_working, stopping)
trajectory

# Each entry is the fired event's clock key and its firing time. Machines
# break, repairs follow, and the two event types alternate per machine, at
# irregular continuous times.
#
# ## What the derivation did
#
# We never said when to check whether a `Break` could happen; the
# `@precondition` macro worked that out from the enabling rule. You can ask
# it to show its work:

using ChronoSim: derivation_report
derivation_report(Break)

# The report says there is one trigger, listening on the pattern
# `machines[i].status`, and that a change there proposes `Break(i)` for the
# specific machine whose status changed. When your preconditions get more
# involved, this report is the first thing to look at, and the
# [Generators](generators.md) page of the manual explains everything it can
# say.
