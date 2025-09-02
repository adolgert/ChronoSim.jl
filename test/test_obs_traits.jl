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
        obs_name = string(obstrait_categories[obs_idx][1])
        @testset "structure_trait pairs $obs_name" begin
            a, b = obstrait_categories[obs_idx]
            @test ChronoSim.ObservedState.structure_trait(a) == b
        end
    end

    @testset "Address smoke" begin
        addr = Address{Int}()
        @test isnothing(addr.container)
        mutable struct ParentType
            changed
            readwrite
        end
        ChronoSim.ObservedState.observed_notify(pt::ParentType, changed, rw) = begin
            pt.changed = changed
            pt.readwrite = rw
        end
        pt = ParentType(nothing, nothing)
        # Notice that if the index is a single value, it should be a tuple with a single value.
        ChronoSim.ObservedState.address_notify(addr, (), :write)
        @test isnothing(pt.changed)
        ChronoSim.ObservedState.update_index(addr, pt, 27)
        ChronoSim.ObservedState.address_notify(addr, (), :write)
        @test pt.changed == (27,)
        ChronoSim.ObservedState.address_notify(addr, ("changed utterly",), :write)
        @test pt.changed == (27, "changed utterly")
        @test pt.readwrite == :write
        empty!(addr)
        # Shouldn't do anything once the address is emptied.
        ChronoSim.ObservedState.address_notify(addr, (:fellow,), :read)
        @test pt.readwrite == :write
    end

    @testset "Address show" begin
        # Test with empty Address
        addr1 = Address{Int}()
        @test startswith(string(addr1), "Address(nothing")

        # Test with container but undefined index
        addr2 = Address{String}()
        addr2.container = "test_container"
        @test string(addr2) == "Address(contained, undef)"

        # Test with both container and index defined
        addr3 = Address{Symbol}()
        addr3.container = "test_container"
        addr3.index = :field_name
        @test string(addr3) == "Address(contained, field_name)"
    end
end
