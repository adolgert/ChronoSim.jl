public over_generated_events

"""
    over_generated_events(f::Function, generators, physical, fired_event_key, changed_places)

Given a fired event and the set of places changed by that event, create new events
that may depend on that fired event and those changed places.
"""
function over_generated_events(f::Function, generators, physical, event_key, changed_places) end
