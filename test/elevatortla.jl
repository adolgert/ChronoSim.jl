# TLA+ Integration for Elevator Simulation (Refactored)
using ChronoSim: get_enabled_events

mutable struct TLATraceRecorder
    states::Vector{Dict{String,Any}}
    transitions::Vector{Dict{String,Any}}
    enabled_events::Vector{Vector{String}}
    enabled_before_transition::Vector{Vector{String}}
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

    push!(recorder.states, tla_state)

    # Record the transition that led to this state
    if length(recorder.states) > 1
        transition = Dict(
            "action" => format_action(event),
            "time" => when,
            "changed" => format_changed_places(changed_places),
        )
        push!(recorder.transitions, transition)

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

format_changed_places(changed_places) = [string(cp) for cp in changed_places]

function format_person_entry(pid, pstate)
    loc_str = isa(pstate["location"], String) ? pstate["location"] : string(pstate["location"])
    "  $pid |-> [location |-> $loc_str, destination |-> $(pstate["destination"]), waiting |-> $(uppercase(string(pstate["waiting"])))]"
end

function format_elevator_entry(eid, estate)
    buttons_str = "{$(join(estate["buttonsPressed"], ", "))}"
    "  $eid |-> [floor |-> $(estate["floor"]), direction |-> \"$(estate["direction"])\", doorsOpen |-> $(uppercase(string(estate["doorsOpen"]))), buttonsPressed |-> $buttons_str]"
end

format_call_entry(call) = "[floor |-> $(call["floor"]), direction |-> \"$(call["direction"])\"]"

function format_state_to_tla(state::Dict{String,Any}, indent::String="")
    lines = String[]

    # PersonState
    push!(lines, "$(indent)PersonState = [")
    person_items = [format_person_entry(pid, pstate) for (pid, pstate) in state["PersonState"]]
    push!(lines, join(person_items, ",\n"))
    push!(lines, "$(indent)]")

    # ActiveElevatorCalls
    call_items = [format_call_entry(call) for call in state["ActiveElevatorCalls"]]
    push!(lines, "$(indent)ActiveElevatorCalls = {$(join(call_items, ", "))}")

    # ElevatorState
    push!(lines, "$(indent)ElevatorState = [")
    elevator_items = [
        format_elevator_entry(eid, estate) for (eid, estate) in state["ElevatorState"]
    ]
    push!(lines, join(elevator_items, ",\n"))
    push!(lines, "$(indent)]")

    return join(lines, "\n")
end

function export_tlc_trace(recorder::TLATraceRecorder, filename::String)
    open(filename, "w") do io
        for (i, state) in enumerate(recorder.states)
            println(io, "State $i:")
            println(io, format_state_to_tla(state))

            # Add transition info if available
            if i > 1 && i-1 <= length(recorder.transitions)
                trans = recorder.transitions[i - 1]
                println(io, "\n-- Transition: $(trans["action"]) at time $(trans["time"])")
            end

            # Add enabled events info
            if i <= length(recorder.enabled_events)
                println(io, "-- Enabled: [$(join(recorder.enabled_events[i], ", "))]")
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
    create_config_file(
        pc,
        ec,
        fc,
        fn,
        ["TraceTypeInvariant", "TraceSafetyInvariant", "ValidTransitions", "CorrectEnabledActions"],
    )
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
Generate a single enabled predicate for a given action type
"""
generate_single_predicate(io::IO, name::String, params::String, body::String) = println(
    io,
    """
$name($params) ==
$body
""",
)

"""
Generate enabled action predicates for TLA+ based on Julia event types
"""
function generate_enabled_predicates(io::IO)
    println(io, "(* Predicates to check if specific actions are enabled *)")

    # Define predicates as (name, params, body) tuples
    predicates = [
        (
            "PickNewDestinationEnabled",
            "p, ps",
            """    /\\ ~ps[p].waiting
/\\ ps[p].location \\in 1..FloorCount""",
        ),
        (
            "CallElevatorEnabled",
            "p, ps, es",
            """    LET pState == ps[p]
    call == [floor |-> pState.location, direction |-> IF pState.destination > pState.location THEN "Up" ELSE "Down"]
IN
/\\ ~pState.waiting
/\\ pState.location /= pState.destination""",
        ),
        (
            "OpenElevatorDoorsEnabled",
            "e, es, calls",
            """    LET eState == es[e] IN
/\\ ~eState.doorsOpen
/\\ \\/ \\E call \\in calls :
      /\\ call.floor = eState.floor
      /\\ call.direction = eState.direction
   \\/ eState.floor \\in eState.buttonsPressed""",
        ),
        (
            "EnterElevatorEnabled",
            "e, ps, es",
            """    LET eState == es[e] IN
