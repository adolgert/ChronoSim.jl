module ElevatorExample

using ChronoSim
using ChronoSim.ObservedState
using ChronoSim: precondition, enable, fire!
@enum ElevatorDirection Up Down Stationary


@keyedby Person Int64 begin
    location::Int64
    destination::Int64
    waiting::Bool
end

@keyedby Call Tuple{Int64,Bool} begin
    direction::ElevatorDirection
end

@keyedby Elevator Int64 begin
    floor::Int64
    direction::ElevatorDirection
    doorsOpen::Bool
    buttons_pressed::Set{Int64}
end


@observedphysical ElevatorSystem begin
    person::ObservedVector{Person}
    # Floor and direction, true is up, false is down.
    calls::ObservedDict{Tuple{Int64,Bool},Call}
    elevator::ObservedVector{Elevator}
    floor_cnt::Int64
    people_cnt::Int64
end


struct PickNewDestination <: SimEvent
    person::Int64
end

@conditionsfor PickNewDestination begin
    @reactto changed(person[who].location) begin
        system
        generate(PickNewDestination(who))
    end
end

function precondition(evt::PickNewDestination, system)
    person = system.person[evt.person]
    return !person.waiting && person.location == person.destination
end

enable(evt::PickNewDestination, system, when) = (Exponential(1.0), when)

function fire!(evt::PickNewDestination, system, when, rng)
    dests = Set(collect(1:floor_cnt))
    delete!(dests, evt.person.location)
    system.person[evt.person].destination = rand(rng, dests)
end

struct CallElevator <: SimEvent
    person::Int64
end

@conditionsfor CallElevator begin
    @reactto changed(person[who].waiting) begin
        system
        generate(CallElevator(who))
    end
end

function precondition(evt::CallElevator, system)
    person = system.person[evt.person]
    return person.location != person.destination && !person.waiting
end

enable(evt::CallElevator, system, when) = (Exponential(1.0), when)

function fire!(evt::CallElevator, system, when, rng)
    person = system.person[evt.person]
    person.waiting = true
    dests = Set(collect(1:floor_cnt))
    delete!(dests, evt.person.location)
    person.destination = rand(rng, dests)
    direction = if person.destination < person.location
        Down
    else
        Up
    end
    system.calls[(person.destination, direction)] = true
end


struct OpenElevatorDoor
    elevator_idx::Int64
end

@conditionsfor OpenElevatorDoor begin
    @reactto changed(elevator[elidx].direction) begin
        system
        generate(OpenElevatorDoor(elidx))
    end
end

function precondition(evt::OpenElevatorDoor, system)
    elevator = system.elevator[evt.elevator_idx]
    return elevator.direction == Stationary && !elevator.doors
end

enable(evt::OpenElevatorDoor, system, when) = (Exponential(1.0), when)

function fire!(evt::OpenElevatorDoor, system, when, rng)
    elevator = system.elevator[evt.elevator_idx]
    elevator.doorsOpen = true
    if elevator.floor ∈ elevator.buttons_pressed
        delete!(elevator.buttons_pressed, elevator.floor)
    end
    # XXX
    system.calls[(elevator.floor, UPORDOWN)] = false
end

end
