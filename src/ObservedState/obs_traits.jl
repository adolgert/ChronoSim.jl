
# This helps support ObservedVector and ObservedArray that may contain
# compound types or primitive types.
abstract type StructureTrait end
struct PrimitiveTrait <: StructureTrait end
struct CompoundTrait <: StructureTrait end

# Represents a container that doesn't have an Address.
# If this is in an observed hierarchy, it is an error.
struct UnObservableTrait <: StructureTrait end

function structure_trait(::Type{T}) where {T}
    if (isprimitivetype(T) || !ismutable(T))
        PrimitiveTrait()
    elseif is_observed_container(T)
        CompoundTrait()
    else
        UnObservableTrait()
    end
end
