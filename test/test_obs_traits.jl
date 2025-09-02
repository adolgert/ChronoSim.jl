using ReTest
using ChronoSim
using ChronoSim.ObservedState

@testset "ObsTraits" begin
    obstrait_categories = [
        (Int, ChronoSim.ObservedState.PrimitiveTrait()),
        (Float64, ChronoSim.ObservedState.PrimitiveTrait()),
        (Bool, ChronoSim.ObservedState.PrimitiveTrait()),
        (Char, ChronoSim.ObservedState.PrimitiveTrait()),
        (String, ChronoSim.ObservedState.PrimitiveTrait()),
        (ObservedArray, ChronoSim.ObservedState.CompoundTrait()),
        (ObservedVector, ChronoSim.ObservedState.CompoundTrait()),
        (ObservedMatrix, ChronoSim.ObservedState.CompoundTrait()),
        (ObservedDict, ChronoSim.ObservedState.CompoundTrait()),
        (ChronoSim.ObservedState.Address, ChronoSim.ObservedState.PrimitiveTrait()),
        (Array, ChronoSim.ObservedState.PrimitiveTrait()),
        (Dict, ChronoSim.ObservedState.PrimitiveTrait()),
        (Param{Int}, ChronoSim.ObservedState.UnObservableTrait()),
        (Param{Array}, ChronoSim.ObservedState.UnObservableTrait()),
        (Param{ObservedArray}, ChronoSim.ObservedState.UnObservableTrait()),
    ]
    for obs_idx in eachindex(obstrait_categories)
        @testset "structure_trait pairs $obs_idx" begin
            a, b = obstrait_categories[obs_idx]
            @test ChronoSim.ObservedState.structure_trait(a) == b
        end
    end
end
