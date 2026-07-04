struct AddressPath
    path::Vector{Any}
    type::Type
    example::String
end


function _nth_field(::Type{T}, n::Int)
    names = fieldnames(T)
    types = fieldtypes(T)
    n > length(names) && return nothing
    return ("." * names[n], types[n])
end

function _nth_field(::Type{T}, n::Int) where {T<:ObservedArray}
    n > 1 && return nothing
    var_str = join(["i" * string(j) for j in ndims(T)])
    ("[" * var_str * "]", eltype(T))
end

function _nth_field(::Type{T}, n::Int) where {T<:ObservedDict}
    n > 1 && return nothing
    ("[key]", valtype(T))
end

function _physical_at_index(::Type{T}, index::Vector{Int}) where {T}
    names = String[]
    types = DataType[]
    type_idx = T
    for idx in index
        result = _nth_field(type_idx, idx)
        isnothing(result) && return nothing
        nm, nt = result
        push!(names, nm)
        push!(types, nt)
        type_idx = nt
    end
    return (names, types)
end


_addressof(names, types) = AddressPath(names, types[end], join(names, ""))


function physical_addresses(::Type{T}) where {T<:ObservedPhysical}
    addresses = AddressPath[]
    # The index is a sequence of ordinals into the fieldnames of each type.
    # The first index is the ordinal of a field in the base physical state.
    index = Int[1]
    while index[1] <= length(fieldnames(T))
        value = _physical_at_index(T, index)
        if !isnothing(value)
            names, types = value
            last_type = types[end]
            classed = structure_trait(last_type)
            if classed == CompoundTrait()
                if last_type isa ObservedSet
                    push!(addresses, _addressof(names, types))
                else
                    push!(index, 1)
                end
            elseif classed == UnObservableTrait()
                index[end] += 1
            elseif classed == PrimitiveTrait()
                push!(addresses, _addressof(names, types))
                index[end] += 1
            else
                error("Type {types[end]} of name {names[end]} is {classed}")
            end
        else
            pop!(index)
            index[end] += 1
        end
    end
    return addresses
end
