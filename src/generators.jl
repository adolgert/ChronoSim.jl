using Logging: Logging

##### Helpers for events

export EventGenerator, generators, GeneratorSearch, GenMatches, ToEvent, ToPlace
export over_generated_events, @reactto, @conditionsfor
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

# Helper methods for testing and inspection
function count_event_generators(gs::GeneratorSearch, event_type::Symbol)
    length(get(gs.event_to_event, event_type, Function[]))
end

function count_place_generators(gs::GeneratorSearch, place_pattern)
    masked_pattern = placekey_mask_index(place_pattern)
    length(get(gs.byarray, masked_pattern, Function[]))
end

has_event_generator(gs::GeneratorSearch, event_type::Symbol) = haskey(gs.event_to_event, event_type)

function has_place_generator(gs::GeneratorSearch, place_pattern)
    masked_pattern = placekey_mask_index(place_pattern)
    haskey(gs.byarray, masked_pattern)
end

event_types(gs::GeneratorSearch) = collect(keys(gs.event_to_event))

place_patterns(gs::GeneratorSearch) = collect(keys(gs.byarray))

function over_generated_events(
    f::Function, generators::GeneratorSearch, physical, event_key, changed_places
)
    if !isempty(event_key)
        event_args = event_key[2:end]
        for from_event in get(generators.event_to_event, event_key[1], Function[])
            from_event(f, physical, event_args...)
        end
    end
    # Every place is (arrayname, integer index in array, struct member)
    for place in changed_places
        placekey = placekey_mask_index(place)
        inds = [val for val in place if !isa(val, Member)]
        for genfunc in get(generators.byarray, placekey, Function[])
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

    place_generators = filter(matches_place, generators)
    if isempty(place_generators)
        # No place generators, use a simple type
        dict_type = Tuple{Vararg{Member}}
        match_dict = Dict{dict_type,Vector{Function}}()
    else
        matchlens = [length(gen.matchstr) for gen in place_generators]
        if allequal(matchlens)
            dict_type = NTuple{matchlens[1],Member}
        else
            dict_type = Tuple{Vararg{Member}}
        end
        match_dict = Dict{dict_type,Vector{Function}}()
    end

    for add_gen in place_generators
        match_key = placekey_mask_index(add_gen.matchstr)
        rule_set = get!(match_dict, match_key, Vector{Function}())
        push!(rule_set, add_gen.generator)
    end
    GeneratorSearch{typeof(match_dict)}(from_event, match_dict)
end

"""
    access_to_searchkey(expr::Expr)

Convert a Julia access expression into a search key pattern for the event generator system.
Field names become `Member` objects, and array/container indices become `MEMBERINDEX` placeholders.

# Examples

```julia
# Simple member access
julia> access_to_searchkey(:(obj.field))
[Member(:obj), Member(:field)]

# Array access with index
julia> access_to_searchkey(:(arr[5].field))  
[Member(:arr), MEMBERINDEX, Member(:field)]

# Multi-dimensional array access
julia> access_to_searchkey(:(board[i][j].piece))
[Member(:board), MEMBERINDEX, MEMBERINDEX, Member(:piece)]
```

The resulting pattern is used to match against place keys in the simulation's state change tracking.
"""
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

