using Base: Base
export ObservedArray, ObservedVector, ObservedMatrix, FixedExtentError

"""
    FixedExtentError(op)

Signals that the length-changing operation `op` was attempted on an
`ObservedArray`/`ObservedVector`. These containers use the integer index as a
place identity, so growing or shrinking the extent would silently migrate
identity between addresses that the dependency network and generator templates
have already recorded. See docs/src/state_contract.md ("Fixed extent: position
is identity").
"""
struct FixedExtentError <: Exception
    op::Symbol
end

function Base.showerror(io::IO, e::FixedExtentError)
    print(
        io,
        "FixedExtentError: `",
        e.op,
        "` is not permitted on an ObservedArray. An integer index is a place ",
        "identity, so a length change would migrate identity between addresses ",
        "(see docs/src/state_contract.md). Allocate with the final size via ",
        "`ObservedArray{T,Index}(undef, dims...)` and fill by setindex!.",
    )
end

mutable struct ObservedArray{T,N,Index} <: DenseArray{T,N}
    const arr::Array{T,N}
    _address::Address{Index}
    # copy() does a raw buffer copy that leaves undefined references intact, so an
    # array allocated with `undef` and filled by the caller afterward is accepted.
    # collect() dereferences every slot and throws UndefRefError on such arrays
    # (element-wise since Julia 1.13); the generic method below keeps collect() for
    # non-Array iterables such as generators, whose elements are always defined.
    function ObservedArray{T,N,Index}(arr::Array{T,N}) where {T,N,Index}
        new{T,N,Index}(copy(arr), Address{Index}())
    end
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
    # Re-address each returned element to the slot it came from, mirroring the
    # scalar compound getindex: compound reads carry no per-element read
    # notification, only address maintenance.
    return [_update_index(v.arr[idx], v, idx) for idx in r]
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

# Fixed extent: every length-changing operation is rejected rather than
# implemented. An integer index is a place identity, and any extent change would
# silently migrate that identity between addresses already recorded in the
# dependency network and generator templates (see docs/src/state_contract.md,
# "Fixed extent: position is identity"). Allocate the final size with
# `ObservedArray{T,Index}(undef, dims...)` and fill by setindex!.
Base.push!(v::ObservedArray, x...) = throw(FixedExtentError(:push!))
Base.pop!(v::ObservedArray) = throw(FixedExtentError(:pop!))
Base.pushfirst!(v::ObservedArray, x...) = throw(FixedExtentError(:pushfirst!))
Base.popfirst!(v::ObservedArray) = throw(FixedExtentError(:popfirst!))
Base.append!(v::ObservedArray, items...) = throw(FixedExtentError(:append!))
Base.resize!(v::ObservedArray, n::Integer) = throw(FixedExtentError(:resize!))
Base.empty!(v::ObservedArray) = throw(FixedExtentError(:empty!))
Base.sizehint!(v::ObservedArray, n::Integer) = throw(FixedExtentError(:sizehint!))

function observed_notify(v::ObservedArray, changed, readwrite)
    address_notify(v._address, changed, readwrite)
end
