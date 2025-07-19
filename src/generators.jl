using Logging: Logging

##### Helpers for events

export EventGenerator, generators, GeneratorSearch, GenMatches, ToEvent, ToPlace
export over_generated_events

@enum GenMatches ToEvent ToPlace

"""
    EventGenerator{TransitionType}(matchstr, generator::Function)

When an event fires, it changes the physical state. The simulation observes which
parts of the physical state changed and sends those parts to this `EventGenerator`.
The `EventGenerator` is a rule that matches changes to the physical state and creates
`SimEvent` that act on that physical state.

The `matchstr` is a list of symbols `(array_name, ℤ, struct_member)`. The ℤ represents
the integer index within the array. For instance, if we simulated chess, it might
be `(:board, ℤ, :piece)`.

The generator is a callback that the simulation uses to determine which events
need to be enabled given recent changes to the state of the board. Its signature
is:

```
    callback_function(f::Function, physical_state, indices...)
```

Here the indices are the integer index that matches the ℤ above. This callback
function should look at the physical state and call `f(transition)` where
`transition` is an instance of `SimEvent`.
"""
struct EventGenerator
    match_what::GenMatches
    matchstr::Vector{Symbol}
    generator::Function
end

matches_event(eg::EventGenerator) = eg.match_what == ToEvent
matches_place(eg::EventGenerator) = eg.match_what == ToPlace

"""
    generators(::Type{SimEvent})::Vector{EventGenerator}

Every transition in the simulation needs generators that notice changes to state
or events fired and create the appropriate transitions. Implement a `generators`
function as part of the interface of each transition.
"""
generators(::Type{<:SimEvent}) = EventGenerator[]

struct GeneratorSearch
    event_to_event::Dict{Symbol,Vector{Function}}
    # Think of this as a two-level trie.
    byarray::Dict{Symbol,Dict{Symbol,Vector{Function}}}
end

function Base.show(io::IO, generators::GeneratorSearch)
    by_event = [(sym, length(funcs)) for (sym, funcs) in generators.event_to_event]
    println(io, "OnEvent: $(by_event)")
    on_place = Tuple{Symbol,Symbol,Int}[]
    for arrkey in keys(generators.byarray)
        for propkey in keys(generators.byarray[arrkey])
            push!(on_place, (arrkey, propkey, length(generators.byarray[arrkey][propkey])))
        end
    end
    println(io, "OnPlace: $(on_place)")
end

function over_generated_events(f::Function, generators, physical, event_key, changed_places)
    event_args = event_key[2:end]
    for from_event in get(generators.event_to_event, event_key[1], Function[])
        from_event(f, physical, event_args...)
    end
    # Every place is (arrayname, integer index in array, struct member)
    for place in changed_places
        place_idx = place[2]
        for genfunc in get(
            get(generators.byarray, place[1], Dict{Symbol,Vector{Function}}()), place[3], Function[]
        )
            genfunc(f, physical, place_idx)
        end
    end
end

function GeneratorSearch(generators::Vector{EventGenerator})
    from_event = Dict{Symbol,Vector{Function}}()
    from_array = Dict{Symbol,Dict{Symbol,Vector{Function}}}()
    for add_gen in generators
        if matches_event(add_gen)
            struct_name = add_gen.matchstr[1]
            rule_set = get!(from_event, struct_name, Function[])
            push!(rule_set, add_gen.generator)
        elseif matches_place(add_gen)
            struct_name = add_gen.matchstr[1]
            property_name = add_gen.matchstr[3]
            if struct_name ∉ keys(from_array)
                from_array[struct_name] = Dict{Symbol,Vector{Function}}()
            end
            rule_set = get!(from_array[struct_name], property_name, Function[])
            push!(rule_set, add_gen.generator)
        else
            error("event generator should match place or event")
        end
    end
    GeneratorSearch(from_event, from_array)
end
