using Base: Base

mutable struct ObservedArray{T,N} <: DenseArray{T,N}
    const arr::Array{T,N}
    array_name::Symbol
    owner::Any
    ObservedArray{T,N}(arr) where {T,N} = new{T,N}(arr)
end

function ObservedArray{T}(::UndefInitializer, dims...) where {T}
    N = length(dims)
    arr = Array{T}(undef, dims...)
    ObservedArray{T,N}(arr)
end

Base.eltype(v::ObservedArray{T}) where {T} = T
Base.ndims(v::ObservedArray) = ndims(v.arr)
Base.size(v::ObservedArray) = size(v.arr)
Base.size(v::ObservedArray, n) = size(v.arr, n)
Base.length(v::ObservedArray) = length(v.arr)
Base.eachindex(v::ObservedArray) = eachindex(v.arr)
Base.iterate(v::ObservedArray) = iterate(v.arr)
Base.axes(v::ObservedArray) = axes(v.arr)

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

Base.IndexStyle(v::ObservedArray) = Base.IndexStyle(v.arr)

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
