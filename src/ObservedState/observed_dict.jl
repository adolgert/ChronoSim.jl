mutable struct ObservedDict{K,V} <: AbstractDict{K,V}
    const dict::Dict{K,V}
    field_name::Symbol
    owner::Any
    ObservedDict{K,V}(dict) where {K,V} = new{K,V}(dict)
end

# Constructors
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


# Forward read-only operations
for op in [:eltype, :haskey, :isempty, :iterate, :keys, :length, :pairs, :size, :sizehint!, :values]
    @eval Base.$op(tv::ObservedDict, args...; kwargs...) = $op(tv.dict, args...; kwargs...)
end


function Base.getindex(d::ObservedDict, key)
    element = d.dict[key]
    setfield!(element, :_container, d)
    setfield!(element, :_index, key)
    return element
end

function Base.setindex!(d::ObservedDict, value, key)
    d.dict[key] = value
    setfield!(value, :_container, d)
    setfield!(value, :_index, key)
    return value
end

function Base.delete!(d::ObservedDict, key)
    if haskey(d.dict, key)
        element = d.dict[key]
        setfield!(element, :_container, nothing)
        # missing: notify all fields of this element
        # Note: _index is left as-is since it might still be meaningful
        delete!(d.dict, key)
    end
    return d
end


function Base.pop!(d::ObservedDict, key)
    if haskey(d.dict, key)
        element = d.dict[key]
        # missing: notify all fields of this element
        setfield!(element, :_container, nothing)
        return pop!(d.dict, key)
    end
    return nothing
end

function Base.pop!(d::ObservedDict, key, default)
    if haskey(d.dict, key)
        element = d.dict[key]
        # missing: notify all fields of this element
        setfield!(element, :_container, nothing)
        return pop!(d.dict, key, default)
    end
    return nothing
end

# popfirest!, poplast!
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
function Base.iterate(d::ObservedDict)
    next = iterate(d.dict)
    if next === nothing
        return nothing
    else
        (k, v), state = next
        return (k => v), state
    end
end

function Base.iterate(d::ObservedDict, state)
    next = iterate(d.dict, state)
    if next === nothing
        return nothing
    else
        (k, v), state = next
        return (k => v), state
    end
end


function observed_notify(v::ObservedDict, changed, readwrite)
    if isdefined(v, :owner)
        observed_notify(
            getfield(v, :owner), (Member(getfield(v, :field_name)), changed...), readwrite
        )
    end
end
