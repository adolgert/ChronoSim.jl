using Logging
using Random
using CompetingClocks:
    SSA, CombinedNextReaction, enable!, disable!, next, keytype, steploglikelihood

using Distributions

export SimulationFSM

########## The Simulation Finite State Machine (FSM)

mutable struct SimulationFSM{State,Sampler,CK}
    physical::State
    sampler::Sampler
    immediategen::GeneratorSearch
    when::Float64
    rng::Xoshiro
    event_dependency::EventDependency{CK}
    enabled_events::Dict{CK,SimEvent}
    enabling_times::Dict{CK,Float64}
    observer
end


"""
Look at events and determine a common base type.
Internally the simulation tracks events with sets of tuples by turning
each event instance into a tuple. If all the tuples have the same type,
this should turn out to be performant.
"""
function common_base_key_tuple(events)
    all_field_types = [Tuple{Symbol,fieldtypes(T)...} for T in events]
    typejoined = reduce(typejoin, all_field_types)
    return typejoined
end


"""
    SimulationFSM(physical_state, trans_rules; seed, rng, sampler, observer=nothing)

Create a simulation.

The `physical_state` is of type `PhysicalState`. The sampler is of type
`CompetingClocks.SSA`. The `trans_rules` are a list of type `SimEvent`.
The seed is an integer seed for a `Xoshiro` random number generator. The
observer is a callback with the signature:

```
observer(physical, when::Float64, event::SimEvent, changed_places::AbstractSet{Tuple})
```

The `changed_places` argument is a set-like object with tuples that are keys that
represent which places were changed.
"""
function SimulationFSM(
    physical, events; sampler=nothing, observer=nothing, rng=nothing, seed=nothing
)
    randgen = if !isnothing(rng)
        rng
    elseif !isnothing(seed)
        Xoshiro(seed)
    else
        Xoshiro()
    end

    if isnothing(sampler)
        ClockKey = common_base_key_tuple(events)
        sampler = CombinedNextReaction{ClockKey,Float64}()
        @debug "Creating a sampler with clock key type $ClockKey"
    else
        ClockKey = keytype(sampler)
    end
    generator_searches = generators_from_events(events)
    if isnothing(observer)
        observer = (args...) -> nothing
    end
    return SimulationFSM{typeof(physical),typeof(sampler),ClockKey}(
        physical,
        sampler,
        generator_searches["immediate"],
        0.0,
        randgen,
        EventDependency{ClockKey}(generator_searches["timed"]),
        Dict{ClockKey,SimEvent}(),
        Dict{ClockKey,Float64}(),
        observer,
    )
end


function checksim(sim::SimulationFSM)
    @assert keys(sim.enabled_events) == keys(sim.event_dependency.depnet.event)
end

struct ModelDefinitionError <: Exception
    context::String
    event_type::Type
    event::Any
    cause::Exception
    backtrace::Vector
end

function Base.showerror(io::IO, e::ModelDefinitionError)
    println(io, "Error in user-defined $(e.context) for $(e.event_type)")
    println(io, "  Event: $(e.event)")
    println(io, "  Caused by:")
    showerror(io, e.cause)
    println(io, "\n\nIn model code:")
    Base.show_backtrace(io, e.backtrace)
end

function invoke_user_code(f::Function, context::String, event::SimEvent)
    try
        return f()
    catch e
        bt = catch_backtrace()
        throw(ModelDefinitionError(context, typeof(event), event, e, bt))
    end
end

"""
The three `sim_event_*` functions call user-defined code, so we separate this
out in order to check the calls and return values. This also provides a way
to mock interaction with both events and the sampler for testing the central
function `deal_with_changes()`. Subclass `SimEvent` to create a fake interaction.
"""
function sim_event_precondition(event::SimEvent, physical)
    reads_result = capture_state_reads(physical) do
        invoke_user_code("precondition", event) do
            precondition(event, physical)
        end
    end
    return reads_result
end


function sim_event_enable(event::SimEvent, event_key, sim, when)
    reads_result = capture_state_reads(sim.physical) do
        enabling_spec = invoke_user_code("enable", event) do
            enable(event, sim.physical, when)
        end
        if length(enabling_spec) != 2
            error("""The enable() function for $event_key should return a
                distribution and a time. This one returns $enabling_spec.
                """)
        end
        return enabling_spec
    end
    (dist, enable_time) = reads_result.result
    enable!(sim.sampler, event_key, dist, enable_time, sim.when, sim.rng)
    return (; reads=reads_result.reads)
end


function sim_event_reenable(event::SimEvent, event_key, sim)
    first_enable = sim.enabling_times[event_key]
    reads_result = capture_state_reads(sim.physical) do
        invoke_user_code("reenable", event) do
            reenable(event, sim.physical, first_enable, sim.when)
        end
    end
    if !isnothing(reads_result.result)
        (dist, enable_time) = reads_result.result
        enable!(sim.sampler, event_key, dist, enable_time, sim.when, sim.rng)
    end
    return reads_result.reads
