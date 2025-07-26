module ElevatorExample
using CompetingClocks
using Distributions
using Logging
using Random
using ChronoSim
using ChronoSim.ObservedState
import ChronoSim: precondition, enable, fire!

# DirectionState
@enum ElevatorDirection Up Down Stationary

@keyedby Person Int64 begin
    location::Int64  # a floor, 0 if on elevator.
    destination::Int64  # a floor
    elevator::Int64 # 0 if not on an elevator.
    waiting::Bool
end

@keyedby ElevatorCall Tuple{Int64,ElevatorDirection} begin
    requested::Bool
end

@keyedby Elevator Int64 begin
    floor::Int64
    direction::ElevatorDirection
    doors_open::Bool
    buttons_pressed::Set{Int64}
end


@observedphysical ElevatorSystem begin
    person::ObservedVector{Person}
    # Floor and direction, true is up, false is down.
    calls::ObservedDict{Tuple{Int64,ElevatorDirection},ElevatorCall}
    elevator::ObservedVector{Elevator}
    floor_cnt::Int64
end


function ElevatorSystem(person_cnt::Int64, elevator_cnt::Int64, floor_cnt::Int64)
    persons = ObservedArray{Person}(undef, person_cnt)
    for pidx in eachindex(persons)
        persons[pidx] = Person(1, 1, 0, false)
    end
    calls = ObservedDict{Tuple{Int64,ElevatorDirection},ElevatorCall}()
    for flooridx in 1:floor_cnt
        for direction in [Up, Down]
            calls[(flooridx, direction)] = ElevatorCall(false)
        end
    end
    elevators = ObservedArray{Elevator}(undef, elevator_cnt)
    for elevidx in eachindex(elevators)
        elevators[elevidx] = Elevator(1, Stationary, false, Set{Int64}())
    end
    ElevatorSystem(persons, calls, elevators, floor_cnt)
end


get_distance(floor1, floor2) = abs(floor1 - floor2)
get_direction(current, destination) = destination > current ? Up : Down
function can_service_call(elevator, call_floor, call_dirn)
    elevator.floor == call_floor && elevator.direction == call_dirn
end


function people_waiting(people, floor, dirn)
    waiters = Int[]
    for pidx in eachindex(people)
        p = people[pidx]
        if p.location == floor && p.waiting && get_direction(p.location, p.destination) == dirn
            push!(waiters, pidx)
        end
    end
    return waiters
end


struct PickNewDestination <: SimEvent
    person::Int64
end

@conditionsfor PickNewDestination begin
    @reactto changed(person[who].location) do system
        @debug "picking new destination for $who"
        println("PICKING DESTINATION")
        generate(PickNewDestination(who))
    end
end

function precondition(evt::PickNewDestination, system)
    person = system.person[evt.person]
    @debug "PickNewDestination $(person.waiting) $(person.location)"
    return !person.waiting && person.location != 0
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
    @reactto changed(person[who].destination) do system
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
    direction = get_direction(person.location, person.destination)
    # Don't create a call if there is already an elevator with doors open.
    any_open = any(
        can_service_call(system.elevator[elidx], person.location, direction) &&
        system.elevator[elidx].doors_open for elidx in eachindex(system.elevator)
    )
    if !any_open
        system.calls[(person.location, direction)].requested = true
    end
end


struct OpenElevatorDoor <: SimEvent
    elevator_idx::Int64
end

@conditionsfor OpenElevatorDoor begin
    @reactto changed(elevator[elidx].floor) do system
        generate(OpenElevatorDoor(elidx))
    end
    @reactto changed(elevator[elidx].buttons_pressed) do system
        generate(OpenElevatorDoor(elidx))
    end
    @reactto changed(calls[callkey].requested) do system
        # Check all elevators when a new call is made
        for elidx in 1:length(system.elevator)
            generate(OpenElevatorDoor(elidx))
        end
    end
end

function precondition(evt::OpenElevatorDoor, system)
    elevator = system.elevator[evt.elevator_idx]
    elevator.doors_open && return false

    call_exists = system.calls[(elevator.floor, elevator.direction)].requested
    button_pressed = elevator.floor ∈ elevator.buttons_pressed

    return call_exists || button_pressed
end

enable(evt::OpenElevatorDoor, system, when) = (Exponential(1.0), when)

