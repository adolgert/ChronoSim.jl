"""
    access_to_placekey(expr)

This function takes an expression for member access to a hierarchical container
and converts it into a place key. For instance:

| Accessor expression           | Place key                 |
| ----------------------------- | ------------------------- |
| `state.agent[j].armor`        | `(:agent, j, :armor)`     |
| `sim.board[i, j].fval`        | `(:board, (i, j), :fval)` |
| `state.param`                 | `(:param,)`               |
| `sim.adict[(name, kind)]`     | `(:adict, (name, kind))`  |
| `physical.land[square].grass` | `(:land, square, :grass)` |

The output is also an `Expr`-type object.
"""
function access_to_placekey(expr::Expr)
    parts = []
    current = expr

    while current isa Expr
        if current.head == :.
            push!(parts, :(Member($(current.args[2]))))
            current = current.args[1]
        elseif current.head == :ref
            if length(current.args) == 2
                push!(parts, current.args[2])
            else
                push!(parts, Expr(:tuple, current.args[2:end]...))
            end
            current = current.args[1]
        else
            break
        end
    end

    if current isa Symbol
        push!(parts, current)
    end

    reverse!(parts)

    if length(parts) > 1
        parts = parts[2:end]
    end

    return Expr(:tuple, parts...)
end


function _observe_macro(expr, readwrite_field)
    if isa(expr, Expr) && expr.head == :(=)
        # Handle assignment (write)
        expr = expr.args[1]
    end
    placekey_expr = access_to_placekey(expr)

    # Extract the physical state object
    current = expr
    while current isa Expr && (current.head == :. || current.head == :ref)
        if current.head == :.
            current = current.args[1]
        elseif current.head == :ref
            current = current.args[1]
        end
    end
    physical_obj = current

    return quote
        local _physical = $(esc(physical_obj))
        local _placekey = $(esc(placekey_expr))
        push!(getfield(_physical, $(QuoteNode(readwrite_field))), _placekey)
        $(esc(expr))
    end
end


"""
    @obsread expr

Track reads and writes to ObservedPhysical state. Records the access
in physical state and returns the value.
"""
macro obsread(expr)
    _observe_macro(expr, :obs_read)
end


"""
    @obswrite expr

Track writes to ObservedPhysical state. Records the access in physical state
and performs the assignment.
"""
macro obswrite(expr)
    _observe_macro(expr, :obs_modified)
end
