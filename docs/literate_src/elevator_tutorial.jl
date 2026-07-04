# # Build an Elevator
#
# This tutorial builds a model of one elevator serving a small building,
# event by event. It is longer than [Getting Started](getting_started.md)
# because it deliberately runs into the situations a real model runs into:
# an event that concerns the whole system rather than one entity, a
# precondition that needs a helper function, one event's enabling rule
# defined in terms of another's, and a generator written by hand so you can
# see what the automatic ones replace. When you finish, you will have seen
# every technique needed to write a model of your own. The full two-car
# elevator that this model is reduced from lives in the
# [ChronoSimExamples.jl](https://github.com/adolgert/ChronoSimExamples.jl)
# repository, alongside an epidemic model, if you want larger worked
# examples.

using ChronoSim
using ChronoSim.ObservedState
import ChronoSim: precondition, enable, fire!, generators
using Distributions
using Random

# ## The state
#
# The building has several people, one call button per floor, and a single
# elevator car. A person is on a floor (with zero meaning they are riding
# the car), has a destination, and may be waiting for the car. A call
# button is either requested or not.

@keyedby Person Int64 begin
    floor::Int64
    destination::Int64
    waiting::Bool
end

@keyedby Call Int64 begin
    requested::Bool
end

# The people live in a fixed-length vector, since nobody enters or leaves
# the building during a run. The call buttons live in a dictionary keyed by
# floor number. The car itself is just two values, so rather than invent a
# struct for it we store its floor and door state as plain scalar fields,
# which the framework tracks at the granularity of the whole field.

@observedphysical Building begin
    people::ObservedVector{Person,Member}
    calls::ObservedDict{Int64,Call,Member}
    car_floor::Int64
    car_open::Bool
    floor_cnt::Int64
end

function make_building(people_count, floor_count)
    people = ObservedArray{Person,Member}(undef, people_count)
    for i in eachindex(people)
        people[i] = Person(1, 1, false)
    end
    calls = ObservedDict{Int64,Call,Member}()
    for floor in 1:floor_count
        calls[floor] = Call(false)
    end
    return Building(people, calls, 1, false, floor_count)
end
nothing #hide

# ## A first event, with its generator written by hand
#
# A person who is standing on their destination floor eventually decides to
# go somewhere else. To show what generators are, we write this first event
# the manual way: a plain `precondition` function plus a `@conditionsfor`
# block that tells the framework when the precondition is worth checking.

struct PickDestination <: SimEvent
    person::Int64
end

function precondition(evt::PickDestination, building)
    person = building.people[evt.person]
    return person.floor != 0 && !person.waiting && person.destination == person.floor
end

@conditionsfor PickDestination begin
    @reactto changed(people[who].floor) do building
        generate(PickDestination(who))
    end
    @reactto changed(people[who].destination) do building
        generate(PickDestination(who))
    end
    @reactto changed(people[who].waiting) do building
        generate(PickDestination(who))
    end
end

# Each `@reactto changed(...)` rule names a pattern of state addresses.
# When any write matches the pattern, the rule runs with the wildcard
# (here `who`) bound to the index from the written address, and it proposes
# candidate events with `generate`. Proposals are cheap: each one is
# filtered through the precondition, so proposing too much wastes a boolean
# check, while proposing too little silently loses behavior.
#
# Notice that the three rules correspond exactly to the three fields the
# precondition reads. That is not a coincidence, and it is the reason the
# manual block is usually unnecessary: the generator is the precondition's
# read set, restated. Writing it by hand means keeping the two in sync
# forever. For the remaining events we will let the `@precondition` macro
# derive the generators, and you can mix the two styles freely across the
# events of one model, as we have just done.
#
# The rest of `PickDestination` is its rate and its effect. People decide
# to travel with a mean waiting time of ten minutes, and the new
# destination is a uniformly chosen different floor. Note that `fire!`
# draws from the `rng` argument, never from a global generator, so that
# runs are reproducible.

enable(evt::PickDestination, building, when) = (Exponential(10.0), when)

function fire!(evt::PickDestination, building, when, rng)
    person = building.people[evt.person]
    choices = [f for f in 1:building.floor_cnt if f != person.floor]
    person.destination = rand(rng, choices)
end