end


"""
    deal_with_changes(sim::SimulationFSM, event_dependency, fired_event_keys, changed_places)

An event changed the state. This function modifies events to respond to changes in state.

 * `sim` - the simulation
 * `event_dependency` - the bipartite graph of addresses and clocks, separated out from the sim
   so that we can test more easily.
 * `fired_event_keys` - a list of what fired. It's a list because of immediate events.
 * `changed_places` - the addresses of physical state affected by firing.
"""
function deal_with_changes(
    sim::SimulationFSM{State,Sampler,CK}, event_dependency, fired_event_keys, changed_places
) where {State,Sampler,CK}
    # This function starts with enabled events. It ends with enabled events.
    # Let's look at just those events that depend on changed places.
    #                      Finish
    #                 Enabled     Disabled
    # Start  Enabled  re-enable   remove
    #       Disabled  create      nothing
    #
    # Sort for reproducibility run-to-run.
    isempty(changed_places) && return nothing

    clock_toremove = CK[]
    over_event_invariants(event_dependency, sim, fired_event_keys, changed_places) do event
        check_clock_key = clock_key(event)
        event_should_be_enabled, depends_places = sim_event_precondition(event, sim.physical)
        # While the current dependency network knows if it was enabled, we check it here
        # in case we use a dependency graph that doesn't depend on the current state.
        event_was_enabled = check_clock_key ∈ keys(sim.enabled_events)

        if event_was_enabled && !event_should_be_enabled
            push!(clock_toremove, check_clock_key)
        elseif !event_was_enabled && event_should_be_enabled
            sim.enabled_events[check_clock_key] = event
            sim.enabling_times[check_clock_key] = sim.when
            rate_deps, = sim_event_enable(event, check_clock_key, sim, sim.when)
            @debug "Evtkey $(check_clock_key) with enable deps $(depends_places) rate deps $(rate_deps)"
            add_event!(event_dependency, check_clock_key, depends_places, rate_deps)
        elseif event_was_enabled && event_should_be_enabled
            # Every time we check an invariant after a state change, we must
            # re-calculate how it depends on the state. For instance,
            # A can move right. Then A moves down. Then A can still move
            # right, but its moving right now depends on a different space
            # to the right. This is because a "move right" event is defined
            # relative to a state, not on a specific, absolute set of places.
            depended_on_places = getevent_enable(event_dependency, check_clock_key)
            @assert eltype(depends_places) == eltype(depended_on_places)
            if depends_places != depended_on_places
                rate_deps = sim_event_reenable(event, check_clock_key, sim)
                add_event!(event_dependency, check_clock_key, depends_places, rate_deps)
            else
                rate_deps = getevent_rate(event_dependency, check_clock_key)
                @assert eltype(rate_deps) == eltype(changed_places)
                if !isdisjoint(rate_deps, changed_places)
                    new_rate_deps = sim_event_reenable(event, check_clock_key, sim)
                    if rate_deps != new_rate_deps
                        add_event!(event_dependency, check_clock_key, depends_places, new_rate_deps)
                    end
                end
            end
            # else event wasn't enabled and it isn't now.
        end
    end

    disable_clocks!(sim, clock_toremove)

    over_event_rates(event_dependency, sim, fired_event_keys, changed_places) do event
        rate_clock_key = clock_key(event)
        rate_event = get(sim.enabled_events, rate_clock_key, nothing)
        if !isnothing(rate_event)
            rate_deps = getevent_rate(event_dependency, rate_clock_key)
            new_rate_deps = sim_event_reenable(rate_event, rate_clock_key, sim)
            if rate_deps != new_rate_deps
                cond_deps = getevent_enable(event_dependency, rate_clock_key)
                add_event!(event_dependency, rate_clock_key, cond_deps, new_rate_deps)
            end
            # else it won't be in event_dependency either so nothing to add/delete.
        end
    end
end


function disable_clocks!(sim::SimulationFSM, clock_keys)
    isempty(clock_keys) && return nothing
    @debug "Disable clock $(clock_keys)"
    for clock_done in clock_keys
        disable!(sim.sampler, clock_done, sim.when)
        delete!(sim.enabled_events, clock_done)
        delete!(sim.enabling_times, clock_done)
    end
    remove_event!(event_dependency, clock_keys)
end


