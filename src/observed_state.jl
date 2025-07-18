module ObservedState

using Base: Base
export ObservedArray, ObservedDict
export @keyedby

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

# ObservedDict implementation
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

"""
    @keyedby StructName IndexType begin
        field1::Type1
        field2::Type2
        ...
    end

Create a mutable struct with the given fields plus automatic `_container::Any` and `_index::IndexType` fields.
The generated constructor only requires the user-defined fields.

# Example
```julia
@keyedby MyElement Int64 begin
    val::Int64
    name::String
end
```

This generates a struct equivalent to:
```julia
mutable struct MyElement
    val::Int64
    name::String
    _container::Any
    _index::Int64
    MyElement(val, name) = new(val, name)
end
```
"""
macro keyedby(struct_name, index_type, struct_block)
    # Validate inputs
    if !isa(struct_name, Symbol)
        error("@keyedby expects a struct name as the first argument")
    end

    if !isa(struct_block, Expr) || struct_block.head != :block
        error("@keyedby expects a begin...end block with struct fields")
    end

    # Parse fields from the block
    user_fields = []
    for stmt in struct_block.args
        if isa(stmt, Expr) && stmt.head == :(::)
            push!(user_fields, stmt)
        elseif isa(stmt, LineNumberNode)
            # Skip line number nodes
            continue
        elseif isa(stmt, Symbol)
            # Handle untyped fields
            push!(user_fields, stmt)
        end
    end

    # Build constructor arguments (just the user fields)
    constructor_args = []
    for field in user_fields
        if isa(field, Expr) && field.head == :(::)
            push!(constructor_args, field.args[1])
        else
            push!(constructor_args, field)
        end
    end

    # Create the struct definition
    struct_def = quote
        mutable struct $struct_name
            $(user_fields...)
            _container::Any
            _index::$index_type

            # Constructor that only takes user fields
            $struct_name($(constructor_args...)) = new($(constructor_args...))
        end
    end

    return esc(struct_def)
end

end
