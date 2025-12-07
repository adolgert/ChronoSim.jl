using Logging: Logging

##### Helpers for events

export EventGenerator, generators, GeneratorSearch, GenMatches, ToEvent, ToPlace
export @reactto, @conditionsfor

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
    EventGenerator(match_what, matchstr, generator::Function)

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
    byarray::DictType
end

Base.isempty(gs::GeneratorSearch) = isempty(gs.event_to_event) && isempty(gs.byarray)

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

"""
    over_generated_events(callback, generators, physical, event_keys, changed_places)

 * `callback` is a function in the main event loop of the framework that accepts
   an event as an argument.
 * `generators` is the struct containing all event generators.
 * `physical` is physical state.
 * `event_keys` is a vector or set of keys.
 * `changed_places` is a vector or set of physical addresses.
"""
function over_generated_events(
    f::Function, generators::GeneratorSearch, physical, event_key, changed_places
)
    if !isnothing(event_key) && !isempty(event_key)
        event_args = event_key[2:end]
        for from_event in get(generators.event_to_event, event_key[1], Function[])
            # `from_event` is written by the user and calls `f` with possibly-enabled events.
            from_event(f, physical, event_args...)
        end
    end
    # Every place is (arrayname, integer index in array, struct member)
    for place in changed_places
        placekey = placekey_mask_index(place)
        inds = [val for val in place if !isa(val, Member)]
        # `genfunc` is written by the user and calls `f` with possibly-enabled events.
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

# These functions support debugging macros below.
const DEBUG_MACROS = Ref(false)
enable_macro_debug(flag=true) = DEBUG_MACROS[] = flag
macro_debug(label, expr) = DEBUG_MACROS[] && println("[$label] ", expr)

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

"""
    access_to_argnames(expr)

It extracts variable arguments to an accessor expression. An accessor expression
uses `getfield` or `getindex` to find members of structs and containers.
Turns this: `:(agent[j].value[k])`, into this: `[:(j), :(k)]`.
"""
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
                # Single index: arr[i] -> push i.  This pushes a Symbol, not an Expr.
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
Instead of escaping the argument list as-is, we reach into arguments
that are tuples and escape them individually. The idea is to destructure
the arguments into escaped variables.
"""
function escaped_args(accessor_args)
    accessor_restated = Any[]
    for arg in accessor_args
        if isa(arg, Symbol)
            # Escape the symbol so it resolves in caller's scope
            modified = esc(arg)
        elseif isa(arg, Expr) && arg.head == :tuple
            # Escape each element of the tuple for destructuring: (i, j)
            arg_vec = [esc(a) for a in arg.args]
            modified = Expr(:tuple, arg_vec...)
        else
            error("unknown argument to build_argument_list: $arg")
        end
        push!(accessor_restated, modified)
    end
    return accessor_restated
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
    if DEBUG_MACROS[]
        println("=== @funcmaker input ===")
        dump(do_block; maxdepth=32)
    end
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


function parse_changed_reactto_doblock(place_expr, block_param, body)
    matchstr_parts = access_to_searchkey(place_expr)
    argnames = access_to_argnames(place_expr)
    esc_args = escaped_args(argnames)
    franken_func = :(EventGenerator(
        ToPlace,
        $matchstr_parts,
        function ($(esc(:generate))::Function, $(esc(block_param)), $(esc_args...))
            $(esc(body))
        end,
    ))
    if DEBUG_MACROS[]
        println("=== @funcmaker output ===")
        dump(franken_func; maxdepth=32)
    end
    return franken_func
end

function parse_fired_reactto_doblock(event_expr, block_param, body)
    # Parse something like InfectTransition(sick, healthy)
    if event_expr.head == :call
        event_type = event_expr.args[1]
        event_args = event_expr.args[2:end]

        franken_func = quote
            EventGenerator(
                ToEvent,
                [$(QuoteNode(event_type))],
                function ($(esc(:generate))::Function, $(esc(block_param)), $(esc.(event_args)...))
                    $(esc(body))
                end,
            )
        end
        if DEBUG_MACROS[]
            println("=== @funcmaker output ===")
            dump(franken_func; maxdepth=32)
        end
        return franken_func
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


function generators_from_events(events)
    no_generator_event = Any[]
    generator_searches = Dict{String,GeneratorSearch}()
    for (idx, filter_condition) in Dict("timed" => !isimmediate, "immediate" => isimmediate)
        event_set = filter(filter_condition, events)
        generator_set = EventGenerator[]
        for event in event_set
            gen_for_event = generators(event)
            if !isempty(gen_for_event)
                append!(generator_set, gen_for_event)
            else
                push!(no_generator_event, gen_for_event)
            end
        end
        generator_searches[idx] = GeneratorSearch(generator_set)
    end
    if isempty(generator_searches["timed"])
        imm_str = string(generator_searches["immediate"])
        error("There are no timed events and immediate events are $imm_str")
    end
    if length(no_generator_event) > 1
        error("""More than one event has no generators. Check function signatures
            because only one should be the initializer event. $(no_generator_event)
            """)
    elseif !isempty(no_generator_event)
        @debug "Possible initialization event $(no_generator_event[1])"
    end
    return generator_searches
end
