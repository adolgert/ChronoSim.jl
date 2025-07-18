function access_to_placekey(expr::Expr)
    parts = []
    current = expr

    while current isa Expr
        if current.head == :.
            push!(parts, current.args[2])
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
