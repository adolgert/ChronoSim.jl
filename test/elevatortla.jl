# TLA+ Integration for Elevator Simulation (Refactored)
using ChronoSim: get_enabled_events

mutable struct TLATraceRecorder
    states::Vector{Dict{String,Any}}
    transitions::Vector{Dict{String,Any}}  # Keep for action comments only
    sim::ChronoSim.SimulationFSM
    TLATraceRecorder() = new([], [])
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

    push!(recorder.states, tla_state)

    # Record the transition for comments only (not for validation)
    if length(recorder.states) > 1
        transition = Dict("action" => format_action(event), "time" => when)
        push!(recorder.transitions, transition)
    end
end

"""
Convert Julia person state to TLA+ format
"""
function convert_person_state(persons::ObservedVector{Person})
    result = Dict{String,Any}()
    for (idx, person) in enumerate(persons)
        # Determine location based on new structure
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
    [
        Dict("floor" => floor, "direction" => string(direction)) for
        ((floor, direction), call) in calls if call.requested
    ]
end

"""
Convert Julia elevator state to TLA+ format
"""
function convert_elevator_state(elevators::ObservedVector{Elevator})
    Dict(
        "e$idx" => Dict(
            "floor" => elevator.floor,
            "direction" => string(elevator.direction),
            "doorsOpen" => elevator.doors_open,
            "buttonsPressed" => collect(elevator.buttons_pressed),
        ) for (idx, elevator) in enumerate(elevators)
    )
end

"""
Format a SimEvent into TLA+ action name
"""
function format_action(event::SimEvent)
    # Use type dispatch pattern
    format_action_impl(event)
end

# Individual implementations for each event type
format_action_impl(e::PickNewDestination) = "PickNewDestination(p$(e.person))"
format_action_impl(e::CallElevator) = "CallElevator(p$(e.person))"
format_action_impl(e::OpenElevatorDoors) = "OpenElevatorDoors(e$(e.elevator_idx))"
format_action_impl(e::EnterElevator) = "EnterElevator(e$(e.elevator_idx))"
format_action_impl(e::ExitElevator) = "ExitElevator(e$(e.elevator_idx))"
format_action_impl(e::CloseElevatorDoors) = "CloseElevatorDoors(e$(e.elevator_idx))"
format_action_impl(e::MoveElevator) = "MoveElevator(e$(e.elevator_idx))"
format_action_impl(e::StopElevator) = "StopElevator(e$(e.elevator_idx))"
function format_action_impl(e::DispatchElevator)
    "DispatchElevator([floor |-> $(e.floor), direction |-> \"$(string(e.direction))\"])"
end
format_action_impl(e) = "Unknown($(typeof(e)))"


function format_person_entry(pid, pstate)
    loc_str = isa(pstate["location"], String) ? pstate["location"] : string(pstate["location"])
    "            $pid |-> [location |-> $loc_str, destination |-> $(pstate["destination"]), waiting |-> $(uppercase(string(pstate["waiting"])))]"
end

function format_elevator_entry(eid, estate)
    buttons_str = "{$(join(estate["buttonsPressed"], ", "))}"
    "            $eid |-> [floor |-> $(estate["floor"]), direction |-> \"$(estate["direction"])\", doorsOpen |-> $(uppercase(string(estate["doorsOpen"]))), buttonsPressed |-> $buttons_str]"
end

format_call_entry(call) = "[floor |-> $(call["floor"]), direction |-> \"$(call["direction"])\"]"

function format_state_to_tla(state::Dict{String,Any}, indent::String="")
    lines = String[]

    # PersonState
    push!(lines, "$(indent)PersonState |-> [")
    person_items = [format_person_entry(pid, pstate) for (pid, pstate) in state["PersonState"]]
    push!(lines, join(person_items, ",\n"))
    push!(lines, "$(indent)],")

    # ActiveElevatorCalls
    call_items = [format_call_entry(call) for call in state["ActiveElevatorCalls"]]
    push!(lines, "$(indent)ActiveElevatorCalls |-> {$(join(call_items, ", "))},")

    # ElevatorState
    push!(lines, "$(indent)ElevatorState |-> [")
    elevator_items = [
        format_elevator_entry(eid, estate) for (eid, estate) in state["ElevatorState"]
    ]
    push!(lines, join(elevator_items, ",\n"))
    push!(lines, "$(indent)]")

    return join(lines, "\n")
