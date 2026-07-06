module ChronoSim

include("depnet.jl")
include("physical_interface.jl")
include("generator_interface.jl")
include("ObservedState/ObservedState.jl")
include("events.jl")
include("generators.jl")
include("derive.jl")
include("derive_effects.jl")    # Phase 2: @fire + WriteSpec + can_stop_change
include("guard.jl")
include("coverage.jl")
include("policy.jl")
include("effect_coverage.jl")   # Phase 2: CheckEffects oracle (needs ExecutionPolicy)
include("placetoevent.jl")
include("framework.jl")
include("skeleton.jl")
include("policy_stack.jl")      # Phase 1d: PolicyStack + find_policy
include("invariant.jl")         # Phase 1d: @invariant + CheckInvariants
include("replay.jl")
include("why.jl")               # Phase 1e: the why-verbs
include("lint.jl")              # Phase 3: footprint lints (@guard + lint + LintHarvest)

# Phase 4: the Quint compiler + generic trace validation (pure Julia to emit;
# checker invocation is environment-gated via QuintToolchain).
include("quint/types.jl")
include("quint/schema.jl")
include("quint/printer.jl")
include("quint/effects.jl")
include("quint/assemble.jl")
include("quint/trace.jl")

end