"""
    @reactto changed(array[index].field) do physical
        # generator body
    end

    @reactto fired(EventType(args...)) do physical
        # generator body
    end

Creates an EventGenerator that reacts to state changes or event firings.
Used within @conditionsfor blocks.
"""
macro reactto(expr)
    # When using do-block syntax, Julia passes the entire expression as one argument
    if expr isa Expr && expr.head == :do && length(expr.args) == 2
        # Extract the do-block components
        func_expr = expr.args[1]
        param_and_body = expr.args[2]

        # Check if this is the expected structure
        if param_and_body isa Expr && param_and_body.head == :-> && length(param_and_body.args) == 2
            block_param = param_and_body.args[1]
            # Handle single parameter do-blocks where param is wrapped in a tuple
            if block_param isa Expr && block_param.head == :tuple && length(block_param.args) == 1
                block_param = block_param.args[1]
            end
            body = param_and_body.args[2]
        else
            error("Invalid do-block structure for @reactto")
        end

        # Now handle the trigger expression (func_expr)
        if func_expr.head == :call
            if func_expr.args[1] == :changed
                return parse_changed_reactto_doblock(func_expr.args[2], block_param, body)
            elseif func_expr.args[1] == :fired
                return parse_fired_reactto_doblock(func_expr.args[2], block_param, body)
            else
                error("@reactto expects changed(...) or fired(...)")
            end
        else
            error("Invalid @reactto syntax")
        end
    else
        error(
            "@reactto expects do-block syntax: @reactto (fired|changed)(accessor) do param ... end"
        )
    end
end

# Keep the old two-argument version for backward compatibility if needed
macro reactto(trigger_expr, block)
    # Check if this is do-block syntax passed as two arguments (shouldn't happen but just in case)
    if block isa Expr && block.head == :do && length(block.args) == 2
        # Extract parameter and body from do block
        param_and_body = block.args[1]
        func_expr = block.args[2]

        # The parameter is in param_and_body.args
        if param_and_body isa Expr && param_and_body.head == :-> && length(param_and_body.args) == 2
            block_param = param_and_body.args[1]
            # Handle single parameter do-blocks where param is wrapped in a tuple
            if block_param isa Expr && block_param.head == :tuple && length(block_param.args) == 1
                block_param = block_param.args[1]
            end
            body = param_and_body.args[2]
        else
            error("Invalid do-block structure for @reactto")
        end

        # Now handle the trigger expression (func_expr)
        if func_expr.head == :call
            if func_expr.args[1] == :changed
                return parse_changed_reactto_doblock(func_expr.args[2], block_param, body)
            elseif func_expr.args[1] == :fired
                return parse_fired_reactto_doblock(func_expr.args[2], block_param, body)
            else
                error("@reactto expects changed(...) or fired(...)")
            end
        else
            error("Invalid @reactto syntax")
        end
    else
        error("@reactto (fired|changed)(accessor) do block")
    end
end

function transform_generate_calls(expr)
    if expr isa Expr
        if expr.head == :call && expr.args[1] == :generate
            # Keep generate unescaped but escape its arguments
            escaped_args = [esc(arg) for arg in expr.args[2:end]]
            return Expr(:call, :generate, escaped_args...)
        elseif expr.head == :macrocall
            # Don't transform macrocalls like @debug - they need to work as-is
            return expr
        else
            # Recursively transform subexpressions
            return Expr(expr.head, map(transform_generate_calls, expr.args)...)
        end
    else
        # Escape non-expression values (symbols, etc)
        return esc(expr)
    end
end

function parse_changed_reactto_doblock(place_expr, block_param, body)
    matchstr_parts = access_to_searchkey(place_expr)
    argnames = access_to_argnames(place_expr)

    # Transform generate(event) calls to use the local generate parameter
    transformed_body = transform_generate_calls(body)

    return :(EventGenerator(
        ToPlace,
        $matchstr_parts,
        function (generate::Function, $(esc(block_param)), $(esc.(argnames)...))
            $transformed_body
        end,
    ))
end

function parse_fired_reactto_doblock(event_expr, block_param, body)
    # Parse something like InfectTransition(sick, healthy)
    if event_expr.head == :call
        event_type = event_expr.args[1]
        event_args = event_expr.args[2:end]

        # Transform generate(event) calls to use the local generate parameter
        transformed_body = transform_generate_calls(body)

        return quote
            EventGenerator(
                ToEvent,
                [$(QuoteNode(event_type))],
                function (generate::Function, $(esc(block_param)), $(esc.(event_args)...))
                    $transformed_body
                end,
            )
        end
    else
        error("Expected EventType(...) syntax")
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
