using Logging: Logging

##### Helpers for events

export EventGenerator, generators, GeneratorSearch, GenMatches, ToEvent, ToPlace
export over_generated_events, @reactto
export ToEvent, ToPlace

@enum GenMatches ToEvent ToPlace

const MEMBERINDEX = Member(:_index)

function placekey_mask_index(placekey)
    mvec = Vector{Member}(undef, length(placekey))
    for i in eachindex(placekey)
        if isa(placekey[i], Member)
            mvec[i] = placekey[i]
        else
            mvec[i] = MEMBERINDEX
        end
    end
    return Tuple(mvec)
end

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
    matchstr::Vector{Any} # This is a specification data structure.
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

struct GeneratorSearch{DictType}
    event_to_event::Dict{Symbol,Vector{Function}}
    # Think of this as a two-level trie.
    byarray::DictType
end

function Base.show(io::IO, generators::GeneratorSearch)
    by_event = [(sym, length(funcs)) for (sym, funcs) in generators.event_to_event]
    println(io, "OnEvent: $(by_event)")
    on_place = collect(keys(generators.byarray))
    println(io, "OnPlace: $(on_place)")
end

function over_generated_events(
    f::Function, generators::Vector{EventGenerator}, physical, event_key, changed_places
)
    event_args = event_key[2:end]
    for from_event in get(generators.event_to_event, event_key[1], Function[])
        from_event(f, physical, event_args...)
    end
    # Every place is (arrayname, integer index in array, struct member)
    for place in changed_places
        key = placekey_mask_index(place)
        inds = [val for val in placekey if !isa(val, Member)]
        for genfunc in get(generators.byarray, key, Function[])
            genfunc(f, physical, inds...)
        end
    end
end

function GeneratorSearch(generators::Vector{EventGenerator})
    from_event = Dict{Symbol,Vector{Function}}()
    for add_gen in filter(matches_event, generators)
        struct_name = add_gen.matchstr[1]
        rule_set = get!(from_event, struct_name, Function[])
        push!(rule_set, add_gen.generator)
    end

    matchlens = [length(gen.matchstr) in filter(matches_place, generators)]
    if allequal(matchlens)
        dict_type = NTuple{matchlens[1],Member}
    else
        dict_type = Tuple{Member,Vararg{Member}}
    end
    match_dict = Dict{dict_type,Vector{Function}}

    for add_gen in filter(matches_place, generators)
        match_key = placekey_mask_index(add_gen.matchstr)
        rule_set = get(match_dict, match_key, Vector{Function}())
        push!(rule_set, add_gen.generator)
    end
    GeneratorSearch{dict_type}(from_event, match_dict)
end

# Macros to make the match string.
"""
    @reactto changed(array[index].field) begin physical
        # generator body
    end

    @reactto fired(EventType(args...)) begin physical
        # generator body
    end

Creates an EventGenerator that reacts to state changes or event firings.
Used within @conditionsfor blocks.
"""
macro reactto(trigger_expr, block)
    if trigger_expr.head == :call
        if trigger_expr.args[1] == :changed
            return parse_changed_reactto(trigger_expr.args[2], block)
        elseif trigger_expr.args[1] == :fired
            return parse_fired_reactto(trigger_expr.args[2], block)
        else
            error("@reactto expects changed(...) or fired(...)")
        end
    else
        error("Invalid @reactto syntax")
    end
end

function access_to_searchkey(expr::Expr)
    parts = []
    current = expr

    while current isa Expr
        if current.head == :.
            field = current.args[2]
            field_val = field isa QuoteNode ? field.value : field
            push!(parts, Member(field_val))
            current = current.args[1]
        elseif current.head == :ref
            push!(parts, MEMBERINDEX)
            current = current.args[1]
        else
            break
        end
    end

    if current isa Symbol
        push!(parts, Member(current))
    end

    reverse!(parts)
    return parts
end

