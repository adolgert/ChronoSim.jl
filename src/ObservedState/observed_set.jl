using Base: Base
export ObservedSet

"""
    ObservedSet{T,Key} <: AbstractSet{T}

A set that tracks mutations for the ChronoSim observed state system.
Unlike ObservedVector and ObservedDict, ObservedSet is not a container - 
elements within the set do not have addresses and cannot be individually tracked.

# Type Parameters
- `T`: Element type of the set
- `Key`: The type of index this set has within its parent container 
  (e.g., `Member` for struct fields, `Int` for vector elements)

# Examples
```julia
# In an observed struct
@observedphysical GameState begin
    buildings::ObservedSet{String,Member}
end

# In an observed vector  
floors = ObservedVector{ObservedSet{String,Int}}(undef, 10)
```
"""
mutable struct ObservedSet{T,Key} <: AbstractSet{T}
    const set::Set{T}
    _address::Address{Key}

    ObservedSet{T,Key}(set::Set{T}) where {T,Key} = new{T,Key}(set, Address{Key}())
end

# Constructors
ObservedSet{T,Key}() where {T,Key} = ObservedSet{T,Key}(Set{T}())
ObservedSet{T,Key}(items...) where {T,Key} = ObservedSet{T,Key}(Set{T}(items))

# For compatibility with collection initialization patterns
ObservedSet{T,Key}(itr) where {T,Key} = ObservedSet{T,Key}(Set{T}(itr))

# Mark as an observed container for the framework
is_observed_container(::ObservedSet) = true
is_observed_container(::Type{<:ObservedSet}) = true

# Property access pattern following ObservedArray
function Base.getproperty(s::ObservedSet, name::Symbol)
    name ∈ (:set, :_address) ? getfield(s, name) : getproperty(s.set, name)
end

# Notification helper - all changes are set-level since elements have no addresses
function observed_notify(s::ObservedSet, readwrite::Symbol)
    # Empty tuple since there's no specific index/key to track for set-level changes
    address_notify(s._address, (), readwrite)
end

# ============================================================================
# Read-only operations - forwarded directly without notification
# ============================================================================

# These operations don't need tracking as they don't reveal specific data
for op in [:eltype]
    @eval Base.$op(s::ObservedSet, args...; kwargs...) = $op(s.set, args...; kwargs...)
end

# Iterator interface - no notification needed as iteration is considered bulk access
Base.iterate(s::ObservedSet) = iterate(s.set)
Base.iterate(s::ObservedSet, state) = iterate(s.set, state)

# ============================================================================
# Read operations that access content - trigger read notifications
# ============================================================================

function Base.length(s::ObservedSet)
    observed_notify(s, :read)
    return length(s.set)
end

function Base.isempty(s::ObservedSet)
    observed_notify(s, :read)
    return isempty(s.set)
end

function Base.in(x, s::ObservedSet)
    observed_notify(s, :read)
    return in(x, s.set)
end

# Both directions of issubset
function Base.issubset(a::ObservedSet, b::Union{Set,Vector,Tuple})
    observed_notify(a, :read)
    return issubset(a.set, b)
end

function Base.issubset(a::Union{Set,Vector,Tuple}, b::ObservedSet)
    observed_notify(b, :read)
    return issubset(a, b.set)
end

function Base.issubset(a::ObservedSet, b::ObservedSet)
    observed_notify(a, :read)
    observed_notify(b, :read)
    return issubset(a.set, b.set)
end

# ============================================================================
# Mutating operations - all trigger write notifications
# ============================================================================

function Base.push!(s::ObservedSet, item)
    observed_notify(s, :write)
    push!(s.set, item)
    return s
end

function Base.push!(s::ObservedSet, item, items...)
    observed_notify(s, :write)
    push!(s.set, item, items...)
    return s
end

function Base.pop!(s::ObservedSet)
    observed_notify(s, :write)
    return pop!(s.set)
end

function Base.pop!(s::ObservedSet, item)
    observed_notify(s, :write)
    return pop!(s.set, item)
end

function Base.pop!(s::ObservedSet, item, default)
    observed_notify(s, :write)
    return pop!(s.set, item, default)
end

function Base.delete!(s::ObservedSet, item)
    observed_notify(s, :write)
    delete!(s.set, item)
    return s
end

function Base.empty!(s::ObservedSet)
    observed_notify(s, :write)
    empty!(s.set)
    return s
end

# ============================================================================
# Set operations - mutating versions
# ============================================================================

function Base.union!(s::ObservedSet, others...)
    observed_notify(s, :write)
    union!(s.set, others...)
    return s
end

function Base.intersect!(s::ObservedSet, others...)
    observed_notify(s, :write)
    intersect!(s.set, others...)
    return s
end

function Base.intersect!(s::ObservedSet, other::AbstractSet)
    observed_notify(s, :write)
    intersect!(s.set, other)
    return s
end

function Base.setdiff!(s::ObservedSet, others...)
    observed_notify(s, :write)
    setdiff!(s.set, others...)
    return s
end

function Base.symdiff!(s::ObservedSet, others...)
    observed_notify(s, :write)
    symdiff!(s.set, others...)
    return s
end

function Base.symdiff!(s::ObservedSet, other::AbstractSet)
    observed_notify(s, :write)
    symdiff!(s.set, other)
    return s
end

# ============================================================================
# Non-mutating set operations - create regular Sets
# ============================================================================

# These create new Sets, not ObservedSets, matching Julia's convention
Base.union(s::ObservedSet, others...) = union(s.set, others...)
Base.intersect(s::ObservedSet, others...) = intersect(s.set, others...)
Base.setdiff(s::ObservedSet, others...) = setdiff(s.set, others...)
Base.symdiff(s::ObservedSet, others...) = symdiff(s.set, others...)

# ============================================================================
# Equality and hashing
# ============================================================================

Base.:(==)(a::ObservedSet, b::ObservedSet) = a.set == b.set
Base.:(==)(a::ObservedSet, b::AbstractSet) = a.set == b
Base.:(==)(a::AbstractSet, b::ObservedSet) = a == b.set

Base.hash(s::ObservedSet, h::UInt) = hash(s.set, h)

# ============================================================================
# Display
# ============================================================================

Base.show(io::IO, s::ObservedSet{T,Key}) where {T,Key} = show(io, s.set)
function Base.show(io::IO, ::MIME"text/plain", s::ObservedSet{T,Key}) where {T,Key}
    show(io, MIME"text/plain"(), s.set)
end
