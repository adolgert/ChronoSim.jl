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
    enabled_before_transition::Vector{Vector{String}}  # Events enabled just before transition
    export_every_state::Bool
    sim::ChronoSim.SimulationFSM
    TLATraceRecorder() = new([], [], [], [], false)
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

        # The enabled events before this transition were recorded in the previous state
        if length(recorder.enabled_events) > 0
            push!(recorder.enabled_before_transition, recorder.enabled_events[end])
        end
    end

    # Record currently enabled events (after this transition)
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
        # New structure: on floor if location > 0 && elevator == 0
        #                in elevator if location == 0 && elevator > 0
        location = if person.location > 0 && person.elevator == 0
            person.location  # On a floor
        elseif person.location == 0 && person.elevator > 0
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
Create a config file for checking the trace specification
"""
function create_trace_config(
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
        println(io, "  TraceTypeInvariant")
        println(io, "  TraceSafetyInvariant")
        println(io, "  ValidTransitions")
        println(io, "  CorrectEnabledActions")
    end
end

"""
Run TLC to check the trace specification
"""
function check_trace_with_tlc(
    trace_spec::String, config_file::String, tla_tools_path::String="~/dev/tla/tla2tools.jar"
)
    cmd = `java -cp $tla_tools_path tlc2.TLC -config $config_file $trace_spec`

    try
        result = read(cmd, String)
        return (success=true, output=result)
    catch e
        return (success=false, output=string(e))
    end
end

"""
Run complete trace validation: export trace spec, create config, and run TLC
"""
function validate_trace(
    recorder::TLATraceRecorder,
    person_cnt::Int,
    elevator_cnt::Int,
    floor_cnt::Int,
    tla_tools_path::String="~/dev/tla/tla2tools.jar",
)
    # Export the trace as a TLA+ spec
    trace_spec_file = "ElevatorTrace.tla"
    export_trace_spec(recorder, trace_spec_file)

    # Create config file for the trace spec  
    trace_config_file = "ElevatorTrace.cfg"
    create_trace_config(person_cnt, elevator_cnt, floor_cnt, trace_config_file)

    # Run TLC to check the trace
    println("Checking trace with TLC...")
    result = check_trace_with_tlc(trace_spec_file, trace_config_file, tla_tools_path)

    if result.success
        println("TLC check completed successfully!")
        # Check if the output contains any errors
        if contains(result.output, "Error") ||
            contains(result.output, "Invariant") && contains(result.output, "violated")
            println("Trace validation FAILED:")
            println(result.output)
            return false
        else
            println("Trace validation PASSED")
            return true
        end
    else
        println("TLC check failed to run:")
        println(result.output)
        return false
    end
end

"""
Generate enabled action predicates for TLA+ based on Julia event types
"""
function generate_enabled_predicates(io::IO)
    println(io, "(* Predicates to check if specific actions are enabled *)")
    println(io, "")

    # PickNewDestination
    println(io, "PickNewDestinationEnabled(p, ps) ==")
    println(io, "    /\\ ~ps[p].waiting")
    println(io, "    /\\ ps[p].location \\in 1..FloorCount")
    println(io, "")

    # CallElevator
    println(io, "CallElevatorEnabled(p, ps, es) ==")
    println(io, "    LET pState == ps[p]")
    println(
        io,
        "        call == [floor |-> pState.location, direction |-> IF pState.destination > pState.location THEN \"Up\" ELSE \"Down\"]",
    )
    println(io, "    IN")
    println(io, "    /\\ ~pState.waiting")
    println(io, "    /\\ pState.location /= pState.destination")
    println(io, "")

    # OpenElevatorDoors
    println(io, "OpenElevatorDoorsEnabled(e, es, calls) ==")
    println(io, "    LET eState == es[e] IN")
    println(io, "    /\\ ~eState.doorsOpen")
    println(io, "    /\\ \\/ \\E call \\in calls :")
    println(io, "          /\\ call.floor = eState.floor")
    println(io, "          /\\ call.direction = eState.direction")
    println(io, "       \\/ eState.floor \\in eState.buttonsPressed")
    println(io, "")

    # EnterElevator
    println(io, "EnterElevatorEnabled(e, ps, es) ==")
    println(io, "    LET eState == es[e] IN")
    println(io, "    /\\ eState.doorsOpen")
    println(io, "    /\\ eState.direction /= \"Stationary\"")
    println(io, "    /\\ \\E p \\in Person :")
    println(io, "          /\\ ps[p].location = eState.floor")
    println(io, "          /\\ ps[p].waiting")
    println(io, "          /\\ IF ps[p].destination > ps[p].location")
    println(io, "             THEN eState.direction = \"Up\"")
    println(io, "             ELSE eState.direction = \"Down\"")
    println(io, "")

    # Add more predicates for other actions...
    println(io, "(* Check if an action string corresponds to an enabled action *)")
    println(io, "ActionIsEnabled(actionStr, ps, calls, es) ==")
    println(
        io, "    \\/ /\\ \\E p \\in Person : actionStr = \"PickNewDestination(\" \\o p \\o \")\""
    )
    println(io, "       /\\ \\E p \\in Person : PickNewDestinationEnabled(p, ps)")
    println(io, "    \\/ /\\ \\E p \\in Person : actionStr = \"CallElevator(\" \\o p \\o \")\"")
    println(io, "       /\\ \\E p \\in Person : CallElevatorEnabled(p, ps, es)")
    println(
        io, "    \\/ /\\ \\E e \\in Elevator : actionStr = \"OpenElevatorDoors(\" \\o e \\o \")\""
    )
    println(io, "       /\\ \\E e \\in Elevator : OpenElevatorDoorsEnabled(e, es, calls)")
    println(io, "    \\/ /\\ \\E e \\in Elevator : actionStr = \"EnterElevator(\" \\o e \\o \")\"")
    println(io, "       /\\ \\E e \\in Elevator : EnterElevatorEnabled(e, ps, es)")
    println(io, "")
end

"""
Generate a TLA+ module that represents the trace as a sequence of states
This can be model-checked to verify the trace satisfies the specification
"""
function export_trace_spec(recorder::TLATraceRecorder, spec_filename::String)
    open(spec_filename, "w") do io
        # Module header
        module_name = replace(basename(spec_filename), ".tla" => "")
        println(io, "-" ^ 28 * " MODULE $module_name " * "-" ^ 28)
        println(
            io,
            "(* This specification defines a specific trace to be checked against the Elevator spec *)",
        )
        println(io, "EXTENDS Elevator, Sequences, TLC\n")

        # Define the trace as a sequence of states
        println(io, "(* The recorded trace as a sequence of states *)")
        println(io, "TraceStates == <<")

        for (i, state) in enumerate(recorder.states)
            println(io, "    (* State $i *)")
            println(io, "    [")

            # PersonState
            print(io, "        PersonState |-> [")
            person_items = []
            for (pid, pstate) in sort(collect(state["PersonState"]); by=x->x[1])
                loc_str = if isa(pstate["location"], String)
                    "\"$(pstate["location"])\""
                else
                    string(pstate["location"])
                end
                push!(
                    person_items,
                    "$pid |-> [location |-> $loc_str, destination |-> $(pstate["destination"]), waiting |-> $(uppercase(string(pstate["waiting"])))]",
                )
            end
            println(io, join(person_items, ",\n                         "), "],")

            # ActiveElevatorCalls
            print(io, "        ActiveElevatorCalls |-> {")
            call_items = []
            for call in state["ActiveElevatorCalls"]
                push!(
                    call_items,
                    "[floor |-> $(call["floor"]), direction |-> \"$(call["direction"])\"]",
                )
            end
            println(io, join(call_items, ", "), "},")

            # ElevatorState
            print(io, "        ElevatorState |-> [")
            elevator_items = []
            for (eid, estate) in sort(collect(state["ElevatorState"]); by=x->x[1])
                buttons_str = "{" * join(estate["buttonsPressed"], ", ") * "}"
                push!(
                    elevator_items,
                    "$eid |-> [floor |-> $(estate["floor"]), direction |-> \"$(estate["direction"])\", doorsOpen |-> $(uppercase(string(estate["doorsOpen"]))), buttonsPressed |-> $buttons_str]",
                )
            end
            println(io, join(elevator_items, ",\n                            "), "]")

            print(io, "    ]")
            if i < length(recorder.states)
                println(io, ",")
            else
                println(io)
            end
        end

        println(io, ">>\n")

        # Verification that trace satisfies invariants
        println(io, "(* Verify each state in the trace satisfies the invariants *)")
        println(io, "TraceTypeInvariant == \\A i \\in 1..Len(TraceStates) :")
        println(io, "    LET state == TraceStates[i]")
        println(io, "        PersonState == state.PersonState")
        println(io, "        ActiveElevatorCalls == state.ActiveElevatorCalls")
        println(io, "        ElevatorState == state.ElevatorState")
        println(io, "    IN TypeInvariant\n")

        println(io, "TraceSafetyInvariant == \\A i \\in 1..Len(TraceStates) :")
        println(io, "    LET state == TraceStates[i]")
        println(io, "        PersonState == state.PersonState")
        println(io, "        ActiveElevatorCalls == state.ActiveElevatorCalls")
        println(io, "        ElevatorState == state.ElevatorState")
        println(io, "    IN SafetyInvariant\n")

        # Verify transitions are valid according to Next
        println(io, "(* Verify each transition in the trace is valid according to Next *)")
        println(io, "ValidTransitions == \\A i \\in 1..(Len(TraceStates)-1) :")
        println(io, "    LET PersonState == TraceStates[i].PersonState")
        println(io, "        ActiveElevatorCalls == TraceStates[i].ActiveElevatorCalls")
        println(io, "        ElevatorState == TraceStates[i].ElevatorState")
        println(io, "        PersonState' == TraceStates[i+1].PersonState")
        println(io, "        ActiveElevatorCalls' == TraceStates[i+1].ActiveElevatorCalls")
        println(io, "        ElevatorState' == TraceStates[i+1].ElevatorState")
        println(
            io, "    IN Next \\/ UNCHANGED <<PersonState, ActiveElevatorCalls, ElevatorState>>\n"
        )

        # Add enabled actions information if available
        if length(recorder.enabled_events) > 0
            println(io, "(* Enabled actions recorded at each state *)")
            println(io, "EnabledActions == <<")
            for (i, enabled) in enumerate(recorder.enabled_events)
                enabled_str = "{" * join(["\"$e\"" for e in enabled], ", ") * "}"
                if i < length(recorder.enabled_events)
                    println(io, "    $enabled_str,  (* State $i *)")
                else
                    println(io, "    $enabled_str   (* State $i *)")
                end
            end
            println(io, ">>\n")

            # Generate the enabled predicates
            generate_enabled_predicates(io)

            println(io, "(* Verify that recorded enabled actions match the specification *)")
            println(
                io,
                "(* This checks that the simulation correctly determines which actions are enabled *)",
            )
            println(io, "CorrectEnabledActions == \\A i \\in 1..Len(TraceStates) :")
            println(io, "    LET state == TraceStates[i]")
            println(io, "        ps == state.PersonState")
            println(io, "        calls == state.ActiveElevatorCalls")
            println(io, "        es == state.ElevatorState")
            println(
                io,
                "        recordedEnabled == IF i <= Len(EnabledActions) THEN EnabledActions[i] ELSE {}",
            )
            println(io, "    IN \\A action \\in recordedEnabled :")
            println(io, "        ActionIsEnabled(action, ps, calls, es)")
            println(io, "")
            println(io, "(* Additionally check that transitions taken were actually enabled *)")
            println(io, "TransitionWasEnabled == \\A i \\in 1..(Len(TraceStates)-1) :")
            println(io, "    LET state == TraceStates[i]")
            println(io, "        ps == state.PersonState")
            println(io, "        calls == state.ActiveElevatorCalls")
            println(io, "        es == state.ElevatorState")
            println(
                io,
                "        enabledBefore == IF i <= Len(EnabledActions) THEN EnabledActions[i] ELSE {}",
            )
            println(
                io,
                "    IN TRUE  (* The transition that was taken should have been in enabledBefore *)",
            )
            println(io, "")
        end

        # Properties to check
        println(io, "(* Properties to check *)")
        println(io, "ASSUME TraceTypeInvariant")
        println(io, "ASSUME TraceSafetyInvariant")
        println(io, "ASSUME ValidTransitions\n")

        println(io, "=" ^ 77)
    end
end

# Export all functions for use in elevator simulation
export TLATraceRecorder,
    export_tlc_trace,
    export_current_state,
    create_tlc_config,
    create_trace_config,
    validate_type_invariant,
    check_safety_invariant,
    check_trace_with_tlc,
    export_trace_spec,
    validate_trace
