
module ChronoSimTests
using ChronoSim
using ReTest

continuous_integration() = get(ENV, "CI", "false") == "true"

# Include test files directly at module level so @testset blocks are properly registered
include("test_container_fuzz.jl")
include("test_coverage.jl")
include("test_depnet.jl")
include("test_derivation_spike.jl")
include("test_derive.jl")
include("test_derive_effects.jl")
include("test_effect_coverage.jl")
include("test_elevator.jl")
include("test_events.jl")
include("test_framework.jl")
include("test_generator_search.jl")
include("test_generators.jl")
include("test_guard.jl")
include("test_immediate.jl")
include("test_invariant.jl")
include("test_lint.jl")
include("test_obs_traits.jl")
include("test_observe.jl")
include("test_observed_array.jl")
include("test_observed_dict.jl")
include("test_observed_physical.jl")
include("test_observed_set.jl")
include("test_observed_state.jl")
include("test_physical_interface.jl")
include("test_policy.jl")
include("test_policy_stack.jl")
include("test_quint.jl")
include("test_replay.jl")
include("test_skeleton.jl")
include("test_static.jl")
include("test_trace_eval.jl")
include("test_why.jl")


retest(args...; kwargs...) = ReTest.retest(args...; kwargs...)

end
