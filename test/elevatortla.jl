# TLA+ Integration for Elevator Simulation
# This module provides functions to export simulation trajectories and states
# in a format that can be checked by TLC (TLA+ model checker)
#
# IO/Export functions for TLA+ integration:
#   1. TLATraceRecorder - A mutable struct that records simulation states
#   2. Observer function (lines 18-43) - Records states during simulation
#   3. Conversion functions:
#     - convert_person_state - Converts Julia Person to TLA+ format
#     - convert_active_calls - Converts Julia calls to TLA+ format
#     - convert_elevator_state - Converts Julia elevators to TLA+ format
#   4. Formatting functions:
#     - format_action - Converts SimEvent to TLA+ action names
#     - format_changed_places - Formats changed places for debugging
#     - format_tla_state - Formats complete TLA+ state as string
#   5. Export functions:
#     - export_tlc_trace - Exports recorded trace to TLC format
#     - export_current_state - Exports single state snapshot
#     - create_tlc_config - Creates TLC configuration file
#   6. run_tlc_check - Runs TLC model checker on exported trace

using ChronoSim: get_enabled_events

mutable struct TLATraceRecorder
    states::Vector{Dict{String,Any}}
    transitions::Vector{Dict{String,Any}}
    enabled_events::Vector{Vector{String}}
    export_every_state::Bool
    sim::ChronoSim.SimulationFSM
    TLATraceRecorder() = new([], [], [], false)
end

"""
Observer function that records simulation states for TLA+ validation
"""
function (recorder::TLATraceRecorder)(physical, when, event, changed_places)
    # Convert current state to TLA+ format
    tla_state = Dict(
        "PersonState" => convert_person_state(physical.person),
        "ActiveElevatorCalls" => convert_active_calls(physical.calls),
        "ElevatorState" => convert_elevator_state(physical.elevator),
    )

    # Record the state
    push!(recorder.states, tla_state)

    # Record the transition that led to this state
    if length(recorder.states) > 1
        transition = Dict(
            "action" => format_action(event),
            "time" => when,
            "changed" => format_changed_places(changed_places),
        )
        push!(recorder.transitions, transition)
    end

    # Record currently enabled events
    enabled = get_enabled_events(recorder.sim)
    enabled_names = [format_action(e) for e in enabled]
    push!(recorder.enabled_events, enabled_names)

    if recorder.export_every_state
        export_current_state(recorder.sim, physical, "Elevator_state$(length(recorder.states)).txt")
    end
end

"""
Convert Julia person state to TLA+ format
"""
function convert_person_state(persons::ObservedVector{Person})
    result = Dict{String,Any}()
    for (idx, person) in enumerate(persons)
        # In TLA+, location is either a floor number or elevator identifier
        location = if person.location > 0
            person.location  # On a floor
        elseif person.elevator > 0
            "e$(person.elevator)"  # In elevator
        else
            error(
                "Person $idx has invalid state: location=$(person.location), elevator=$(person.elevator)",
            )
        end

        result["p$idx"] = Dict(
            "location" => location, "destination" => person.destination, "waiting" => person.waiting
        )
    end
    return result
end

"""
Convert Julia calls to TLA+ ActiveElevatorCalls format
"""
function convert_active_calls(calls::ObservedDict{Tuple{Int64,ElevatorDirection},ElevatorCall})
    active_calls = []
    for ((floor, direction), call) in calls
        if call.requested
            push!(
                active_calls, Dict("floor" => floor, "direction" => direction == Up ? "Up" : "Down")
            )
        end
    end
    return active_calls
end

"""
Convert Julia elevator state to TLA+ format
"""
function convert_elevator_state(elevators::ObservedVector{Elevator})
    result = Dict{String,Any}()
    for (idx, elevator) in enumerate(elevators)
        direction_str = if elevator.direction == Up
            "Up"
        elseif elevator.direction == Down
            "Down"
        else
            "Stationary"
        end

        result["e$idx"] = Dict(
            "floor" => elevator.floor,
            "direction" => direction_str,
            "doorsOpen" => elevator.doors_open,
            "buttonsPressed" => collect(elevator.buttons_pressed),
        )
    end
    return result
end

"""
Format a SimEvent into TLA+ action name
"""
function format_action(event::SimEvent)
    if isa(event, PickNewDestination)
        return "PickNewDestination(p$(event.person))"
    elseif isa(event, CallElevator)
        return "CallElevator(p$(event.person))"
    elseif isa(event, OpenElevatorDoors)
        return "OpenElevatorDoors(e$(event.elevator_idx))"
    elseif isa(event, EnterElevator)
        return "EnterElevator(e$(event.elevator_idx))"
    elseif isa(event, ExitElevator)
        return "ExitElevator(e$(event.elevator_idx))"
    elseif isa(event, CloseElevatorDoors)
        return "CloseElevatorDoors(e$(event.elevator_idx))"
    elseif isa(event, MoveElevator)
        return "MoveElevator(e$(event.elevator_idx))"
    elseif isa(event, StopElevator)
        return "StopElevator(e$(event.elevator_idx))"
    elseif isa(event, DispatchElevator)
        dir_str = event.direction == Up ? "Up" : "Down"
        return "DispatchElevator([floor |-> $(event.floor), direction |-> \"$dir_str\"])"
    else
        return "Unknown($(typeof(event)))"
    end
end

"""
Format changed places for debugging
"""
format_changed_places(changed_places) = [string(cp) for cp in changed_places]

