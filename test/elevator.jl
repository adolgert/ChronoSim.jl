module ElevatorExample

using ChronoSim
using ChronoSim.ObservedState
import ChronoSim: precondition, enable, fire!
using Distributions
@enum ElevatorDirection Up Down Stationary


@keyedby Person Int64 begin
    location::Int64
    destination::Int64
    waiting::Bool
end

@keyedby Call Tuple{Int64,ElevatorDirection} begin
    requested::Bool
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
    calls::ObservedDict{Tuple{Int64,ElevatorDirection},Call}
    elevator::ObservedVector{Elevator}
    floor_cnt::Int64
end


function ElevatorSystem(person_cnt::Int64, elevator_cnt::Int64, floor_cnt::Int64)
    persons = ObservedVector{Person}(undef, person_cnt)
    for pidx in eachindex(persons)
        persons[pidx] = Person(1, 1, false)
    end
    calls = ObservedDict{Tuple{Int64,ElevatorDirection},Call}()
    for flooridx in 1:floor_cnt
        for direction in [Up, Down]
            calls[(flooridx, direction)] = Call(false)
        end
    end
    elevators = ObservedVector{Elevator}(undef, elevator_cnt)
    for elevidx in eachindex(elevators)
        elevators[elevidx] = Elevator(1, Stationary, false, Set{Int64}())
    end
    ElevatorSystem(person, calls, elevators, floor_cnt)
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
    dests = Set(collect(1:system.floor_cnt))
    delete!(dests, system.person[evt.person].location)
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
    direction = if person.destination > person.location
        Up
    else
        Down
    end
    system.calls[(person.location, direction)].requested = true
end


struct OpenElevatorDoor <: SimEvent
    elevator_idx::Int64
end

@conditionsfor OpenElevatorDoor begin
    @reactto changed(elevator[elidx].floor) begin
        system
        generate(OpenElevatorDoor(elidx))
    end
    @reactto changed(elevator[elidx].buttons_pressed) begin
        system
        generate(OpenElevatorDoor(elidx))
    end
    @reactto changed(calls[callkey].requested) begin
        system
        # Check all elevators when a new call is made
        for elidx in 1:length(system.elevator)
            generate(OpenElevatorDoor(elidx))
        end
    end
end

function precondition(evt::OpenElevatorDoor, system)
    elevator = system.elevator[evt.elevator_idx]
    # Open doors if: doors are closed AND (there's a call we can service OR button pressed for this floor)
    if elevator.doorsOpen
        return false
    end

    # Check if there's a call at this floor in elevator's direction
    call_exists =
        haskey(system.calls, (elevator.floor, elevator.direction)) &&
        system.calls[(elevator.floor, elevator.direction)].requested

    # Check if button pressed for this floor
    button_pressed = elevator.floor ∈ elevator.buttons_pressed

    return call_exists || button_pressed
end

enable(evt::OpenElevatorDoor, system, when) = (Exponential(1.0), when)

function fire!(evt::OpenElevatorDoor, system, when, rng)
    elevator = system.elevator[evt.elevator_idx]
    elevator.doorsOpen = true

    # Remove this floor from buttons pressed
    if elevator.floor ∈ elevator.buttons_pressed
        # Assign a new value so that it registers as changed.
        elevator.buttons_pressed = setdiff(elevator.buttons_pressed, elevator.floor)
    end

    # Remove the active call at this floor in the elevator's direction
    call_key = (elevator.floor, elevator.direction)
    if haskey(system.calls, call_key)
        system.calls[call_key].requested = false
    end
end


# EnterElevator - people board the elevator
struct EnterElevator <: SimEvent
    elevator_idx::Int64
end

@conditionsfor EnterElevator begin
    @reactto changed(elevator[elidx].doorsOpen) begin
        system
        generate(EnterElevator(elidx))
    end
    @reactto changed(person[pidx].waiting) begin
        system
        # Check all elevators when person starts waiting
        for elidx in 1:length(system.elevator)
            generate(EnterElevator(elidx))
        end
    end
end

function precondition(evt::EnterElevator, system)
    elevator = system.elevator[evt.elevator_idx]

    # Doors must be open
    if !elevator.doorsOpen
        return false
    end

    # Check if there are people waiting at this floor who can board
    for pidx in 1:length(system.person)
        person = system.person[pidx]
        if person.location == elevator.floor && person.waiting
            # Person can enter if elevator is going their direction or is stationary
            person_direction = person.destination > person.location ? Up : Down
            if elevator.direction == Stationary || elevator.direction == person_direction
                return true
            end
        end
    end

    return false
end

enable(evt::EnterElevator, system, when) = (Exponential(1.0), when)

