

"""
    EventDependency{ClockKey}(event_generator)

Represents the dependency graph between the set of events and the set of
physical states. It uses clock keys to represent events and physical addresses
to represent the physical state. This struct combines dynamic event generation
with a static graph in order to present to the framework a unified version of
the bipartite graph of events and physical state. It could be replaced by a
static graph of events and physical states, such as is used in generalized
stochastic Petri nets (GSPN).
"""
struct EventDependency{CK}
    depnet::DependencyNetwork{CK}
    eventgen::GeneratorSearch
    seen::Set{CK}
    EventDependency{CK}(eventgen) where {CK} = new(DependencyNetwork{CK}(), eventgen, Set{CK}())
end


function over_event_invariants(
    cb::Function, dependency::EventDependency, sim, fired_event_keys, changed_places
)
    enabled_events = sim.enabled_events
    empty!(dependency.seen)
    @assert !isempty(changed_places)

    # Candidates are collected and sorted by clock key before the callback runs.
    # The callback enables clocks, which draws from the shared RNG, so the
    # trajectory would otherwise depend on the order generators happen to
    # propose events. Sorting makes the trajectory a function of the proposed
    # SET alone, so two generator sets that propose the same events (e.g.
    # hand-written vs. derived) yield identical trajectories under one seed.
    candidates = Vector{Any}()

    cond_affected = union((getplace_enable(dependency.depnet, cp) for cp in changed_places)...)
    for cond_key in cond_affected
        cond_evt = enabled_events[cond_key]
        push!(candidates, cond_evt)
        push!(dependency.seen, cond_key)
    end

    over_generated_events(
        dependency.eventgen, sim.physical, fired_event_keys, changed_places
    ) do newevent
        newevent_key = clock_key(newevent)
        if !in(newevent_key, dependency.seen)
            push!(candidates, newevent)
            push!(dependency.seen, newevent_key)
        end
    end

    sort!(candidates; by=clock_key)
    for event in candidates
        cb(event)
    end
end


"""
Note that this method requires a first call to `over_event_invariants` and that
this method interacts with that call by excluding events that were iterated in
`over_event_invariants`.
"""
function over_event_rates(
    cb::Function, dependency::EventDependency, sim, fired_event_keys, changed_places
)
    enabled_events = sim.enabled_events
    @assert !isempty(changed_places)

    rate_affected = union((getplace_rate(dependency.depnet, cp) for cp in changed_places)...)
    # Sorted for the same reason as over_event_invariants: re-enabling draws
    # from the shared RNG, so processing order must not depend on Set order.
    for rate_key in sort!(collect(rate_affected))
        rate_evt = enabled_events[rate_key]
        # This is where this method depends on the `over_event_invariants` method.
        if !in(rate_key, dependency.seen)
            cb(rate_evt)
            push!(dependency.seen, rate_key)
        end
    end
end


function add_event!(net::EventDependency{E}, evtkey, enplaces, raplaces) where {E}
    add_event!(net.depnet, evtkey, enplaces, raplaces)
end

remove_event!(net::EventDependency{E}, evtkeys) where {E} = remove_event!(net.depnet, evtkeys)

function getevent_enable(net::EventDependency{E}, event_key) where {E}
    getevent_enable(net.depnet, event_key)
end

getevent_rate(net::EventDependency{E}, event_key) where {E} = getevent_rate(net.depnet, event_key)
