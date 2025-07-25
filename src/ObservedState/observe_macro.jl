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

"""
    @observe expr

Track reads and writes to ObservedPhysical state. For reads, records the access
in obs_read and returns the value. For writes, records the access in obs_modified
and performs the assignment.
"""
macro observe(expr)
    if isa(expr, Expr) && expr.head == :(=)
        # Handle assignment (write)
        lhs = expr.args[1]
        rhs = expr.args[2]

        # Get the placekey from the left-hand side
        placekey_expr = access_to_placekey(lhs)

        # Extract the physical state object (first part of the access chain)
        current = lhs
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
            local _placekey = $placekey_expr
            push!(_physical.obs_modified, _placekey)
            $(esc(lhs)) = $(esc(rhs))
        end
    else
        # Handle read
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
            local _placekey = $placekey_expr
            push!(_physical.obs_read, _placekey)
            $(esc(expr))
        end
    end
end