function fire!(evt::OpenElevatorDoor, system, when, rng)
    elevator = system.elevator[evt.elevator_idx]
    elevator.doors_open = true

    if elevator.floor ∈ elevator.buttons_pressed
        # Assign a new value so that it registers as changed.
        elevator.buttons_pressed = setdiff(elevator.buttons_pressed, elevator.floor)
    end
    system.calls[(elevator.floor, elevator.direction)].requested = false
end


# EnterElevator - people board the elevator
struct EnterElevator <: SimEvent
    elevator_idx::Int64
end

@conditionsfor EnterElevator begin
    @reactto changed(elevator[elidx].doors_open) do system
        generate(EnterElevator(elidx))
    end
    @reactto changed(person[pidx].waiting) do system
        # Check all elevators when person starts waiting
        for elidx in 1:length(system.elevator)
            generate(EnterElevator(elidx))
        end
    end
end

function precondition(evt::EnterElevator, system)
    elevator = system.elevator[evt.elevator_idx]
    elevator_ready = (elevator.doors_open && elevator.direction != Stationary)
    people_ready = !empty(people_waiting(system.person, elevator.floor, elevator.direction))
    return elevator_ready && people_ready
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
                person.location = 0
                person.elevator = evt.elevator_idx
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
    @reactto changed(elevator[elidx].doors_open) do system
        generate(ExitElevator(elidx))
    end
    @reactto changed(elevator[elidx].floor) do system
        generate(ExitElevator(elidx))
    end
end

function precondition(evt::ExitElevator, system)
    elevator = system.elevator[evt.elevator_idx]

    # Check if anyone in this elevator wants to exit at this floor
    anyone_exit_here = false
    for pidx in 1:length(system.person)
        person = system.person[pidx]
        if person.elevator == evt.elevator_idx && person.destination == elevator.floor
            anyone_exit_here = true
        end
    end

    return anyone_exit_here && elevator.doors_open
end

enable(evt::ExitElevator, system, when) = (Exponential(1.0), when)

function fire!(evt::ExitElevator, system, when, rng)
    elevator = system.elevator[evt.elevator_idx]

    for pidx in 1:length(system.person)
        person = system.person[pidx]
        if person.elevator == evt.elevator_idx && person.destination == elevator.floor
            person.location = elevator.floor
            person.elevator = 0
            person.waiting = false
        end
    end
end


# CloseElevatorDoors - close doors after boarding/exiting
struct CloseElevatorDoors <: SimEvent
    elevator_idx::Int64
end

@conditionsfor CloseElevatorDoors begin
    @reactto changed(elevator[elidx].doors_open) do system
        generate(CloseElevatorDoors(elidx))
    end
    @reactto fired(EnterElevator(elidx)) do system
        generate(CloseElevatorDoors(elidx))
    end
    @reactto fired(ExitElevator(elidx)) do system
        generate(CloseElevatorDoors(elidx))
    end
end

function precondition(evt::CloseElevatorDoors, system)
    elevator = system.elevator[evt.elevator_idx]

    # Doors must be open
    if !elevator.doors_open
        return false
    end

    # No one can enter or exit
    # Check no one waiting at this floor can board
    person_needs_to_board = false
    for pidx in 1:length(system.person)
        person = system.person[pidx]
        if person.location == elevator.floor && person.waiting
            person_direction = person.destination > person.location ? Up : Down
            if elevator.direction == Stationary || elevator.direction == person_direction
                person_needs_to_board = true
            end
        end
    end

    person_needs_to_exit = false
    for pidx in 1:length(system.person)
        person = system.person[pidx]
        if person.elevator == evt.elevator_idx && person.destination == elevator.floor
            person_needs_to_exit = true
        end
    end

    enabled_enter = !precondition(EnterElevator(evt.elevator_idx), system)
    enabled_exit = !precondition(ExitElevator(evt.elevator_idx), system)

    return elevator.doors_open &&
           !(person_needs_to_board || person_needs_to_exit) &&
           !enabled_enter &&
           !enabled_exit
end

enable(evt::CloseElevatorDoors, system, when) = (Exponential(1.0), when)

function fire!(evt::CloseElevatorDoors, system, when, rng)
    elevator = system.elevator[evt.elevator_idx]
    elevator.doors_open = false
end


# MoveElevator - elevator moves between floors
struct MoveElevator <: SimEvent
    elevator_idx::Int64
end

@conditionsfor MoveElevator begin
    @reactto changed(elevator[elidx].doors_open) do system
        generate(MoveElevator(elidx))
    end
    @reactto changed(elevator[elidx].direction) do system
        generate(MoveElevator(elidx))
    end
    @reactto changed(elevator[elidx].floor) do system
        generate(MoveElevator(elidx))
    end
