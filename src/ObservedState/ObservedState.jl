module ObservedState

using Base: Base
export ObservedArray, ObservedDict, ObservedPhysical
export @keyedby, @observedphysical, @observe
export capture_state_reads, capture_state_changes
public is_observed_container

is_observed_container(::Any) = false

using ..ChronoSim: Member

include("observed_physical.jl")
include("observed_vector.jl")
include("observed_dict.jl")
include("keyed.jl")
include("observe_macro.jl")

end
