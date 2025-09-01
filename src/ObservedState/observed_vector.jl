using Base: Base
export ObservedArray, ObservedVector, ObservedMatrix

mutable struct ObservedArray{T,N} <: DenseArray{T,N}
    const arr::Array{T,N}
    field_name::Symbol
    owner::Any
    ObservedArray{T,N}(arr) where {T,N} = new{T,N}(collect(arr))
end

const ObservedVector{T} = ObservedArray{T,1}
const ObservedMatrix{T} = ObservedArray{T,2}

function ObservedArray{T}(::UndefInitializer, dims...) where {T}
    N = length(dims)
    arr = Array{T}(undef, dims...)
    ObservedArray{T,N}(arr)
end

ObservedVector{T}(::UndefInitializer, dim) where {T} = ObservedArray{T,1}(Array{T}(undef, dim))
function ObservedMatrix{T}(::UndefInitializer, dim1, dim2) where {T}
    ObservedArray{T,2}(Array{T}(undef, dim1, dim2))
end

is_observed_container(v::ObservedArray) = true
is_observed_container(::Type{ObservedArray}) = true

function Base.getproperty(tv::ObservedArray, name::Symbol)
    name ∈ (:arr, :field_name, :owner) ? getfield(tv, name) : getproperty(tv.arr, name)
end

# Forward read-only operations
for op in [:axes, :eltype, :haskey, :isempty, :iterate, :keys, :length, :pairs, :size, :values]
    @eval Base.$op(tv::ObservedArray, args...; kwargs...) = $op(tv.arr, args...; kwargs...)
end

Base.IndexStyle(v::ObservedArray) = Base.IndexStyle(v.arr)

# Use a trait type to treat primitive element types as leaf nodes but treat
# compound element types as branch nodes.
Base.getindex(v::ObservedArray, i...) = _getindex(structure_trait(eltype(v)), v, i...)

_update_index(el, v, i) = (setfield!(el, :_container, v); setfield!(el, :_index, i); el)

function _getindex(::PrimitiveTrait, v::ObservedArray{T,1}, i::Int) where {T}
    observed_notify(v, i, :read)
    return v.arr[i]
end

function _getindex(::CompoundTrait, v::ObservedArray{T,1}, i::Int) where {T}
    element = v.arr[i]
    return _update_index(element, v, i)
end

function _getindex(::PrimitiveTrait, v::ObservedArray{T,N}, i::Int) where {T,N}
    observed_notify(v, Tuple(CartesianIndices(v.arr)[i]), :read)
    return v.arr[i]
end

function _getindex(::CompoundTrait, v::ObservedArray{T,N}, i::Int) where {T,N}
    element = v.arr[i]
    return _update_index(element, v, Tuple(CartesianIndices(v.arr)[i]))
end

function _getindex(::PrimitiveTrait, v::ObservedArray, i::Vararg{Int})
    observed_notify(v, i, :read)
    return v.arr[i...]
end

function _getindex(::CompoundTrait, v::ObservedArray, i::Vararg{Int})
    element = v.arr[i...]
    return _update_index(element, v, i)
end

function _getindex(::PrimitiveTrait, v::ObservedArray, i::CartesianIndex)
    observed_notify(v, Tuple(i), :read)
    return v.arr[i]
end

function _getindex(::CompoundTrait, v::ObservedArray, i::CartesianIndex)
    element = v.arr[i]
    return _update_index(element, v, Tuple(i))
end

Base.setindex!(v::ObservedArray, x, i...) = _setindex!(structure_trait(eltype(v)), v, x, i...)

function _setindex!(::PrimitiveTrait, v::ObservedArray{T,1}, x, i::Int) where {T}
    observed_notify(v, i, :write)
    return v.arr[i] = x
end

function _setindex!(::CompoundTrait, v::ObservedArray{T,1}, x, i::Int) where {T}
    v.arr[i] = x
    return _update_index(x, v, i)
end

function _setindex!(::PrimitiveTrait, v::ObservedArray{T,N}, x, i::Int) where {T,N}
    observed_notify(v, Tuple(CartesianIndices(v.arr)[i]), :write)
    return v.arr[i] = x
end

function _setindex!(::CompoundTrait, v::ObservedArray{T,N}, x, i::Int) where {T,N}
    v.arr[i] = x
    return _update_index(x, v, Tuple(CartesianIndices(v.arr)[i]))
end

function _setindex!(::PrimitiveTrait, v::ObservedArray, x, i::Vararg{Int})
    observed_notify(v, i, :write)
    return v.arr[i...] = x
end

function _setindex!(::CompoundTrait, v::ObservedArray, x, i::Vararg{Int})
    v.arr[i...] = x
    return _update_index(x, v, i)
end

function _setindex!(::PrimitiveTrait, v::ObservedArray, x, i::CartesianIndex)
    v.arr[i] = x
    return observed_notify(v, Tuple(i), :write)
end

function _setindex!(::CompoundTrait, v::ObservedArray, x, i::CartesianIndex)
    v.arr[i] = x
    return _update_index(x, v, Tuple(i))
end

Base.push!(v::ObservedVector, x) = _push!(structure_trait(eltype(v)), v, x)

function _push!(::PrimitiveTrait, v::ObservedVector, x)
    observed_notify(v, length(v.arr) + 1, :write)
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
    observed_notify(v, length(v), :write)
    x = pop!(v.arr)
    return x
end

function _pop!(::CompoundTrait, v::ObservedVector)
    if isempty(v.arr)
        throw(BoundsError(v, ()))
    end
    x = pop!(v.arr)
    notify_all(x)
    setfield!(x, :_container, nothing)
    return x
end

Base.pushfirst!(v::ObservedVector, x) = _pushfirst!(structure_trait(eltype(v)), v, x)

function _pushfirst!(::PrimitiveTrait, v::ObservedVector, x)
    pushfirst!(v.arr, x)
    for i in eachindex(v.arr)
        observed_notify(v, i, :write)
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
        observed_notify(v, i, :write)
    end
    return x
end

function _popfirst!(::CompoundTrait, v::ObservedVector)
    if isempty(v.arr)
        throw(BoundsError(v, ()))
    end
    x = popfirst!(v.arr)
    setfield!(x, :_container, nothing)
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
        observed_notify(v, idx, :write)
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
            observed_notify(v, rem_idx, :write)
        end
    else
        for add_idx in (old_length + 1):n
            observed_notify(v, add_idx, :write)
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
            setfield!(v.arr[rem_idx], :_container, nothing)
        end
        # else New entries will be undef after resize. Don't initialize.
    end
    resize!(v.arr, n)
    return v
end

function observed_notify(v::ObservedArray, changed, readwrite)
    if isdefined(v, :owner)
        observed_notify(
            getfield(v, :owner), (Member(getfield(v, :field_name)), changed...), readwrite
        )
    end
end
