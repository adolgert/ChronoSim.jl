module ObservedState

using Base: Base
export ObservedArray, ObservedDict, ObservedSet, ObservedPhysical
export @keyedby, @observedphysical, @obsread, @obswrite
export capture_state_reads, capture_state_changes
public is_observed_container

is_observed_container(::Any) = false

struct Param{T}
    value::T
end
export Param, is_observed_container
Base.convert(::Type{Param{T}}, x::T) where {T} = Param{T}(x)

using ..ChronoSim: Member

include("obs_traits.jl")
include("observed_physical.jl")
include("observed_vector.jl")
include("observed_dict.jl")
include("observed_set.jl")
include("keyed.jl")
include("observe_macro.jl")

end
