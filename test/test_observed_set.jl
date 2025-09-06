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

    @testset "ObservedSet push pull invector" begin
        set_stuff = ObservedSet{Float64,Int}()
        base = ObsSetListen(Any[])
        ChronoSim.ObservedState.update_index(set_stuff._address, base, 3)
        push!(set_stuff, 3.14)
        @test base.seen[1][1] == (3,)
        @test base.seen[1][2] == :write
    end

    @testset "ObservedSet push pull for string" begin
        set_stuff = ObservedSet{Float64,String}()
        base = ObsSetListen(Any[])
        ChronoSim.ObservedState.update_index(set_stuff._address, base, "fred")
        push!(set_stuff, 3.14)
        @test base.seen[1][1] == ("fred",)
        @test base.seen[1][2] == :write
    end

    @testset "ObservedSet push pull for struct" begin
        struct SetContents
            i::Int
        end

        set_stuff = ObservedSet{SetContents,Symbol}()
        base = ObsSetListen(Any[])
        ChronoSim.ObservedState.update_index(set_stuff._address, base, :cardinal)
        push!(set_stuff, SetContents(37))
        @test base.seen[1][1] == (:cardinal,)
        @test base.seen[1][2] == :write
    end

    @testset "ObservedSet push pull INT" begin
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

    @testset "ObservedSet empty! function" begin
        set_stuff = ObservedSet{Int,ChronoSim.ObservedState.Member}()
        base = ObsSetListen(Any[])
        ChronoSim.ObservedState.update_index(set_stuff._address, base, Member(:myset))
        push!(set_stuff, 1, 2, 3, 4, 5)
        @test length(set_stuff) == 5
        @test length(base.seen) == 2  # push! write + length read
        empty!(set_stuff)
        @test isempty(set_stuff)
        @test length(base.seen) == 4  # empty! write + isempty read
        @test base.seen[3][2] == :write  # empty! operation
        @test base.seen[4][2] == :read   # isempty check
    end

    @testset "ObservedSet mutating set operations" begin
        set_stuff = ObservedSet{Int,ChronoSim.ObservedState.Member}()
        base = ObsSetListen(Any[])
        ChronoSim.ObservedState.update_index(set_stuff._address, base, Member(:myset))
        push!(set_stuff, 1, 2, 3)
        @test length(base.seen) == 1  # push! write

        union!(set_stuff, [4, 5])
        @test length(base.seen) == 2  # + union! write
        @test base.seen[2][2] == :write
        @test 4 ∈ set_stuff && 5 ∈ set_stuff
        @test length(base.seen) == 4  # + 2 reads from ∈ checks

        intersect!(set_stuff, [1, 2, 4])
        @test length(base.seen) == 5  # + intersect! write
        @test base.seen[5][2] == :write
        @test 3 ∉ set_stuff && 5 ∉ set_stuff
        @test 1 ∈ set_stuff && 2 ∈ set_stuff && 4 ∈ set_stuff
        @test length(base.seen) == 10 # + 5 reads from membership checks

        setdiff!(set_stuff, [1])
        @test length(base.seen) == 11 # + setdiff! write
        @test base.seen[11][2] == :write
        @test 1 ∉ set_stuff
        @test 2 ∈ set_stuff && 4 ∈ set_stuff
        @test length(base.seen) == 14 # + 3 reads from membership checks

        symdiff!(set_stuff, [2, 6])
        @test length(base.seen) == 15 # + symdiff! write
        @test base.seen[15][2] == :write
        @test 2 ∉ set_stuff && 6 ∈ set_stuff
        @test 4 ∈ set_stuff
        @test length(base.seen) == 18 # + 3 reads from membership checks
    end

    @testset "ObservedSet non-mutating set operations" begin
        set_stuff = ObservedSet{Int,ChronoSim.ObservedState.Member}()
        base = ObsSetListen(Any[])
        ChronoSim.ObservedState.update_index(set_stuff._address, base, Member(:myset))
        push!(set_stuff, 1, 2, 3)
        @test length(base.seen) == 1  # push! write

        result = union(set_stuff, [4, 5])
        @test result isa Set{Int}
        @test result == Set([1, 2, 3, 4, 5])
        @test length(base.seen) == 2  # + union read
        @test base.seen[2][2] == :read

        result = intersect(set_stuff, [2, 3, 4])
        @test result isa Set{Int}
        @test result == Set([2, 3])
        @test length(base.seen) == 3  # + intersect read
        @test base.seen[3][2] == :read

        result = setdiff(set_stuff, [2])
        @test result isa Set{Int}
        @test result == Set([1, 3])
        @test length(base.seen) == 4  # + setdiff read
        @test base.seen[4][2] == :read

        result = symdiff(set_stuff, [3, 4])
        @test result isa Set{Int}
        @test result == Set([1, 2, 4])
        @test length(base.seen) == 5  # + symdiff read
        @test base.seen[5][2] == :read
    end

    @testset "ObservedSet issubset functionality" begin
        set_stuff = ObservedSet{Int,ChronoSim.ObservedState.Member}()
        base = ObsSetListen(Any[])
        ChronoSim.ObservedState.update_index(set_stuff._address, base, Member(:myset))
        push!(set_stuff, 1, 2, 3)

        # Test ObservedSet ⊆ regular collection
        @test issubset(set_stuff, [1, 2, 3, 4])
        @test base.seen[end][2] == :read
        @test !issubset(set_stuff, [1, 2])
        @test base.seen[end][2] == :read

        # Test regular collection ⊆ ObservedSet
        other_base = ObsSetListen(Any[])
        other_set = ObservedSet{Int,ChronoSim.ObservedState.Member}()
        ChronoSim.ObservedState.update_index(other_set._address, other_base, Member(:otherset))
        push!(other_set, 1, 2, 3, 4)

        @test issubset([1, 2], other_set)
        @test other_base.seen[end][2] == :read
        @test !issubset([1, 5], other_set)
        @test other_base.seen[end][2] == :read

        # Test ObservedSet ⊆ ObservedSet
        @test issubset(set_stuff, other_set)
        @test base.seen[end][2] == :read
        @test other_base.seen[end][2] == :read
    end

    @testset "ObservedSet equality and hash operations" begin
        set1 = ObservedSet{Int,Member}()
        set2 = ObservedSet{Int,Member}()
        regular_set = Set([1, 2, 3])

        push!(set1, 1, 2, 3)
        push!(set2, 3, 2, 1)  # Same elements, different order

        @test set1 == set2

        @test set1 == regular_set
        @test regular_set == set1

        @test hash(set1) == hash(set2)
        @test hash(set1) == hash(regular_set)

        push!(set2, 4)
        @test set1 != set2
        @test hash(set1) != hash(set2)
    end

    @testset "ObservedSet eltype and display methods" begin
        set_stuff = ObservedSet{String,ChronoSim.ObservedState.Member}()

        @test eltype(set_stuff) == String

        io = IOBuffer()
        show(io, set_stuff)
        output = String(take!(io))
        @test occursin("Set", output)

        io = IOBuffer()
        show(io, MIME"text/plain"(), set_stuff)
        output = String(take!(io))
        @test occursin("Set", output)

        push!(set_stuff, "hello", "world")
        io = IOBuffer()
        show(io, set_stuff)
        output = String(take!(io))
        @test occursin("hello", output) || occursin("world", output)
    end
end  # ObservedSet