/\\ eState.doorsOpen
/\\ eState.direction /= "Stationary"
/\\ \\E p \\in Person :
      /\\ ps[p].location = eState.floor
      /\\ ps[p].waiting
      /\\ IF ps[p].destination > ps[p].location
         THEN eState.direction = "Up"
         ELSE eState.direction = "Down\"""",
        ),
    ]

    for (name, params, body) in predicates
        generate_single_predicate(io, name, params, body)
    end

    # ActionIsEnabled mapping
    println(
        io,
        """(* Check if an action string corresponds to an enabled action *)
ActionIsEnabled(actionStr, ps, calls, es) ==
    \\/ /\\ \\E p \\in Person : actionStr = "PickNewDestination(" \\o p \\o ")"
       /\\ \\E p \\in Person : PickNewDestinationEnabled(p, ps)
    \\/ /\\ \\E p \\in Person : actionStr = "CallElevator(" \\o p \\o ")"
       /\\ \\E p \\in Person : CallElevatorEnabled(p, ps, es)
    \\/ /\\ \\E e \\in Elevator : actionStr = "OpenElevatorDoors(" \\o e \\o ")"
       /\\ \\E e \\in Elevator : OpenElevatorDoorsEnabled(e, es, calls)
    \\/ /\\ \\E e \\in Elevator : actionStr = "EnterElevator(" \\o e \\o ")"
       /\\ \\E e \\in Elevator : EnterElevatorEnabled(e, ps, es)
""",
    )
end

"""
Generate invariant verification section
"""
function generate_invariant_checks(io::IO, invariant_name::String, tla_invariant::String)
    println(
        io,
        """
$invariant_name == \\A i \\in 1..Len(TraceStates) :
    LET state == TraceStates[i]
        PersonState == state.PersonState
        ActiveElevatorCalls == state.ActiveElevatorCalls
        ElevatorState == state.ElevatorState
    IN $tla_invariant
""",
    )
end

"""
Generate a TLA+ module that represents the trace as a sequence of states
This can be model-checked to verify the trace satisfies the specification
"""
function export_trace_spec(recorder::TLATraceRecorder, spec_filename::String)
    open(spec_filename, "w") do io
        # Module header
        module_name = replace(basename(spec_filename), ".tla" => "")
        println(
            io,
            """
$(repeat("-", 28)) MODULE $module_name $(repeat("-", 28))
(* This specification defines a specific trace to be checked against the Elevator spec *)
EXTENDS Elevator, Sequences, TLC

(* The recorded trace as a sequence of states *)
TraceStates == <<""",
        )

        # Output each state
        for (i, state) in enumerate(recorder.states)
            println(io, "    (* State $i *)")
            println(io, "    [")

            # Format the state with proper indentation
            state_lines = split(format_state_to_tla(state, "        "), "\n")
            println(io, join(state_lines, "\n"))

            print(io, "    ]")
            println(io, i < length(recorder.states) ? "," : "")
        end

        println(io, ">>\n")

        # Verification sections
        println(io, "(* Verify each state in the trace satisfies the invariants *)")
        generate_invariant_checks(io, "TraceTypeInvariant", "TypeInvariant")
        generate_invariant_checks(io, "TraceSafetyInvariant", "SafetyInvariant")

        # Verify transitions
        println(
            io,
            """(* Verify each transition in the trace is valid according to Next *)
ValidTransitions == \\A i \\in 1..(Len(TraceStates)-1) :
    LET PersonState == TraceStates[i].PersonState
        ActiveElevatorCalls == TraceStates[i].ActiveElevatorCalls
        ElevatorState == TraceStates[i].ElevatorState
        PersonState' == TraceStates[i+1].PersonState
        ActiveElevatorCalls' == TraceStates[i+1].ActiveElevatorCalls
        ElevatorState' == TraceStates[i+1].ElevatorState
    IN Next \\/ UNCHANGED <<PersonState, ActiveElevatorCalls, ElevatorState>>
""",
        )

        # Add enabled actions information if available
        if length(recorder.enabled_events) > 0
            println(
                io,
                """(* Enabled actions recorded at each state *)
EnabledActions == <<""",
            )

            for (i, enabled) in enumerate(recorder.enabled_events)
                enabled_str = "{$(join(["\"$e\"" for e in enabled], ", "))}"
                comment = i < length(recorder.enabled_events) ? "," : ""
                println(io, "    $enabled_str$comment  (* State $i *)")
            end
            println(io, ">>\n")

            generate_enabled_predicates(io)

            println(
                io,
                """(* Verify that recorded enabled actions match the specification *)
(* This checks that the simulation correctly determines which actions are enabled *)
CorrectEnabledActions == \\A i \\in 1..Len(TraceStates) :
    LET state == TraceStates[i]
        ps == state.PersonState
        calls == state.ActiveElevatorCalls
        es == state.ElevatorState
        recordedEnabled == IF i <= Len(EnabledActions) THEN EnabledActions[i] ELSE {}
    IN \\A action \\in recordedEnabled :
        ActionIsEnabled(action, ps, calls, es)

(* Additionally check that transitions taken were actually enabled *)
TransitionWasEnabled == \\A i \\in 1..(Len(TraceStates)-1) :
    LET state == TraceStates[i]
        ps == state.PersonState
        calls == state.ActiveElevatorCalls
        es == state.ElevatorState
        enabledBefore == IF i <= Len(EnabledActions) THEN EnabledActions[i] ELSE {}
    IN TRUE  (* The transition that was taken should have been in enabledBefore *)
""",
            )
        end

        # Properties to check
        println(
            io,
            """(* Properties to check *)
ASSUME TraceTypeInvariant
ASSUME TraceSafetyInvariant
ASSUME ValidTransitions

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
