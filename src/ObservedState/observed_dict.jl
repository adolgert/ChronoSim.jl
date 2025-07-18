mutable struct ObservedDict{K,V} <: AbstractDict{K,V}
    const dict::Dict{K,V}
    array_name::Symbol
    owner::Any
    ObservedDict{K,V}(dict) where {K,V} = new{K,V}(dict)
end

# Constructors
ObservedDict{K,V}() where {K,V} = ObservedDict{K,V}(Dict{K,V}())
ObservedDict() = ObservedDict{Any,Any}()

# Required AbstractDict interface methods
Base.length(d::ObservedDict) = length(d.dict)
Base.isempty(d::ObservedDict) = isempty(d.dict)
Base.haskey(d::ObservedDict, key) = haskey(d.dict, key)
Base.keys(d::ObservedDict) = keys(d.dict)
Base.values(d::ObservedDict) = values(d.dict)
Base.pairs(d::ObservedDict) = pairs(d.dict)

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
        # Note: _index is left as-is since it might still be meaningful
        delete!(d.dict, key)
    end
    return d
end

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

# Other useful methods
Base.empty!(d::ObservedDict) = (empty!(d.dict); d)
Base.sizehint!(d::ObservedDict, n) = (sizehint!(d.dict, n); d)
