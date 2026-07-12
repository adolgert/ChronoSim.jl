module ChronoSim

include("depnet.jl")
include("physical_interface.jl")
include("generator_interface.jl")
include("ObservedState/ObservedState.jl")
include("events.jl")
include("event_entry.jl")       # Phase OB-3b: event families (entries) + the parameter binding
include("recipe.jl")            # Milestone 2 (G4): θ-free DistRecipe behind the seam
include("generators.jl")
include("derive.jl")
include("derive_effects.jl")    # Phase 2: @fire + WriteSpec + can_stop_change
include("guard.jl")
include("coverage.jl")
include("policy.jl")
include("effect_coverage.jl")   # Phase 2: CheckEffects oracle (needs ExecutionPolicy)
include("placetoevent.jl")
include("counting_rng.jl")      # Adoption 1: draw-counting rng proxy (used by framework.jl)
include("framework.jl")
include("skeleton.jl")
include("minimal_record.jl")    # Adoption 1/2: minimal record schema + effect check
include("functionals.jl")       # Phase OB-1: path functionals + the derived state fold
include("initial_law.jl")       # Phase OB-2: the initial law (declared time-zero state)
include("gsmp_model.jl")        # Phase OB-3c: the model value (GsmpModel + simulate)
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