end

function export_tlc_trace(recorder::TLATraceRecorder, filename::String)
    @info "Writing $filename"
    open(filename, "w") do io
        for (i, state) in enumerate(recorder.states)
            # Add action comment if this is not the initial state
            if i > 1 && i-1 <= length(recorder.transitions)
                trans = recorder.transitions[i - 1]
                println(io, "\\* After $(trans["action"])")
            elseif i == 1
                println(io, "\\* Initial state")
            end

            # Write the state in TLA+ format
            println(io, "[")
            println(io, format_state_to_tla(state, "  "))
            println(io, "]")

            # Add separator between states (except after last state)
            if i < length(recorder.states)
                println(io, "----")
            end
        end
    end
end

"""
Export state and enabled events for a specific point in simulation
"""
function export_current_state(sim, physical, filename::String)
    @info "Writing $filename"
    open(filename, "w") do io
        # Current state
        state = Dict(
            "PersonState" => convert_person_state(physical.person),
            "ActiveElevatorCalls" => convert_active_calls(physical.calls),
            "ElevatorState" => convert_elevator_state(physical.elevator),
        )

        println(io, "Current State:")
        println(io, format_state_to_tla(state))

        # Get and write enabled events
        println(io, "\nEnabled Actions:")
        enabled = get_enabled_events(sim)
        for event in enabled
            println(io, "  - $(format_action(event))")
        end
    end
end

"""
Format a complete TLA+ state as a string
"""
format_tla_state(state::Dict{String,Any}) = format_state_to_tla(state)

"""
Create a TLC configuration file with given invariants and properties
"""
function create_config_file(
    people_count::Int,
    elevator_count::Int,
    floor_count::Int,
    filename::String,
    invariants::Vector{String},
    properties::Vector{String}=String[],
)
    @info "Writing $filename"
    open(filename, "w") do io
        println(
            io,
            """
CONSTANTS
  Person = {$(join(["p$i" for i in 1:people_count], ", "))}
  Elevator = {$(join(["e$i" for i in 1:elevator_count], ", "))}
  FloorCount = $floor_count

INVARIANTS
$(join(["  $inv" for inv in invariants], "\n"))
""",
        )

        if !isempty(properties)
            println(io, "\nPROPERTIES")
            println(io, join(["  $prop" for prop in properties], "\n"))
        end
    end
end

# Convenience functions for specific config types
function create_tlc_config(pc, ec, fc, fn)
    create_config_file(pc, ec, fc, fn, ["TypeInvariant", "SafetyInvariant"], ["TemporalInvariant"])
end

function create_trace_config(pc, ec, fc, fn)
    @info "Writing $fn"
    # For trace checking, we need a dummy INIT and NEXT
    open(fn, "w") do io
        println(
            io,
            """
CONSTANTS
  Person = {$(join(["\"p$i\"" for i in 1:pc], ", "))}
  Elevator = {$(join(["\"e$i\"" for i in 1:ec], ", "))}
  FloorCount = $fc

INIT Init
NEXT Next

INVARIANTS
  TraceTypeInvariant
  TraceSafetyInvariant
""",
        )
    end
end