# ## Calling the car
#
# A person on a floor, not yet waiting, whose destination is elsewhere,
# presses the call button. This precondition is declared with
# `@precondition`, so its generators are derived: any change to a person's
# `floor`, `destination`, or `waiting` field proposes `CallCar` for that
# person, which is precisely the hand-written block above, produced
# mechanically.

struct CallCar <: SimEvent
    person::Int64
end

@precondition function precondition(evt::CallCar, building)
    person = building.people[evt.person]
    return person.floor != 0 && !person.waiting && person.destination != person.floor
end

enable(evt::CallCar, building, when) = (Exponential(0.5), when)

function fire!(evt::CallCar, building, when, rng)
    person = building.people[evt.person]
    person.waiting = true
    building.calls[person.floor].requested = true
end

# ## Moving the car, with a helper function
#
# The car should move when the doors are shut and somebody, somewhere,
# wants it to be somewhere else: a pressed call button on another floor, or
# a rider whose destination is another floor. That "somebody, somewhere" is
# a scan over the state, and it reads naturally as a helper function.
#
# A helper that receives state must be marked with `@fragment`. The mark
# changes nothing about how the function runs; it registers the function's
# body so that the `@precondition` analysis can look inside it. An unmarked
# helper that receives state is a macro-time error, because the analysis
# refuses to guess what a function it cannot see might read.

@fragment function wants_car_elsewhere(calls, people, here)
    for (floor, call) in calls
        if call.requested && floor != here
            return true
        end
    end
    for p in eachindex(people)
        if people[p].floor == 0 && people[p].destination != here
            return true
        end
    end
    return false
end

# The event itself has no fields, because it concerns the single shared
# car rather than any person.

struct MoveCar <: SimEvent end

@precondition function precondition(evt::MoveCar, building)
    return !building.car_open &&
           wants_car_elsewhere(building.calls, building.people, building.car_floor)
end

enable(evt::MoveCar, building, when) = (Exponential(0.5), when)

function fire!(evt::MoveCar, building, when, rng)
    targets = Int[]
    for (floor, call) in building.calls
        call.requested && push!(targets, floor)
    end
    for p in eachindex(building.people)
        person = building.people[p]
        person.floor == 0 && push!(targets, person.destination)
    end
    isempty(targets) && return nothing
    nearest = targets[argmin(abs.(targets .- building.car_floor))]
    building.car_floor += sign(nearest - building.car_floor)
end

# Two things are worth noticing here. First, the scans inside the helper
# read people and calls at loop indices, so the derivation cannot tell from
# a changed address which `MoveCar` instance to propose — but `MoveCar` has
# no fields, so there is only one instance, and the derived trigger simply
# proposes it whenever any call or any person's floor or destination
# changes. Second, `fire!` also scans the state, and that needs no
# `@fragment` and no care at all, because only preconditions are analyzed;
# firing functions just run, and the framework records what they write.

# ## Opening the doors
#
# The car opens its doors when it is at a floor where the button is
# pressed, or where a rider wants to get off. Reading
# `building.calls[building.car_floor]` indexes a container by *state*
# rather than by an event field, which is fine: the derivation widens that
# trigger, meaning a change to any call button proposes the (single)
# `OpenDoors` event and the precondition decides.

@fragment function rider_arriving(people, here)
    for p in eachindex(people)
        if people[p].floor == 0 && people[p].destination == here
            return true
        end
    end
    return false
end

struct OpenDoors <: SimEvent end

@precondition function precondition(evt::OpenDoors, building)
    return !building.car_open && (
        building.calls[building.car_floor].requested ||
        rider_arriving(building.people, building.car_floor)
    )
end

enable(evt::OpenDoors, building, when) = (Exponential(0.1), when)

function fire!(evt::OpenDoors, building, when, rng)
    building.car_open = true
    building.calls[building.car_floor].requested = false
end

# ## Boarding and exiting
#
# These two are straightforward person-keyed events in the same style as
# `CallCar`. A waiting person on the car's floor boards while the doors are
# open; a rider whose destination is the car's floor steps out.

struct Board <: SimEvent
    person::Int64
end

@precondition function precondition(evt::Board, building)
    person = building.people[evt.person]
    return building.car_open && person.waiting && person.floor == building.car_floor
end

enable(evt::Board, building, when) = (Exponential(0.05), when)

function fire!(evt::Board, building, when, rng)
    person = building.people[evt.person]
    person.floor = 0
    person.waiting = false
end

struct Exit <: SimEvent
    person::Int64
end

