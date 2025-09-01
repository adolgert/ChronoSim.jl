# This helps support ObservedVector and ObservedArray that may contain
# compound types or primitive types.
abstract type StructureTrait end
struct PrimitiveTrait <: StructureTrait end
struct CompoundTrait <: StructureTrait end

# Represents a container that doesn't have an Address.
# If this is in an observed hierarchy, it is an error.
struct UnObservableTrait <: StructureTrait end

structure_trait(::Type{T}) where {T} =
    if (isprimitivetype(T) || !ismutable(T))
        PrimitiveTrait()
    elseif is_observed_container(T)
        CompoundTrait()
    else
        UnObservableTrait()
    end


"""
    Address{Key}()

Represents the address of this compound struct within the container that has
this object. This object is mutable because addresses change as containers
modify their contents.

If this object is in a vector, the `Key=Int`. If it's in a struct,
`Key=Member`, which is a wrapper around the fieldname Symbol.
"""
mutable struct Address{Key}
    container::Any
    index::Key
    Address{Key}() where {Key} = new(nothing)
end

function Base.show(io::IO, addr::Address)
    print(
        io,
        "Address(",
        isnothing(addr.container) ? "nothing" : "container",
        ", ",
        isdefined(addr, :index) ? addr.index : "undef",
        ")",
    )
end

function update_index(addr::Address, container, index)
    addr.container = container
    addr.index = index
    return nothing
end


function address_notify(addr::Address, changed, readwrite)
    !isnothing(addr.container) || return nothing
    observed_notify(addr.container, (addr.index, changed...), readwrite)
end


Base.empty!(addr::Address) = (addr.container=nothing; nothing)

# If a struct has an Address, that shouldn't count against two instances being equal.
Base.:(==)(a::Address, b::Address) = true
