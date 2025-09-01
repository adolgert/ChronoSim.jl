
# This helps support ObservedVector and ObservedArray that may contain
# compound types or primitive types.
abstract type StructureTrait end
struct PrimitiveTrait <: StructureTrait end
struct CompoundTrait <: StructureTrait end

function structure_trait(::Type{T}) where {T}
    (isprimitivetype(T) || !ismutable(T)) ? PrimitiveTrait() : CompoundTrait()
end