@precondition function precondition(evt::Exit, building)
    person = building.people[evt.person]
    return building.car_open && person.floor == 0 && person.destination == building.car_floor
end

enable(evt::Exit, building, when) = (Exponential(0.05), when)

fire!(evt::Exit, building, when, rng) = building.people[evt.person].floor = building.car_floor

# ## Closing the doors, by asking other preconditions
#
# The doors should close when nobody can board and nobody can exit. We
# could restate those two conditions inline, but they already exist: they
# are the preconditions of `Board` and `Exit`. A `@precondition` body may
# call another event's `precondition` directly, and the analysis follows
# the call, so the derived generators for `CloseDoors` know about every
# address that `Board` and `Exit` read. The `any(... for ...)` form is
# analyzed like a loop.

struct CloseDoors <: SimEvent end

@precondition function precondition(evt::CloseDoors, building)
    return building.car_open &&
           !any(precondition(Board(p), building) for p in eachindex(building.people)) &&
           !any(precondition(Exit(p), building) for p in eachindex(building.people))
end

enable(evt::CloseDoors, building, when) = (Weibull(2.0, 0.5), when)

fire!(evt::CloseDoors, building, when, rng) = building.car_open = false

# One ordering rule applies here: because `CloseDoors` refers to the
# preconditions of `Board` and `Exit`, those two must be declared with
# `@precondition` earlier in the file, which they were.

# ## Running the model

trajectory = Tuple{Tuple,Float64}[]
record(building, when, event, changed) = push!(trajectory, (clock_key(event), when))

building = make_building(4, 5)
sim = SimulationFSM(
    building,
    [PickDestination, CallCar, MoveCar, OpenDoors, Board, Exit, CloseDoors];
    seed=90210,
    observer=record,
)
nothing #hide

# The initializer writes every field that events depend on. Construction
# alone is not enough, because it is the recorded *writes* that propose the
# first candidate events: writing each person's fields proposes their
# `PickDestination`, and writing the car's fields proposes the car events.

function settle_in(building, when, rng)
    for i in eachindex(building.people)
        floor = rand(rng, 1:building.floor_cnt)
        building.people[i].floor = floor
        building.people[i].destination = floor
        building.people[i].waiting = false
    end
    building.car_floor = 1
    building.car_open = false
end

stopping(building, step, event, when) = when > 120.0

ChronoSim.run(sim, settle_in, stopping)
length(trajectory)

# A couple of hours of building life. Here are the first dozen firings.

first(trajectory, 12)

# ## Inspecting what the derivation built
#
# Every derived event can print its triggers. `MoveCar` is the interesting
# one, because everything it depends on arrives through the helper.

using ChronoSim: derivation_report
derivation_report(MoveCar)

# The report shows widened triggers on the call buttons and on people's
# fields, plus triggers on the two scalar car fields. Widened proposals are
# filtered by the precondition, and if you want to know what that filtering
# costs, the framework will count it for you:

using ChronoSim: collect_generation_stats, generation_stats, reset_generation_stats!

reset_generation_stats!()
collect_generation_stats(true)
trajectory2 = Tuple{Tuple,Float64}[]
sim2 = SimulationFSM(
    make_building(4, 5),
    [PickDestination, CallCar, MoveCar, OpenDoors, Board, Exit, CloseDoors];
    seed=90210,
    observer=(b, t, e, c) -> push!(trajectory2, (clock_key(e), t)),
)
ChronoSim.run(sim2, settle_in, stopping)
collect_generation_stats(false)
generation_stats()

# Each event type lists how many candidates its generators proposed and how
# many passed their precondition. Where the ratio is large and the model is
# slow, a hand-written `@conditionsfor` with tighter proposals is the
# remedy, and the [Generators](generators.md) page discusses that
# trade-off.
#
# Note also that the second run produced the same trajectory as the first,
# because the two simulations used the same seed:

trajectory2 == trajectory

# ## Where to go from here
#
# You have now used every mechanism a typical model needs: observed state
# in vectors, dictionaries, and scalar fields; derived generators; a
# hand-written generator; `@fragment` helpers; precondition reuse; and the
# inspection tools. The [Events](events.md) and [Generators](generators.md)
# manual pages state precisely what each piece requires, and the models in
# ChronoSimExamples.jl show the same techniques at full scale, including an
# epidemic model whose population events (`SIRVillage`) make a good
# template for models of interacting individuals.
