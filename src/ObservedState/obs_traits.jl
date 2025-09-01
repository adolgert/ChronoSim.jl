
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
"""
mutable struct Address{Key}
    container::Any
    index::Key
    Address{Key}() where {Key} = new(nothing)
end


function update_index(addr::Address, container, index)
    addr.container = container
    addr.index = index
end


function address_notify(addr::Address, changed, readwrite)
    !isnothing(addr.container) || return nothing
    observe_notify(addr.container, (Member(addr.index), changed...), readwrite)
end


Base.empty!(addr::Address) = (addr.container=nothing; nothing)
