using Base: Base
export ObservedArray, ObservedVector, ObservedMatrix

mutable struct ObservedArray{T,N,Index} <: DenseArray{T,N}
    const arr::Array{T,N}
    _address::Address{Index}
    ObservedArray{T,N,Index}(arr) where {T,N,Index} = new{T,N,Index}(collect(arr), Address{Index}())
end

const ObservedVector{T,Index} = ObservedArray{T,1,Index}
const ObservedMatrix{T,Index} = ObservedArray{T,2,Index}

function ObservedArray{T,Index}(::UndefInitializer, dims...) where {T,Index}
    N = length(dims)
    arr = Array{T}(undef, dims...)
    ObservedArray{T,N,Index}(arr)
end

function ObservedVector{T,Index}(::UndefInitializer, dim) where {T,Index}
    ObservedArray{T,1,Index}(Array{T}(undef, dim))
end

ObservedVector{T,Index}() where {T,Index} = ObservedArray{T,1,Index}(Array{T}(undef, 0))

function ObservedMatrix{T,Index}(::UndefInitializer, dim1, dim2) where {T,Index}
    ObservedArray{T,2,Index}(Array{T}(undef, dim1, dim2))
end

ObservedMatrix{T,Index}() where {T,Index} = ObservedArray{T,2,Index}(Array{T}(undef, 0, 0))

is_observed_container(v::ObservedArray) = true
is_observed_container(::Type{<:ObservedArray}) = true

function Base.getproperty(tv::ObservedArray, name::Symbol)
    name ∈ (:arr, :_address) ? getfield(tv, name) : getproperty(tv.arr, name)
end

# Forward read-only operations
for op in [:axes, :eltype, :isempty, :iterate, :length, :size]
    @eval Base.$op(tv::ObservedArray, args...; kwargs...) = $op(tv.arr, args...; kwargs...)
end

Base.IndexStyle(v::ObservedArray) = Base.IndexStyle(v.arr)

# Use a trait type to treat primitive element types as leaf nodes but treat
# compound element types as branch nodes.
Base.getindex(v::ObservedArray, i...) = _getindex(structure_trait(eltype(v)), v, i...)

_update_index(el, v, i) = (update_index(el._address, v, i); el)

function _getindex(::PrimitiveTrait, v::ObservedArray{T,1}, i::Int) where {T}
    observed_notify(v, (i,), :read)
    return v.arr[i]
end

function _getindex(::CompoundTrait, v::ObservedArray{T,1}, i::Int) where {T}
    element = v.arr[i]
    return _update_index(element, v, i)
end

function _getindex(::PrimitiveTrait, v::ObservedArray{T,1}, r::AbstractRange) where {T}
    for idx in r
        observed_notify(v, (idx,), :read)
    end
    return v.arr[r]
end

function _getindex(::CompoundTrait, v::ObservedArray{T,1}, r::AbstractRange) where {T}
    element = v.arr[i]
    return _update_index(element, v, i)
end

function _getindex(::PrimitiveTrait, v::ObservedArray{T,N}, i::Int) where {T,N}
    observed_notify(v, (Tuple(CartesianIndices(v.arr)[i]),), :read)
    return v.arr[i]
end

function _getindex(::CompoundTrait, v::ObservedArray{T,N}, i::Int) where {T,N}
    element = v.arr[i]
    return _update_index(element, v, Tuple(CartesianIndices(v.arr)[i]))
end

function _getindex(::PrimitiveTrait, v::ObservedArray, i::Vararg{Int})
    observed_notify(v, (i,), :read)
    return v.arr[i...]
end

function _getindex(::CompoundTrait, v::ObservedArray, i::Vararg{Int})
    element = v.arr[i...]
    return _update_index(element, v, i)
end

function _getindex(::PrimitiveTrait, v::ObservedArray, i::CartesianIndex)
    observed_notify(v, (Tuple(i),), :read)
    return v.arr[i]
end

function _getindex(::CompoundTrait, v::ObservedArray, i::CartesianIndex)
    element = v.arr[i]
    return _update_index(element, v, Tuple(i))
end

Base.setindex!(v::ObservedArray, x, i...) = _setindex!(structure_trait(eltype(v)), v, x, i...)

function _setindex!(::PrimitiveTrait, v::ObservedArray{T,1}, x, i::Int) where {T}
    observed_notify(v, (i,), :write)
    return v.arr[i] = x
end

function _setindex!(::CompoundTrait, v::ObservedArray{T,1}, x, i::Int) where {T}
    v.arr[i] = x
    return _update_index(x, v, i)
end

function _setindex!(::PrimitiveTrait, v::ObservedArray{T,N}, x, i::Int) where {T,N}
    observed_notify(v, (Tuple(CartesianIndices(v.arr)[i]),), :write)
    return v.arr[i] = x
end

function _setindex!(::CompoundTrait, v::ObservedArray{T,N}, x, i::Int) where {T,N}
    v.arr[i] = x
    return _update_index(x, v, Tuple(CartesianIndices(v.arr)[i]))
