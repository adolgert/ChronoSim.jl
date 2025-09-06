mutable struct ObservedDict{K,V,Index} <: AbstractDict{K,V}
    const dict::Dict{K,V}
    _address::Address{Index}
    ObservedDict{K,V,Index}(dict) where {K,V,Index} = new{K,V,Index}(dict, Address{Index}())
end

ObservedDict{K,V,Index}() where {K,V,Index} = ObservedDict{K,V,Index}(Dict{K,V}())
ObservedDict() = ObservedDict{Any,Any,Any}()
function ObservedDict{Index}(pairs...) where {Index}
    K = typejoin([typeof(k) for (k, _) in pairs])
    V = typejoin([typeof(v) for (_, v) in pairs])
    od = ObservedDict{K,V,Index}(Dict{K,V}())
    for (k, v) in pairs
        setindex!(od, v, k)
    end
    return od
end
function ObservedDict{Index}(other::AbstractDict{K,V}) where {K,V,Index}
    od = ObservedDict{K,V,Index}(Dict{K,V}())
    for (k, v) in other
        setindex!(od, v, k)
    end
    return od
end

is_observed_container(v::ObservedDict) = true
is_observed_container(v::Type{<:ObservedDict}) = true


for op in [:eltype, :sizehint!]
    @eval Base.$op(tv::ObservedDict, args...; kwargs...) = $op(tv.dict, args...; kwargs...)
end

# These operations read the entire dict structure
# Event generation relies on notifications that are all the way down to the
# leaf node. Here an isempty will happen with no keys in the Dict, so the leaf
# node can dynamically be the dictionary itself, which would require another
# generator.
for op in [:isempty, :length, :size, :keys, :pairs, :values]
    @eval function Base.$op(tv::ObservedDict, args...; kwargs...)
        observed_notify(tv, (), :read)
        return $op(tv.dict, args...; kwargs...)
    end
end

Base.getindex(v::ObservedDict, i...) = _getindex(structure_trait(valtype(v)), v, i...)

function _getindex(::PrimitiveTrait, d::ObservedDict, key)
    element = d.dict[key]
    observed_notify(d, (key,), :read)
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
    observed_notify(d, (key,), :write)
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
        observed_notify(d, (key,), :write)
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
        observed_notify(d, (key,), :write)
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

Base.haskey(d::ObservedDict, key, default) =
    if haskey(d.dict, key)
        observed_notify(d, (key,), :read)
        return true
    else
        observed_notify(d, (), :read)
        return false
    end

# Iteration interface
Base.iterate(d::ObservedDict) = _iterate(structure_trait(valtype(d)), d)
Base.iterate(d::ObservedDict, state) = _iterate(structure_trait(valtype(d)), d, state)

function _iterate(::PrimitiveTrait, d::ObservedDict)
    next = iterate(d.dict)
    return if next === nothing
        nothing
    else
        observed_notify(d, (next[1].first,), :read)
        next
    end
end

_iterate(::CompoundTrait, d::ObservedDict) = iterate(d.dict)

function _iterate(::PrimitiveTrait, d::ObservedDict, state)
    next = iterate(d.dict, state)
    if next === nothing
        return nothing
    else
        observed_notify(d, (next[1].first,), :read)
        return next
    end
end

_iterate(::CompoundTrait, d::ObservedDict, state) = return iterate(d.dict, state)

function observed_notify(v::ObservedDict, changed, readwrite)
    address_notify(v._address, changed, readwrite)
end