"""
Export recorded trace to TLC trace format
"""
function export_tlc_trace(recorder::TLATraceRecorder, filename::String)
    open(filename, "w") do io
        for (i, state) in enumerate(recorder.states)
            println(io, "State $i:")

            # Write PersonState
            println(io, "PersonState = [")
            person_items = []
            for (pid, pstate) in state["PersonState"]
                loc_str = if isa(pstate["location"], String)
                    pstate["location"]
                else
                    string(pstate["location"])
                end
                push!(
                    person_items,
                    "  $pid |-> [location |-> $loc_str, destination |-> $(pstate["destination"]), waiting |-> $(uppercase(string(pstate["waiting"])))]",
                )
            end
            println(io, join(person_items, ",\n"))
            println(io, "]")

            # Write ActiveElevatorCalls
            print(io, "ActiveElevatorCalls = {")
            call_items = []
            for call in state["ActiveElevatorCalls"]
                push!(
                    call_items,
                    "[floor |-> $(call["floor"]), direction |-> \"$(call["direction"])\"]",
                )
            end
            println(io, join(call_items, ", "), "}")

            # Write ElevatorState
            println(io, "ElevatorState = [")
            elevator_items = []
            for (eid, estate) in state["ElevatorState"]
                buttons_str = "{" * join(estate["buttonsPressed"], ", ") * "}"
                push!(
                    elevator_items,
                    "  $eid |-> [floor |-> $(estate["floor"]), direction |-> \"$(estate["direction"])\", doorsOpen |-> $(uppercase(string(estate["doorsOpen"]))), buttonsPressed |-> $buttons_str]",
                )
            end
            println(io, join(elevator_items, ",\n"))
            println(io, "]")

            # Add transition info if available
            if i > 1 && i-1 <= length(recorder.transitions)
                trans = recorder.transitions[i - 1]
                println(io, "\n-- Transition: $(trans["action"]) at time $(trans["time"])")
            end

            # Add enabled events info
            if i <= length(recorder.enabled_events)
                println(io, "-- Enabled: [" * join(recorder.enabled_events[i], ", ") * "]")
            end

            println(io)  # Empty line between states
        end
    end
end

"""
Export state and enabled events for a specific point in simulation
"""
function export_current_state(sim, physical, filename::String)
    open(filename, "w") do io
        # Current state
        state = Dict(
            "PersonState" => convert_person_state(physical.person),
            "ActiveElevatorCalls" => convert_active_calls(physical.calls),
            "ElevatorState" => convert_elevator_state(physical.elevator),
        )

        # Format and write current state
        println(io, "Current State:")
        println(io, format_tla_state(state))

        # Get and write enabled events
        println(io, "\nEnabled Actions:")
        enabled = get_enabled_events(sim)
        for event in enabled
            println(io, "  - " * format_action(event))
        end
    end
end

"""
Format a complete TLA+ state as a string
"""
function format_tla_state(state::Dict{String,Any})
    lines = String[]

    # PersonState
    push!(lines, "PersonState = [")
    person_items = []
    for (pid, pstate) in state["PersonState"]
        loc_str = isa(pstate["location"], String) ? pstate["location"] : string(pstate["location"])
        push!(
            person_items,
            "  $pid |-> [location |-> $loc_str, destination |-> $(pstate["destination"]), waiting |-> $(uppercase(string(pstate["waiting"])))]",
        )
    end
    push!(lines, join(person_items, ",\n"))
    push!(lines, "]")

    # ActiveElevatorCalls
    push!(lines, "ActiveElevatorCalls = {")
    call_items = []
    for call in state["ActiveElevatorCalls"]
        push!(call_items, "[floor |-> $(call["floor"]), direction |-> \"$(call["direction"])\"]")
    end
    push!(lines, "  " * join(call_items, ", "))
    push!(lines, "}")

    # ElevatorState
    push!(lines, "ElevatorState = [")
    elevator_items = []
    for (eid, estate) in state["ElevatorState"]
        buttons_str = "{" * join(estate["buttonsPressed"], ", ") * "}"
        push!(
            elevator_items,
            "  $eid |-> [floor |-> $(estate["floor"]), direction |-> \"$(estate["direction"])\", doorsOpen |-> $(uppercase(string(estate["doorsOpen"]))), buttonsPressed |-> $buttons_str]",
        )
    end
    push!(lines, join(elevator_items, ",\n"))
    push!(lines, "]")

    return join(lines, "\n")
end

"""
Create a TLC configuration file for the elevator spec
"""
function create_tlc_config(
    people_count::Int, elevator_count::Int, floor_count::Int, filename::String
)
    open(filename, "w") do io
        println(io, "CONSTANTS")

        # Person set
        person_set = join(["p$i" for i in 1:people_count], ", ")
        println(io, "  Person = {$person_set}")

        # Elevator set
        elevator_set = join(["e$i" for i in 1:elevator_count], ", ")
        println(io, "  Elevator = {$elevator_set}")

        # Floor count
        println(io, "  FloorCount = $floor_count")

        println(io, "\nINVARIANTS")
        println(io, "  TypeInvariant")
        println(io, "  SafetyInvariant")

        println(io, "\nPROPERTIES")
        println(io, "  TemporalInvariant")
    end
end


"""
Run TLC on exported trace (requires TLA+ tools installed)
"""
function run_tlc_check(tla_file::String, trace_file::String, config_file::String)
    # This assumes tla2tools.jar is in the PATH or current directory
    cmd = `java -cp tla2tools.jar tlc2.TLC -trace $trace_file -config $config_file $tla_file`

    try
        result = read(cmd, String)
        return (success=true, output=result)
    catch e
        return (success=false, output=string(e))
    end
end

# Export all functions for use in elevator simulation
export TLATraceRecorder,
    export_tlc_trace,
    export_current_state,
    create_tlc_config,
    validate_type_invariant,
    check_safety_invariant,
    run_tlc_check
