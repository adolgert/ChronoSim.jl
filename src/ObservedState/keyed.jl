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
