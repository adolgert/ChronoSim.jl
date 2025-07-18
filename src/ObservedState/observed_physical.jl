using Base: Base
using OrderedCollections
using ..ChronoSim: PhysicalState

export @observedphysical, ObservedPhysical

# Base type for observed physical states
abstract type ObservedPhysical <: PhysicalState end

"""
    @observedphysical <typename> <definition block>

This macro defines a physical state that uses the ObservedState
machinery to track changes to that physical state.

For example:
```julia
@keyedby Int Piece begin
    speed::Float64
    kind::String
end

@keyedby NTuple{2,Int64} Square begin
    grass::Float64
    food::Float64
end

@observedphysical Board begin
    board::ObservedArray{Square,2}
    actor::ObservedDict{Int,Piece}
    params::Dict{Symbol,Float64}
    actors_max::Int64
end
```
This macro creates a struct that contains tracking information about
its Observed members, so in the example `params` would not be tracked.
The `Board` type has a parent type `ObservedPhysical` which has the
parent type `ChronoSim.PhysicalState`.

Expanding the macro, we would see:
```julia
mutable struct Board <: ObservedPhysical
    board::ObservedArray{Square,2}
    actor::ObservedDict{Int,Piece}
    params::Dict{Symbol,Float64}
    actors_max::Int64
    obs_modified::Vector{Tuple}
    obs_read::Vector{Tuple}
    Board(board, actor, params, actors_max) = ...
end
```
Here, the list of read and modified state uses the abstract type
`Tuple` because it unifies the way changed state is reported for the
two observed containers: `(:board, (2,2), :grass)` and
`(:actor, 7, :speed)`. The ellipsis above for the constructor is a
constructor that initializes `obs_modified` and `obs_read` to empty
vectors.
"""
macro observedphysical(struct_name, struct_block)
    # Validate inputs
    if !isa(struct_name, Symbol)
        error("@observedphysical expects a struct name as the first argument")
    end

    if !isa(struct_block, Expr) || struct_block.head != :block
        error("@observedphysical expects a begin...end block with struct fields")
    end

    # Parse fields from the block
    user_fields = []
    observed_fields = []  # Track which fields are ObservedArray or ObservedDict
    for stmt in struct_block.args
        if isa(stmt, Expr) && stmt.head == :(::)
            push!(user_fields, stmt)
            # Check if this is an observed field
            field_name = stmt.args[1]
            field_type = stmt.args[2]
            if isa(field_type, Expr) && field_type.head == :curly
                type_name = field_type.args[1]
                if type_name == :ObservedArray || type_name == :ObservedDict
                    push!(observed_fields, field_name)
                end
            end
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
        mutable struct $struct_name <: ObservedPhysical
            $(user_fields...)
            obs_modified::Vector{Tuple}
            obs_read::Vector{Tuple}

            # Constructor that takes user fields and initializes tracking vectors
            function $struct_name($(constructor_args...))
                instance = new($(constructor_args...), Vector{Tuple}(), Vector{Tuple}())

                # Set up owner references for observed fields
                $(
                    [
                        :(
                            begin
                                field = getfield(instance, $(QuoteNode(fname)))
                                field.array_name = $(QuoteNode(fname))
                                field.owner = instance
                            end
                        ) for fname in observed_fields
                    ]...
                )

                return instance
            end
        end
    end

    return esc(struct_def)
end

"""
    capture_state_changes(f::Function, physical_state)

The callback function `f` will modify the physical state. This function
records which parts of the state were modified. The callback should have
no arguments and may return a result.
"""
function capture_state_changes(f::Function, physical::ObservedPhysical)
    empty!(physical.obs_modified)
    result = f()
    # Use ordered set here so that list is deterministic.
    changes = OrderedSet(physical.obs_modified)
    return (;result, changes)
end

"""
    capture_state_reads(f::Function, physical_state)

The callback function `f` will read the physical state. This function
records which parts of the state were read. The callback should have
no arguments and may return a result.
"""
function capture_state_reads(f::Function, physical::ObservedPhysical)
    empty!(physical.obs_read)
    result = f()
    reads = OrderedSet(physical.obs_read)
    return (;result, reads)
end

function observed_notify(physical::ObservedPhysical, changed, readwrite)
    if readwrite == :read
        push!(physical.obs_read, changed)
    else
        push!(physical.obs_modified, changed)
    end
end
