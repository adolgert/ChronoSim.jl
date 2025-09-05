using ReTest
using ChronoSim
using ChronoSim.ObservedState

@testset "ObservedSet" begin
    struct ObsSetListen
        seen::Vector{Any}
    end
    ChronoSim.ObservedState.observed_notify(osl::ObsSetListen, address, readwrite) = push!(
        osl.seen, (address, readwrite)
    )

    @testset "ObservedSet push pull" begin
        set_stuff = ObservedSet{Int,ChronoSim.ObservedState.Member}()
        base = ObsSetListen(Any[])
        ChronoSim.ObservedState.update_index(set_stuff._address, base, Member(:myset))
        push!(set_stuff, 37)
        @test base.seen[1][1] == (Member(:myset),)
        @test base.seen[1][2] == :write
        @test length(set_stuff) == 1
        @test base.seen[2][2] == :read
        delete!(set_stuff, 37)
        @test base.seen[3][1] == (Member(:myset),)
        @test base.seen[3][2] == :write
        @test isempty(set_stuff)
        @test length(base.seen) == 4
        @test base.seen[end][2] == :read
        push!(set_stuff, 23)
        @test length(base.seen) == 5
        @test 23 ∈ set_stuff
        @test length(base.seen) == 6
        @test base.seen[end][2] == :read
        @test 24 ∉ set_stuff
        @test length(base.seen) == 7
        @test base.seen[end][2] == :read
        push!(set_stuff, 25, 26, 27, 28)
        @test length(base.seen) == 8
        @test base.seen[end][2] == :write
        retval = pop!(set_stuff, 999, 888)
        @test retval == 888
        @test length(base.seen) == 9
        @test base.seen[end][2] == :write
        retval = pop!(set_stuff, 28)
        @test retval == 28
        @test length(base.seen) == 10
        @test base.seen[end][2] == :write
        retval = pop!(set_stuff)
        @test retval ∈ (23, 24, 25, 26, 27)
        @test length(base.seen) == 11
        @test base.seen[end][2] == :write
    end
end  # ObservedSet
