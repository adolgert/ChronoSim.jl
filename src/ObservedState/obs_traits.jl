export Address

# This helps support ObservedVector and ObservedArray that may contain
# compound types or primitive types.
#   - PrimitiveTrait: Tracks reads/writes, calls observed_notify
#   - CompoundTrait: No read tracking, but on writes calls update_index and notify_all
#   - UnObservableTrait: No tracking at all, just direct field access
abstract type StructureTrait end
struct PrimitiveTrait <: StructureTrait end
struct CompoundTrait <: StructureTrait end
# Represents a container that doesn't have an Address.
# If this is in an observed hierarchy, it is an error.
struct UnObservableTrait <: StructureTrait end

structure_trait(::Type{T}) where {T} =
    if T <: Param
        UnObservableTrait()
    elseif is_observed_container(T)
        CompoundTrait()
    else
        PrimitiveTrait()
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

"""
The show() function for `Address{Key}` doesn't print the container
because the type can be quite large.
"""
function Base.show(io::IO, addr::Address)
    print(
        io,
        "Address(",
        isnothing(addr.container) ? "nothing" : "contained",
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
    # Ensure any changed is a tuple so we don't destructure a String.
    @assert changed isa Tuple
    !isnothing(addr.container) || return nothing
    observed_notify(addr.container, (addr.index, changed...), readwrite)
end


Base.empty!(addr::Address) = (addr.container=nothing; nothing)