function access_to_argnames(expr::Expr)
    parts = []
    current = expr

    while current isa Expr
        if current.head == :.
            # Skip field access - no argument name here
            current = current.args[1]
        elseif current.head == :ref
            # Check if this is multi-dimensional indexing
            if length(current.args) > 2
                # Multi-dimensional: arr[i, j] -> push tuple (i, j)
                indices = current.args[2:end]
                push!(parts, Expr(:tuple, indices...))
            else
                # Single index: arr[i] -> push i
                push!(parts, current.args[2])
            end
            current = current.args[1]
        else
            break
        end
    end

    reverse!(parts)
    return parts
end

function parse_changed_reactto(place_expr, block)
    matchstr_parts = access_to_searchkey(place_expr)
    argnames = access_to_argnames(place_expr)

    # Extract the block parameter and body
    # The block should be: begin physical; <body>; end
    if block.head == :block && length(block.args) >= 2
        # Find the first non-LineNumberNode argument
        param_idx = findfirst(arg -> !(arg isa LineNumberNode), block.args)
        if param_idx === nothing
            error("Invalid block structure for @reactto")
        end
        block_param = block.args[param_idx]

        # The rest is the body
        body_args = block.args[(param_idx + 1):end]
        body = Expr(:block, body_args...)
    else
        error("Invalid block structure for @reactto")
    end

    # Transform generate(event) calls to f(event)
    transformed_body = transform_generate_calls(body)

    # Create the generator function
    return :(EventGenerator(
        ToPlace, $matchstr_parts, function (f::Function, $(esc(block_param)), $(esc.(argnames)...))
            $transformed_body
        end
    ))
end

function parse_fired_reactto(event_expr, block)
    # Parse something like InfectTransition(sick, healthy)
    if event_expr.head == :call
        event_type = event_expr.args[1]
        event_args = event_expr.args[2:end]

        # Extract the block parameter and body
        # The block should be: begin physical; <body>; end
        if block.head == :block && length(block.args) >= 2
            # Find the first non-LineNumberNode argument
            param_idx = findfirst(arg -> !(arg isa LineNumberNode), block.args)
            if param_idx === nothing
                error("Invalid block structure for @reactto")
            end
            block_param = block.args[param_idx]

            # The rest is the body
            body_args = block.args[(param_idx + 1):end]
            body = Expr(:block, body_args...)
        else
            error("Invalid block structure for @reactto")
        end

        # Transform generate(event) calls to f(event)
        transformed_body = transform_generate_calls(body)

        # Create the generator function
        return esc(
            quote
                EventGenerator(
                    ToEvent,
                    [$(QuoteNode(event_type))],
                    function (f::Function, $block_param, $(event_args...))
                        $transformed_body
                    end,
                )
            end,
        )
    else
        error("Expected EventType(...) syntax")
    end
end

function transform_generate_calls(expr)
    if expr isa Expr
        if expr.head == :call && expr.args[1] == :generate
            # Transform generate(event) to f(event)
            # Escape the event arguments but not f
            escaped_args = [esc(arg) for arg in expr.args[2:end]]
            return Expr(:call, :f, escaped_args...)
        else
            # Recursively transform subexpressions
            return Expr(expr.head, map(transform_generate_calls, expr.args)...)
        end
    else
        # Escape non-expression values (symbols, etc)
        return esc(expr)
    end
end

"""
    @conditionsfor EventType begin
        @reactto ... end
        @reactto ... end
    end

Generates a generators(::Type{EventType}) function containing all the
EventGenerators defined in the @reactto blocks.
"""
macro conditionsfor(event_type, block)
    # Collect all @reactto expressions
    generators_list = Expr[]

    for expr in block.args
        if expr isa Expr && expr.head == :macrocall && expr.args[1] == Symbol("@reactto")
            # Evaluate the @reactto macro
            push!(generators_list, macroexpand(__module__, expr))
        elseif expr isa LineNumberNode
            # Skip line numbers
            continue
        else
            # Skip other expressions for now
            continue
        end
    end

    # Generate the generators function
    return esc(quote
        generators(::Type{$event_type}) = EventGenerator[$(generators_list...)]
    end)
end
