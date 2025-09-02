abstract type Addressed end
export Addressed

"""
    notify_all(obj)
e
When a struct is deleted or has its index changed, it should create a notification
for every member of the struct.
"""
notify_all(obj) =
    for prop_name in propertynames(obj)
        prop_obj = getfield(obj, prop_name)
        if isa(structure_trait(typeof(prop_obj)), PrimitiveTrait)
            address_notify(obj._address, (Member(prop_name),), :write)
        else
            notify_all(prop_obj)
        end
    end

notify_all(::Address) = nothing

is_observed_container(::Addressed) = true
is_observed_container(::Type{<:Addressed}) = true

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
mutable struct MyElement <: Addressed
    val::Int64
    name::String
    _address::Address{Int64}
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
    field_names = Symbol[]
    for stmt in struct_block.args
        if isa(stmt, Expr) && stmt.head == :(::)
            push!(user_fields, stmt)
            push!(field_names, stmt.args[1])
        elseif isa(stmt, LineNumberNode)
            # Skip line number nodes
            continue
        elseif isa(stmt, Symbol)
            # Handle untyped fields
            push!(user_fields, stmt)
            push!(field_names, stmt)
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
        mutable struct $struct_name <: Addressed
            $(user_fields...)
            _address::ChronoSim.ObservedState.Address{$index_type}

            function $struct_name($(constructor_args...))
                new($(constructor_args...), ChronoSim.ObservedState.Address{$index_type}())
            end
        end
    end

    getprop_def = quote
        function Base.getproperty(obj::$struct_name, field::Symbol)
            if field != :_address
                ChronoSim.ObservedState.address_notify(obj._address, (Member(field),), :read)
            end
            return getfield(obj, field)
        end
    end

    setprop_def = quote
        function Base.setproperty!(obj::$struct_name, field::Symbol, value)
            if field != :_address
                ChronoSim.ObservedState.address_notify(obj._address, (Member(field),), :write)
            end
            return setfield!(obj, field, value)
        end
    end

    propnames_def = quote
        function Base.propertynames(obj::$struct_name, private::Bool=false)
            if private
                return fieldnames($struct_name)
            else
                return $(Tuple(field_names))
            end
        end
    end

    # Create equality comparison
    field_comparisons = [
        :(getproperty(a, $(QuoteNode(fname))) == getproperty(b, $(QuoteNode(fname)))) for
        fname in field_names
    ]
    eq_expr = length(field_comparisons) > 0 ? Expr(:&&, field_comparisons...) : true

    eq_def = quote
        Base.:(==)(a::$struct_name, b::$struct_name) = $eq_expr
    end

    # Return all definitions together
    return esc(quote
        $struct_def
        $getprop_def
        $setprop_def
        $propnames_def
        $eq_def
    end)
end
