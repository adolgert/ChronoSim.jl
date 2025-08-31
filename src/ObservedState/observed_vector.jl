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

function Base.getproperty(tv::ObservedArray, name::Symbol)
    name ∈ (:arr, :field_name, :owner) ? getfield(tv, name) : getproperty(tv.arr, name)
end

# Forward read-only operations
for op in [:axes, :eltype, :haskey, :isempty, :iterate, :keys, :length, :pairs, :size, :values]
    @eval Base.$op(tv::ObservedArray, args...; kwargs...) = $op(tv.arr, args...; kwargs...)
end

Base.IndexStyle(v::ObservedArray) = Base.IndexStyle(v.arr)

function Base.getindex(v::ObservedArray{T,1}, i::Int) where {T}
    element = v.arr[i]
    setfield!(element, :_container, v)
    setfield!(element, :_index, i)
    return element
end

function Base.getindex(v::ObservedArray{T,N}, i::Int) where {T,N}
    element = v.arr[i]
    setfield!(element, :_container, v)
    setfield!(element, :_index, Tuple(CartesianIndices(v.arr)[i]))
    return element
end

function Base.getindex(v::ObservedArray, i::Vararg{Int})
    element = v.arr[i...]
    setfield!(element, :_container, v)
    setfield!(element, :_index, i)
    return element
end

function Base.setindex!(v::ObservedArray{T,1}, x, i::Int) where {T}
    v.arr[i] = x
    setfield!(x, :_container, v)
    setfield!(x, :_index, i)
    return x
end

function Base.setindex!(v::ObservedArray{T,N}, x, i::Int) where {T,N}
    v.arr[i] = x
    setfield!(x, :_container, v)
    setfield!(x, :_index, Tuple(CartesianIndices(v.arr)[i]))
    return x
end

function Base.setindex!(v::ObservedArray, x, i::Vararg{Int})
    v.arr[i...] = x
    setfield!(x, :_container, v)
    setfield!(x, :_index, i)
    return x
end

function Base.push!(v::ObservedVector, x)
    push!(v.arr, x)
    new_index = length(v.arr)
    setfield!(x, :_container, v)
    setfield!(x, :_index, new_index)
    return v
end

function Base.pop!(v::ObservedVector)
    if isempty(v.arr)
        throw(BoundsError(v, ()))
    end
    x = pop!(v.arr)
    setfield!(x, :_container, nothing)
    return x
end

function Base.pushfirst!(v::ObservedVector, x)
    pushfirst!(v.arr, x)
    # Update indices for all elements
    for i in eachindex(v.arr)
        element = v.arr[i]
        setfield!(element, :_container, v)
        setfield!(element, :_index, i)
    end
    return v
end

function Base.popfirst!(v::ObservedVector)
    if isempty(v.arr)
        throw(BoundsError(v, ()))
    end
    x = popfirst!(v.arr)
    setfield!(x, :_container, nothing)
    # Update indices for remaining elements
    for i in eachindex(v.arr)
        element = v.arr[i]
        setfield!(element, :_index, i)
    end
    return x
end

function Base.append!(v::ObservedVector, items)
    start_idx = length(v.arr) + 1
    append!(v.arr, items)
    # Update container and index for newly added items
    for (offset, item) in enumerate(items)
        setfield!(item, :_container, v)
        setfield!(item, :_index, start_idx + offset - 1)
    end
    return v
end

function Base.resize!(v::ObservedVector, n::Integer)
    old_length = length(v.arr)
    resize!(v.arr, n)
    # If we expanded, new elements need their fields set when accessed
    # If we shrank, removed elements should have their container cleared
    if n < old_length
        # Elements that were removed are no longer accessible through the array
        # but their container field should ideally be cleared - however we can't
        # access them anymore, so this is a limitation
    end
    return v
end

function observed_notify(v::ObservedArray, changed, readwrite)
    if isdefined(v, :owner)
        observed_notify(
            getfield(v, :owner), (Member(getfield(v, :field_name)), changed...), readwrite
        )
    end
end
