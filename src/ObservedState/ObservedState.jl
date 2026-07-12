module ObservedState

using Base: Base
export ObservedArray, ObservedDict, ObservedSet, ObservedPhysical
export @keyedby, @observedphysical, @obsread, @obswrite
export capture_state_reads, capture_state_changes
public is_observed_container

is_observed_container(::Any) = false

"""
    Param{T}

A wrapper for state fields that are configuration rather than simulation
state. Reads of a `Param` field are not tracked and create no dependencies,
which is right for values that never change during a run, such as rate
tables or precomputed geometry. Access is transparent: the field behaves as
a `T`. The generated state constructor accepts an unwrapped `T` and wraps
it.
"""
struct Param{T}
    value::T
end
export Param
Base.convert(::Type{Param{T}}, x::T) where {T} = Param{T}(x)

using ..ChronoSim: Member

include("obs_traits.jl")
include("observed_physical.jl")
include("observed_vector.jl")
include("observed_dict.jl")
include("observed_set.jl")
include("keyed.jl")
include("observe_macro.jl")
include("clone.jl")
include("addresses.jl")

end