end

function precondition(evt::MoveElevator, system)
    elevator = system.elevator[evt.elevator_idx]
    next_floor = elevator.direction == Up ? elevator.floor + 1 : elevator.floor - 1
    next_floor_valid = next_floor >= 1 && next_floor <= system.floor_cnt
    stop_here = elevator.floor ∈ elevator.buttons_pressed
    # /\ \A call \in ActiveElevatorCalls : \* Can move only if other elevator servicing call
    #     /\ CanServiceCall[e, call] =>
    #         /\ \E e2 \in Elevator :
    #             /\ e /= e2
    #             /\ CanServiceCall[e2, call]
    for (floor, direction) in keys(system.calls)
        other_calls_serviced = true
        if can_service_call(elevator, floor, direction)
            another_can_service = false
            for other_elev in eachindex(system.elevator)
                other_elev == evt.elevator_idx && continue
                other_elevator = system.elevator[other_elev]
                another_can_service |= can_service_call(other_elevator, floor, direction)
            end
            other_calls_serviced &= another_can_service
        end
    end
    return !elevator.doors_open &&
           elevator.direction != Stationary &&
           next_floor_valid &&
           !stop_here &&
           other_calls_serviced
end

enable(evt::MoveElevator, system, when) = (Exponential(1.0), when)

function fire!(evt::MoveElevator, system, when, rng)
    elevator = system.elevator[evt.elevator_idx]
    elevator.floor += elevator.direction == Up ? 1 : -1
end

# This is about stopping when the elevator is at the top or bottom floor.
struct StopElevator <: SimEvent
    elevator_idx::Int64
end

@conditionsfor StopElevator begin
    @reactto changed(elevator[elidx].floor) do system
        generate(StopElevator(elidx))
    end
end

function precondition(evt::StopElevator, system)
    elevator = system.elevator[evt.elevator_idx]
    next_floor = elevator.direction == Up ? elevator.floor + 1 : elevator.floor - 1
    next_floor_valid = 1 <= next_floor <= system.floor_cnt
    return !elevator.doors_open &&
           !next_floor_valid &&
           !precondition(OpenElevatorDoor(evt.elevator_idx), system)
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
    @reactto changed(calls[callkey].requested) do system
        floor, direction = callkey
        generate(DispatchElevator(floor, direction))
    end
    @reactto changed(elevator[elidx].direction) do system
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
    call_active = system.calls[(evt.floor, evt.direction)]
    any_stationary = any(elevator.direction == Stationary for elevator in system.elevator)
    any_approaching = any(
        elevator.direction == evt.direction &&
        (elevator.floor == evt.floor || get_direction(elevator.floor, evt.floor) == evt.direction)
        for elevator in system.elevator
    )
    return call_active && (any_stationary || any_approaching)
end

enable(evt::DispatchElevator, system, when) = (Exponential(1.0), when)

function fire!(evt::DispatchElevator, system, when, rng)
    close_elev = 0
    close_dist = system.floor_cnt + 1
    for elev_idx in eachindex(system.elevator)
        elevator = system.elevator[elev_idx]
        approaching =
            elevator.direction == evt.direction && (
                elevator.floor == evt.floor ||
                get_direction(elevator.floor, evt.floor) == evt.direction
            )
        if elevator.direction == Stationary || approaching
            dist = get_distance(elevator.floor, evt.floor)
            if dist < close_dist
                close_elev = elev_idx
                close_dist = dist
            end
        end
    end
    @assert close_elev > 0
    if system.elevator[close_elev].direction == Stationary
        system.elevator[close_elev].direction = get_direction(elevator.floor, evt.floor)
    end
end

function init_physical(physical, when, rng)
    for pidx in eachindex(physical.person)
        physical.person[pidx].location = rand(rng, 1:physical.floor_cnt)
        physical.person[pidx].destination = physical.person[pidx].location
        physical.person[pidx].elevator = 0
        physical.person[pidx].waiting = false
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
    person_cnt = 10
    elevator_cnt = 3
    floor_cnt = 10
    minutes = 120.0
    ClockKey=Tuple
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
    sim = SimulationFSM(physical, Sampler(), included_transitions; rng=Xoshiro(93472934))
    # Stop-condition is called after the next event is chosen but before the
    # next event is fired. This way you can stop at an end time between events.
    stop_condition = function (physical, step_idx, event, when)
        return when > minutes
    end
    ChronoSim.run(sim, init_physical, stop_condition)
end

# include("elevatortla.jl")

end
