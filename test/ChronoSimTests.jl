
module ChronoSimTests
using ChronoSim
using ReTest

continuous_integration() = get(ENV, "CI", "false") == "true"

# Include test files directly at module level so @testset blocks are properly registered
include("test_static.jl")
include("test_physical_interface.jl")
include("test_observed_state.jl")
include("test_observed_physical.jl")
include("test_observe.jl")
include("test_events.jl")
include("test_generators.jl")
include("test_generator_search.jl")

retest(args...; kwargs...) = ReTest.retest(args...; kwargs...)

end
