
# This helps support ObservedVector and ObservedArray that may contain
# compound types or primitive types.
abstract type StructureTrait end
struct PrimitiveTrait <: StructureTrait end
struct CompoundTrait <: StructureTrait end

structure_trait(::Type{T}) where {T} = isprimitivetype(T) ? PrimitiveTrait() : CompoundTrait()