end

function _setindex!(::PrimitiveTrait, v::ObservedArray, x, i::Vararg{Int})
    observed_notify(v, (i,), :write)
    return v.arr[i...] = x
end

function _setindex!(::CompoundTrait, v::ObservedArray, x, i::Vararg{Int})
    v.arr[i...] = x
    return _update_index(x, v, i)
end

function _setindex!(::PrimitiveTrait, v::ObservedArray, x, i::CartesianIndex)
    v.arr[i] = x
    return observed_notify(v, (Tuple(i),), :write)
end

function _setindex!(::CompoundTrait, v::ObservedArray, x, i::CartesianIndex)
    v.arr[i] = x
    return _update_index(x, v, Tuple(i))
end

Base.push!(v::ObservedVector, x) = _push!(structure_trait(eltype(v)), v, x)

function _push!(::PrimitiveTrait, v::ObservedVector, x)
    observed_notify(v, (length(v.arr) + 1,), :write)
    return push!(v.arr, x)
end

function _push!(::CompoundTrait, v::ObservedVector, x)
    push!(v.arr, x)
    _update_index(x, v, length(v.arr))
    notify_all(x)
    return x
end

Base.pop!(v::ObservedVector) = _pop!(structure_trait(eltype(v)), v)

function _pop!(::PrimitiveTrait, v::ObservedVector)
    if isempty(v.arr)
        throw(BoundsError(v, ()))
    end
    observed_notify(v, (length(v),), :write)
    x = pop!(v.arr)
    return x
end

function _pop!(::CompoundTrait, v::ObservedVector)
    if isempty(v.arr)
        throw(BoundsError(v, ()))
    end
    x = pop!(v.arr)
    notify_all(x)
    empty!(x._address)
    return x
end

Base.pushfirst!(v::ObservedVector, x) = _pushfirst!(structure_trait(eltype(v)), v, x)

function _pushfirst!(::PrimitiveTrait, v::ObservedVector, x)
    pushfirst!(v.arr, x)
    for i in eachindex(v.arr)
        observed_notify(v, (i,), :write)
    end
    return v
end

function _pushfirst!(::CompoundTrait, v::ObservedVector, x)
    pushfirst!(v.arr, x)
    # Update indices for all elements
    for i in eachindex(v.arr)
        element = v.arr[i]
        _update_index(element, v, i)
        notify_all(element)
    end
    return v
end

Base.popfirst!(v::ObservedVector) = _popfirst!(structure_trait(eltype(v)), v)

function _popfirst!(::PrimitiveTrait, v::ObservedVector)
    if isempty(v.arr)
        throw(BoundsError(v, ()))
    end
    x = popfirst!(v.arr)
    for i in eachindex(v.arr)
        observed_notify(v, (i,), :write)
    end
    return x
end

function _popfirst!(::CompoundTrait, v::ObservedVector)
    if isempty(v.arr)
        throw(BoundsError(v, ()))
    end
    x = popfirst!(v.arr)
    empty!(x._address)
    # Update indices for remaining elements
    for i in eachindex(v.arr)
        element = v.arr[i]
        _update_index(element, v, i)
        notify_all(element)
    end
    return x
end

Base.append!(v::ObservedVector, items) = _append!(structure_trait(eltype(v)), v, items)

function _append!(::PrimitiveTrait, v::ObservedVector, items)
    start_idx = length(v.arr) + 1
    append!(v.arr, items)
    # Update container and index for newly added items
    for idx in start_idx:length(v.arr)
        observed_notify(v, (idx,), :write)
    end
    return v
end

function _append!(::CompoundTrait, v::ObservedVector, items)
    start_idx = length(v.arr) + 1
    append!(v.arr, items)
    # Update container and index for newly added items
    for (offset, item) in enumerate(items)
        _update_index(item, v, start_idx + offset - 1)
        notify_all(item)
    end
    return v
end

Base.resize!(v::ObservedVector, n::Integer) = _resize!(structure_trait(eltype(v)), v, n)

function _resize!(::PrimitiveTrait, v::ObservedVector, n::Integer)
    old_length = length(v.arr)
    if n < old_length
        for rem_idx in (n + 1):old_length
            observed_notify(v, (rem_idx,), :write)
        end
    else
        for add_idx in (old_length + 1):n
            observed_notify(v, (add_idx,), :write)
        end
    end
    resize!(v.arr, n)
    return v
end

function _resize!(::CompoundTrait, v::ObservedVector, n::Integer)
    old_length = length(v.arr)
    if n < old_length
        for rem_idx in (n + 1):old_length
            notify_all(v.arr[rem_idx])
            empty!(v.arr[rem_idx]._address)
        end
        # else New entries will be undef after resize. Don't initialize.
    end
    resize!(v.arr, n)
    return v
end

function observed_notify(v::ObservedArray, changed, readwrite)
    address_notify(v._address, changed, readwrite)
end