"""
Run TLC to check the trace specification
"""
function check_trace_with_tlc(
    trace_spec::String, config_file::String, tla_tools_path::String="~/dev/tla"
)
    tla_tools_path = joinpath(expanduser(tla_tools_path), "tla2tools.jar")
    cmd = `java -XX:+UseParallelGC -jar $tla_tools_path -config $config_file $trace_spec`

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
    tla_tools_path::String="~/dev/tla",
)
    tla_tools_path = expanduser(tla_tools_path)

    export_tlc_trace(recorder, "Elevator_trace.txt")

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
Generate a TLA+ module that represents the trace as a sequence of states
This can be model-checked to verify the trace satisfies the specification
"""
function export_trace_spec(recorder::TLATraceRecorder, spec_filename::String)
    @info "Writing $spec_filename"
    open(spec_filename, "w") do io
        # Module header
        module_name = replace(basename(spec_filename), ".tla" => "")
        println(
            io,
            """
$(repeat("-", 4)) MODULE $module_name $(repeat("-", 4))
(* This specification defines a specific trace to be checked against the Elevator spec *)
EXTENDS Sequences, TLC, Integers

(* Import constants from Elevator *)
CONSTANTS   Person,     \\* The set of all people using the elevator system
            Elevator,   \\* The set of all elevators
            FloorCount  \\* The number of floors serviced by the elevator system

(* Define Floor and Direction for invariant checking *)
Floor == 1..FloorCount
Direction == {"Up", "Down"}

(* The recorded trace as a sequence of states *)
TraceStates == <<""",
        )

        # Output each state with action comments
        for (i, state) in enumerate(recorder.states)
            # Add comment about what action led to this state
            if i == 1
                println(io, "    (* Initial state *)")
            elseif i-1 <= length(recorder.transitions)
                trans = recorder.transitions[i - 1]
                println(io, "    (* After $(trans["action"]) *)")
            else
                println(io, "    (* State $i *)")
            end

            println(io, "    [")
            # Format the state with proper indentation
            state_lines = split(format_state_to_tla(state, "        "), "\n")
            println(io, join(state_lines, "\n"))
            print(io, "    ]")
            println(io, i < length(recorder.states) ? "," : "")
        end

        println(io, ">>\n")

        # Add dummy state variables and actions for TLC
        println(
            io,
            """
(* Dummy variables for TLC - we're just checking a static trace *)
VARIABLES dummy

(* Dummy initial state *)
Init == dummy = 0

(* Dummy next state - never actually used *)
Next == dummy' = dummy

(* Type invariant: check structural constraints *)
TraceTypeInvariant == 
    \\A i \\in 1..Len(TraceStates) :
        LET s == TraceStates[i] IN
        /\\ \\A p \\in Person : 
            /\\ \\/ s.PersonState[p].location \\in Floor
               \\/ s.PersonState[p].location \\in {"e1", "e2"}  \\* In an elevator
            /\\ s.PersonState[p].destination \\in Floor
            /\\ s.PersonState[p].waiting \\in BOOLEAN
        /\\ \\A e \\in Elevator :
            /\\ s.ElevatorState[e].floor \\in Floor
            /\\ s.ElevatorState[e].direction \\in (Direction \\cup {"Stationary"})
            /\\ s.ElevatorState[e].doorsOpen \\in BOOLEAN
            /\\ s.ElevatorState[e].buttonsPressed \\subseteq Floor

(* Safety invariant: check semantic constraints *)
TraceSafetyInvariant == 
    \\A i \\in 1..Len(TraceStates) :
        LET s == TraceStates[i] IN
        (* Elevator buttons pressed only if passenger going there *)
        /\\ \\A e \\in Elevator : \\A f \\in s.ElevatorState[e].buttonsPressed :
            \\E p \\in Person :
                /\\ s.PersonState[p].location = e  \\* In elevator e
                /\\ s.PersonState[p].destination = f
        (* Active calls must have someone waiting *)
        /\\ \\A call \\in s.ActiveElevatorCalls :
            \\E p \\in Person :
                LET pState == s.PersonState[p] IN
                /\\ pState.location = call.floor
                /\\ pState.waiting = TRUE
                /\\ (IF pState.destination > call.floor 
                    THEN "Up" ELSE "Down") = call.direction

$(repeat("=", 77))""",
        )
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