function modify_state!(sim::SimulationFSM, fire_event)
    changes_result = capture_state_changes(sim.physical) do
        fire!(fire_event, sim.physical, sim.when, sim.rng)
    end
    changed_places = changes_result.changes
    seen_immediate = SimEvent[]
    over_generated_events(
        sim.immediategen, sim.physical, clock_key(fire_event), changed_places
    ) do newevent
        if newevent ∉ seen_immediate && precondition(newevent, sim.physical)
            push!(seen_immediate, newevent)
            ans = capture_state_changes(sim.physical) do
                fire!(newevent, sim.physical, sim.when, sim.rng)
            end
            push!(changed_places, ans.changes)
        end
    end
    return changed_places
end

"""
    fire!(sim::SimulationFSM, time, event_key)

Let the event act on the state.
"""
function fire!(sim::SimulationFSM, when, what)
    sim.when = when
    event = sim.enabled_events[what]
    # Break the invariant that state and events are consistent.
    changed_places = modify_state!(sim, event)
    disable_clocks!(sim, [what])
    deal_with_changes(sim, sim.event_dependency, what, changed_places)
    checksim(sim)
    # Invariant for states and events is restored, so show the result.
    sim.observer(sim.physical, when, event, changed_places)
end

get_enabled_events(sim::SimulationFSM) = collect(values(sim.enabled_events))

"""
Initialize the simulation. You could call it as a do-function.
It is structured this way so that the simulation will record changes to the
physical state.
```
    initialize!(sim) do init_physical
        initialize!(init_physical, agent_cnt, sim.rng)
    end
```
"""
function initialize!(init_evt, callback::Function, sim::SimulationFSM)
    changes_result = capture_state_changes(sim.physical) do
        callback(sim.physical, sim.when, sim.rng)
    end
    # The `what` event is type Nothing to signal it isn't an event.
    deal_with_changes(sim, sim.event_dependency, nothing, changes_result.changes)
    checksim(sim)
    sim.observer(sim.physical, sim.when, init_evt, changes_result.changes)
end


"""
    run(simulation, initializer, stop_condition)

Given a simulation, this initializes the physical state and generates a
trajectory from the simulation until the stop condition is met. The `initializer`
is either a function whose argument is a physical state and returns nothing, or
it is an event key for an event that initializes the system. The
stop condition is a function with the signature:

```
stop_condition(physical_state, step_idx, event::SimEvent, when)::Bool
```

The event and when passed into the stop condition are the event and time that are
about to fire but have not yet fired. This lets you enforce a stopping time that
is between events.
"""
function run(sim::SimulationFSM, init_evt::SimEvent, init_func::Function, stop_condition::Function)
    step_idx = 0
    initialize!(init_evt, init_func, sim)
    stop_condition(sim.physical, step_idx, init_evt, sim.when) && return nothing
    step_idx += 1
    while true
        (when, what) = next(sim.sampler, sim.when, sim.rng)
        if isfinite(when) && !isnothing(what)
            stop_condition(sim.physical, step_idx, what, when) && break
            @debug "Firing $what at $when"
            fire!(sim, when, what)
        else
            @info "No more events to process after $step_idx iterations."
            break
        end
        step_idx += 1
    end
    step_idx
end

function run(sim::SimulationFSM, init_evt::SimEvent, stop_condition::Function)
    init_func = (physical, when, rng) -> fire!(init_evt, physical, when, rng)
    run(sim, init_evt, init_func, stop_condition)
end

function run(sim::SimulationFSM, initializer::Function, stop_condition::Function)
    run(sim, InitializeEvent(), initializer, stop_condition)
end

"""
The `trace` is a `Vector{Tuple{Float64,SimEvent}}`. That is, it's a list of
tuples containing `(when, what event)`.
In order to calculate log-likelihood of a simulation, pass it a sampler that
tracks log-likelihood. For instance,
```julia
base_sampler = CombinedNextReaction{K,T}()
memory_sampler = MemorySampler(base_sampler)
```
"""
function trace_likelihood(sim::SimulationFSM, init_evt::SimEvent, init_func::Function, trace)
    loglikelihood = zero(Float64)
    initialize!(init_evt, init_func, sim)
    for (step_idx, step_evt) in enumerate(trace)
        (when, what) = step_evt
        if isfinite(when) && !isnothing(what)
            @debug "Firing $what at $when"
            @assert when > sim.when
            loglikelihood += steploglikelihood(sim.sampler.track, sim.when, when, what)
            fire!(sim, when, what)
        else
            @info "No more events to process after $step_idx iterations."
            break
        end
    end
    loglikelihood
end

function trace_likelihood(sim::SimulationFSM, initializer::SimEvent, trace)
    init_func = (physical, when, rng) -> fire!(initializer, physical, when, rng)
    trace_likelihood(sim, initializer, init_func, trace)
end

function trace_likelihood(sim::SimulationFSM, initializer::Function, trace)
    trace_likelihood(sim, InitializeEvent(), initializer, trace)
end
