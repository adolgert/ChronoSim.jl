export DependencyNetwork, add_event!, remove_event!, getplace
using Base

const DNPlaceKey = Tuple
DoubleEdge{T} = @NamedTuple{en::Set{T}, ra::Set{T}}


"""
This is a multi-graph from places to events.
It is a multi-graph because there can be two kinds of edges from the
same place to the same event: an enabling edge and a rate edge.
The graph is mutable, too, so you can add and remove events which adds
and removes edges from the graph.
"""
struct DependencyNetwork{E}
    place::Dict{DNPlaceKey,DoubleEdge{E}}
    event::Dict{E,DoubleEdge{DNPlaceKey}}

    function DependencyNetwork{E}() where {E}
        new(Dict{DNPlaceKey,DoubleEdge{E}}(), Dict{E,DoubleEdge{DNPlaceKey}}())
    end
end


function add_event!(net::DependencyNetwork{E}, evtkey, enplaces, raplaces) where {E}
    remove_event!(net, [evtkey])

    # Create the reverse mapping for this event
    en_place_set = Set{DNPlaceKey}(enplaces)
    ra_place_set = Set{DNPlaceKey}(raplaces)
    net.event[evtkey] = (en=en_place_set, ra=ra_place_set)

    # Add enabling edges
    for place in enplaces
        if haskey(net.place, place)
            push!(net.place[place].en, evtkey)
        else
            en_set = Set{E}([evtkey])
            ra_set = Set{E}()
            net.place[place] = (en=en_set, ra=ra_set)
        end
    end

    # Add rate edges
    for place in raplaces
        if haskey(net.place, place)
            push!(net.place[place].ra, evtkey)
        else
            en_set = Set{E}()
            ra_set = Set{E}([evtkey])
            net.place[place] = (en=en_set, ra=ra_set)
        end
    end
end


function remove_event!(net::DependencyNetwork{E}, evtkeys) where {E}
    for evtkey in evtkeys
        # Get the places this event depends on
        if haskey(net.event, evtkey)
            event_deps = net.event[evtkey]

            # Remove from enabling places
            for place in event_deps.en
                if haskey(net.place, place)
                    delete!(net.place[place].en, evtkey)
                    # Clean up empty place entries if both sets are empty
                    if isempty(net.place[place].en) && isempty(net.place[place].ra)
                        delete!(net.place, place)
                    end
                end
            end

            # Remove from rate places
            for place in event_deps.ra
                if haskey(net.place, place)
                    delete!(net.place[place].ra, evtkey)
                    # Clean up empty place entries if both sets are empty
                    if isempty(net.place[place].en) && isempty(net.place[place].ra)
                        delete!(net.place, place)
                    end
                end
            end

            # Remove the event from the event dictionary
            delete!(net.event, evtkey)
        end
    end
end


function getplace(net::DependencyNetwork{E}, place) where {E}
    get(net.place, place, (en=Set{E}(), ra=Set{E}()))
end

function getplace_enable(net::DependencyNetwork{E}, place) where {E}
    get(net.place, place, (en=Set{E}(), ra=Set{E}())).en
end

function getplace_rate(net::DependencyNetwork{E}, place) where {E}
    get(net.place, place, (en=Set{E}(), ra=Set{E}())).ra
end

export DepNetNaive

"""
For testing, we make an equivalent version of the dependency network
but this one uses a very different internal structure, an edge list.
"""
mutable struct DepNetNaive
    enable::Vector{Tuple{Any,Any}}
    rate::Vector{Tuple{Any,Any}}

    DepNetNaive() = new(Vector{Tuple{Any,Any}}(), Vector{Tuple{Any,Any}}())
end


function add_event!(net::DepNetNaive, evtkey, enplaces, raplaces)
    remove_event!(net, [evtkey])
    for enplace in enplaces
        (evtkey, enplace) in net.enable && continue
        push!(net.enable, (evtkey, enplace))
    end
    for raplace in raplaces
        (evtkey, raplace) in net.rate && continue
        push!(net.rate, (evtkey, raplace))
    end
end


function remove_event!(net::DepNetNaive, evtkeys)
    filter!(edge -> edge[1] ∉ evtkeys, net.enable)
    filter!(edge -> edge[1] ∉ evtkeys, net.rate)
end


function getplace(net::DepNetNaive, place)
    en_events = Set(evtkey for (evtkey, placekey) in net.enable if placekey == place)
    ra_events = Set(evtkey for (evtkey, placekey) in net.rate if placekey == place)
    return (en=en_events, ra=ra_events)
end


function getplace_enable(net::DepNetNaive, place)
    return Set(evtkey for (evtkey, placekey) in net.enable if placekey == place)
end


function getplace_rate(net::DepNetNaive, place)
    return Set(evtkey for (evtkey, placekey) in net.rate if placekey == place)
end
