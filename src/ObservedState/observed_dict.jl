mutable struct ObservedDict{K,V} <: AbstractDict{K,V}
    const dict::Dict{K,V}
    _address::Address{Member}
    ObservedDict{K,V}(dict) where {K,V} = new{K,V}(dict, Address{Member}())
end

ObservedDict{K,V}() where {K,V} = ObservedDict{K,V}(Dict{K,V}())
ObservedDict() = ObservedDict{Any,Any}()
function ObservedDict(pairs...)
    K = typejoin([typeof(k) for (k, _) in pairs])
    V = typejoin([typeof(v) for (_, v) in pairs])
    od = ObservedDict{K,V}(Dict{K,V}())
    for (k, v) in pairs
        setindex!(od, v, k)
    end
    return od
end
function ObservedDict(other::AbstractDict{K,V}) where {K,V}
    od = ObservedDict{K,V}(Dict{K,V}())
    for (k, v) in other
        setindex!(od, v, k)
    end
    return od
end

is_observed_container(v::ObservedDict) = true
is_observed_container(v::Type{<:ObservedDict}) = true


# Forward read-only operations
for op in [:eltype, :haskey, :isempty, :iterate, :keys, :length, :pairs, :size, :sizehint!, :values]
    @eval Base.$op(tv::ObservedDict, args...; kwargs...) = $op(tv.dict, args...; kwargs...)
end

Base.getindex(v::ObservedDict, i...) = _getindex(structure_trait(valtype(v)), v, i...)

function _getindex(::PrimitiveTrait, d::ObservedDict, key)
    element = d.dict[key]
    observed_notify(d, key, :read)
    return element
end

function _getindex(::CompoundTrait, d::ObservedDict, key)
    element = d.dict[key]
    return _update_index(element, d, key)
end

function Base.setindex!(v::ObservedDict, value, i...)
    _setindex!(structure_trait(valtype(v)), v, value, i...)
end

function _setindex!(::PrimitiveTrait, d::ObservedDict, value, key)
    d.dict[key] = value
    observed_notify(d, key, :write)
    return value
end

function _setindex!(::CompoundTrait, d::ObservedDict, value, key)
    d.dict[key] = value
    _update_index(value, d, key)
    notify_all(value)
    return value
end

Base.delete!(v::ObservedDict, i...) = _delete!(structure_trait(valtype(v)), v, i...)

function _delete!(::PrimitiveTrait, d::ObservedDict, key)
    if haskey(d.dict, key)
        delete!(d.dict, key)
        observed_notify(d, key, :write)
    end
    return d
end

function _delete!(::CompoundTrait, d::ObservedDict, key)
    if haskey(d.dict, key)
        element = d.dict[key]
        notify_all(element)
        empty!(element._address)
        delete!(d.dict, key)
    end
    return d
end

Base.pop!(v::ObservedDict, key) = _pop!(structure_trait(valtype(v)), v, key)

function _pop!(::PrimitiveTrait, d::ObservedDict, key)
    if haskey(d.dict, key)
        observed_notify(d, key, :write)
        return pop!(d.dict, key)
    end
    return nothing
end

function _pop!(::CompoundTrait, d::ObservedDict, key, default)
    if haskey(d.dict, key)
        element = d.dict[key]
        notify_all(element)
        empty!(element._address)
        return pop!(d.dict, key, default)
    end
    return nothing
end

# Maybe these can rely on AbstractDict implementations.
# merge!, empty!, merge
# similar(d) and similar(d, ::Type{Pair{K,V}})
# filter!(f, d)
# in(pair, d) for pair membership

Base.get(d::ObservedDict, key, default) =
    if haskey(d.dict, key)
        return d[key]  # This will update _container and _index
    else
        return default
    end

Base.get!(d::ObservedDict, key, default) =
    if haskey(d.dict, key)
        return d[key]
    else
        d[key] = default
        return default
    end

# Iteration interface
Base.iterate(d::ObservedDict) = _iterate(structure_trait(valtype(d)), d)
Base.iterate(d::ObservedDict, state) = _iterate(structure_trait(valtype(d)), d, state)

function _iterate(::PrimitiveTrait, d::ObservedDict)
    next = iterate(d.dict)
    return if next === nothing
        nothing
    else
        observed_notify(d, next[1].first, :read)
        next
    end
end

_iterate(::CompoundTrait, d::ObservedDict) = iterate(d.dict)

function _iterate(::PrimitiveTrait, d::ObservedDict, state)
    next = iterate(d.dict, state)
    if next === nothing
        return nothing
    else
        observed_notify(d, next[1].first, :read)
        return next
    end
end

_iterate(::CompoundTrait, d::ObservedDict, state) = return iterate(d.dict, state)

function observed_notify(v::ObservedDict, changed, readwrite)
    address_notify(v._address, changed, readwrite)
end
