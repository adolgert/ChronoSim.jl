export PhysicalState, isconsistent
public over_tracked_physical_state, capture_state_changes, capture_state_reads
export Member

"""
`PhysicalState` is an abstract type from which to inherit the state of a simulation.
A `PhysicalState` should put all mutable values, the values upon which events
depend, into `TrackedVector` objects. For instance:

```
@tracked_struct Square begin
    occupant::Int
    resistance::Float64
end

# Everything we know about an agent.
@tracked_struct Agent begin
    health::Health
    loc::CartesianIndex{2}
end

mutable struct BoardState <: PhysicalState
    board::TrackedVector{Square}
    agent::TrackedVector{Agent}
end
```

The `PhysicalState` may contain other properties, but those defined with
`TrackedVectors` are used to compute the next event in the simulation.
"""
abstract type PhysicalState end

"""
    isconsistent(physical_state)

A simulation in debug mode will assert `isconsistent(physical_state)` is true.
Override this to verify the physical state of your simulation.
"""
isconsistent(::PhysicalState) = true

"""
    over_tracked_physical_state(fcallback::Function, physical::PhysicalState)

Iterate over all tracked vectors in the physical state.
"""
function over_tracked_physical_state(fcallback::Function, physical::T) where {T<:PhysicalState} end

"""
    capture_state_changes(f::Function, physical_state)

The callback function `f` will modify the physical state. This function
records which parts of the state were modified. The callback should have
no arguments and may return a result.
"""
function capture_state_changes(f::Function, physical)
    @assert false
end

"""
    capture_state_reads(f::Function, physical_state)

The callback function `f` will read the physical state. This function
records which parts of the state were read. The callback should have
no arguments and may return a result.
"""
function capture_state_reads(f::Function, physical) end

"""
This represents a field in a struct. It is a wrapper around Symbol.
We wrap the Symbol so that it doesn't conflict with dictionary keys that
are symbols.
"""
struct Member
    name::Symbol
end

Base.show(io::IO, m::Member) = print(io, m.name)
Base.Symbol(m::Member) = m.name
Base.convert(::Type{Symbol}, m::Member) = m.name
