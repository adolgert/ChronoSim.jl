
struct EventDependency{CK}
    depnet::DependencyNetwork{CK}
    eventgen::GeneratorSearch
    seen::Set{SimEvent}
    function EventDependency{CK}(eventgen) where {CK}
        new(DependencyNetwork{CK}(), eventgen, Set{SimEvent}())
    end
end


function over_event_invariants(
    cb::Function, dependency::EventDependency, sim, fired_event_keys, changed_places
)
    enabled_events = sim.enabled_events
    empty!(dependency.seen)
    @assert !isempty(changed_places)

    cond_affected = union((getplace_enable(dependency.depnet, cp) for cp in changed_places)...)
    for cond in cond_affected
        cond_evt = enabled_events[cond]
        cb(cond_evt)
        push!(dependency.seen, cond_evt)
    end

    over_generated_events(
        dependency.eventgen, sim.physical, fired_event_keys, changed_places
    ) do newevent
        if !in(newevent, dependency.seen)
            cb(newevent)
            push!(dependency.seen, newevent)
        end
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
    for rate in rate_affected
        rate_evt = enabled_events[rate]
        # This is where this method depends on the `over_event_invariants` method.
        if !in(rate_evt, dependency.seen)
            cb(rate_evt)
            push!(dependency.seen, rate_evt)
        end
    end
end


function add_event!(net::EventDependency{E}, evtkey, enplaces, raplaces) where {E}
    add_event!(net.depnet, evtkey, enplaces, raplaces)
end

remove_event!(net::EventDependency{E}, evtkeys) where {E} = remove_event!(net.depnet, evtkeys)

getevent_enable(net::EventDependency{E}, event) where {E} = getevent_enable(net.depnet, event)

getevent_rate(net::EventDependency{E}, event) where {E} = getevent_rate(net.depnet, event)