function fire!(evt::EnterElevator, system, when, rng)
    elevator = system.elevator[evt.elevator_idx]

    # Find all people who can enter
    for pidx in 1:length(system.person)
        person = system.person[pidx]
        if person.location == elevator.floor && person.waiting
            person_direction = person.destination > person.location ? Up : Down
            if elevator.direction == Stationary || elevator.direction == person_direction
                # Person enters elevator - use negative elevator index to indicate in elevator
                person.location = -evt.elevator_idx
                person.waiting = false

                # Add destination to buttons pressed
                elevator.buttons_pressed = union(elevator.buttons_presed, person.destination)
            end
        end
    end
end


# ExitElevator - people exit the elevator
struct ExitElevator <: SimEvent
    elevator_idx::Int64
end

@conditionsfor ExitElevator begin
    @reactto changed(elevator[elidx].doorsOpen) begin
        system
        generate(ExitElevator(elidx))
    end
    @reactto changed(elevator[elidx].floor) begin
        system
        generate(ExitElevator(elidx))
    end
end

function precondition(evt::ExitElevator, system)
    elevator = system.elevator[evt.elevator_idx]

    # Doors must be open
    if !elevator.doorsOpen
        return false
    end

    # Check if anyone in this elevator wants to exit at this floor
    for pidx in 1:length(system.person)
        person = system.person[pidx]
        if person.location == -evt.elevator_idx && person.destination == elevator.floor
            return true
        end
    end

    return false
end

enable(evt::ExitElevator, system, when) = (Exponential(1.0), when)

function fire!(evt::ExitElevator, system, when, rng)
    elevator = system.elevator[evt.elevator_idx]

    # Exit all people whose destination is this floor
    for pidx in 1:length(system.person)
        person = system.person[pidx]
        if person.location == -evt.elevator_idx && person.destination == elevator.floor
            # Person exits to the floor
            person.location = elevator.floor
            person.waiting = false
        end
    end
end


# CloseElevatorDoors - close doors after boarding/exiting
struct CloseElevatorDoors <: SimEvent
    elevator_idx::Int64
end

@conditionsfor CloseElevatorDoors begin
    @reactto changed(elevator[elidx].doorsOpen) begin
        system
        generate(CloseElevatorDoors(elidx))
    end
    @reactto fired(EnterElevator(elidx)) begin
        system
        generate(CloseElevatorDoors(elidx))
    end
    @reactto fired(ExitElevator(elidx)) begin
        system
        generate(CloseElevatorDoors(elidx))
    end
end

function precondition(evt::CloseElevatorDoors, system)
    elevator = system.elevator[evt.elevator_idx]

    # Doors must be open
    if !elevator.doorsOpen
        return false
    end

    # No one can enter or exit
    # Check no one waiting at this floor can board
    for pidx in 1:length(system.person)
        person = system.person[pidx]
        if person.location == elevator.floor && person.waiting
            person_direction = person.destination > person.location ? Up : Down
            if elevator.direction == Stationary || elevator.direction == person_direction
                return false  # Someone can still board
            end
        end
    end

    # Check no one wants to exit
    for pidx in 1:length(system.person)
        person = system.person[pidx]
        if person.location == -evt.elevator_idx && person.destination == elevator.floor
            return false  # Someone wants to exit
        end
    end

    return true
end

enable(evt::CloseElevatorDoors, system, when) = (Exponential(1.0), when)

function fire!(evt::CloseElevatorDoors, system, when, rng)
    elevator = system.elevator[evt.elevator_idx]
    elevator.doorsOpen = false
end


# MoveElevator - elevator moves between floors
struct MoveElevator <: SimEvent
    elevator_idx::Int64
end

@conditionsfor MoveElevator begin
    @reactto changed(elevator[elidx].doorsOpen) begin
        system
        generate(MoveElevator(elidx))
    end
    @reactto changed(elevator[elidx].direction) begin
        system
        generate(MoveElevator(elidx))
    end
    @reactto changed(elevator[elidx].floor) begin
        system
        generate(MoveElevator(elidx))
    end
end

function precondition(evt::MoveElevator, system)
    elevator = system.elevator[evt.elevator_idx]

    # Doors must be closed
    if elevator.doorsOpen
        return false
    end

    # Must have a direction
    if elevator.direction == Stationary
        return false
    end

    # Check if next floor is valid
    next_floor = elevator.direction == Up ? elevator.floor + 1 : elevator.floor - 1
    if next_floor < 1 || next_floor > system.floor_cnt
        return false
    end

    return true
end

enable(evt::MoveElevator, system, when) = (Exponential(1.0), when)

function fire!(evt::MoveElevator, system, when, rng)
    elevator = system.elevator[evt.elevator_idx]
    # Move one floor in current direction
    if elevator.direction == Up
        elevator.floor += 1
    else
        elevator.floor -= 1
    end
end


# StopElevator - elevator becomes stationary
struct StopElevator <: SimEvent
    elevator_idx::Int64
end

@conditionsfor StopElevator begin
    @reactto changed(elevator[elidx].floor) begin
        system
        generate(StopElevator(elidx))
    end
    @reactto changed(elevator[elidx].buttons_pressed) begin
        system
        generate(StopElevator(elidx))
    end
    @reactto changed(calls[callkey].requested) begin
        system
        for elidx in 1:length(system.elevator)
            generate(StopElevator(elidx))
        end
    end
end

function precondition(evt::StopElevator, system)
    elevator = system.elevator[evt.elevator_idx]

    # Must be moving
    if elevator.direction == Stationary
        return false
    end

    # Must have doors closed
    if elevator.doorsOpen
        return false
    end

    # Stop if: no more buttons pressed AND no calls in current direction
    if !isempty(elevator.buttons_pressed)
        return false
    end

    # Check for calls in current direction
    for floor in 1:system.floor_cnt
        call_key = (floor, elevator.direction)
        if haskey(system.calls, call_key) && system.calls[call_key].requested
            # Check if elevator can reach this call
            if (elevator.direction == Up && floor >= elevator.floor) ||
                (elevator.direction == Down && floor <= elevator.floor)
                return false  # Still have calls to service
            end
        end
    end

    return true
end

enable(evt::StopElevator, system, when) = (Exponential(1.0), when)

function fire!(evt::StopElevator, system, when, rng)
    elevator = system.elevator[evt.elevator_idx]
    elevator.direction = Stationary
end


# DispatchElevator - assign elevator to service a call
struct DispatchElevator <: SimEvent
    floor::Int64
    direction::ElevatorDirection
end

@conditionsfor DispatchElevator begin
    @reactto changed(calls[callkey].requested) begin
        system
        floor, direction = callkey
        generate(DispatchElevator(floor, direction))
    end
    @reactto changed(elevator[elidx].direction) begin
        system
        # Check all calls when elevator becomes available
        for (call_key, call) in system.calls
            if call.requested
                floor, direction = call_key
                generate(DispatchElevator(floor, direction))
            end
        end
    end
end

function precondition(evt::DispatchElevator, system)
    # Call must exist and be active
    call_key = (evt.floor, evt.direction)
    if !haskey(system.calls, call_key) || !system.calls[call_key].requested
        return false
    end

    # At least one elevator must be available to service
    for elidx in 1:length(system.elevator)
        elevator = system.elevator[elidx]
        if elevator.direction == Stationary
            return true  # Idle elevator available
        end
    end

    return false
end

enable(evt::DispatchElevator, system, when) = (Exponential(1.0), when)

function fire!(evt::DispatchElevator, system, when, rng)
    # Find closest idle elevator
    best_elevator = 0
    best_distance = typemax(Int64)

    for elidx in 1:length(system.elevator)
        elevator = system.elevator[elidx]
        if elevator.direction == Stationary
            distance = abs(elevator.floor - evt.floor)
            if distance < best_distance
                best_distance = distance
                best_elevator = elidx
            end
        end
    end

    if best_elevator > 0
        elevator = system.elevator[best_elevator]
        # Set direction toward the call
        if evt.floor > elevator.floor
            elevator.direction = Up
        elseif evt.floor < elevator.floor
            elevator.direction = Down
        else
            # Already at floor, set to call's direction
            elevator.direction = evt.direction
        end
    end
end

function init_physical(physical, rng)
    for pidx in eachindex(persons)
        persons[pidx] = Person(rand(rng, 1:floor_cnt), rand(rng, 1:floor_cnt), false)
    end
end


struct TrajectoryEntry
    event::Tuple
    when::Float64
end

struct TrajectorySave
    trajectory::Vector{TrajectoryEntry}
    TrajectorySave() = new(Vector{TrajectoryEntry}())
end

function observe(te::TrajectoryEntry, physical, when, event, changed_places)
    @debug "Firing $event at $when"
    push!(te.trajectory, TrajectoryEntry(clock_key(event), when))
end


function run_elevator()
    rng = Xoshiro(93472934)
    person_cnt = 10
    elevator_cnt = 3
    floor_cnt = 10
    minutes = 120.0
    Sampler = CombinedNextReaction{ClockKey,Float64}
    physical = ElevatorSystem(person_cnt, elevator_cnt, floor_cnt)
    included_transitions = [
        PickNewDestination,
        CallElevator,
        OpenElevatorDoor,
        EnterElevator,
        ExitElevator,
        CloseElevatorDoors,
        MoveElevator,
        StopElevator,
        DispatchElevator,
    ]
    @assert length(included_transitions) == 9
    sim = SimulationFSM(physical, Sampler(), included_transitions, rng)
    initializer = function (init_physical)
        initialize!(init_physical, sim.rng)
    end
    # Stop-condition is called after the next event is chosen but before the
    # next event is fired. This way you can stop at an end time between events.
    stop_condition = function (physical, step_idx, event, when)
        return when > minutes
    end
    ChronoSim.run(sim, initializer, stop_condition)
end

run_elevator()
# include("elevatortla.jl")

end
