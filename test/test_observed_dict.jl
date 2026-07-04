using ReTest
using ChronoSim
using ChronoSim.ObservedState

@testset "observed_dict notifications" begin
    # A parent sink recording (address, readwrite) pairs, so each test can
    # assert the exact notifications a dict operation emits. Mirrors the
    # ObsArrayListen pattern in test_observed_array.jl.
    struct DictListen
        seen::Vector{Any}
    end
    ChronoSim.ObservedState.observed_notify(dl::DictListen, address, readwrite) = push!(
        dl.seen, (address, readwrite)
    )

    @keyedby DictElem String begin
        value::Int
        label::String
    end

    prim_dict() = begin
        d = ObservedDict{String,Int,Member}()
        base = DictListen(Any[])
        ChronoSim.ObservedState.update_index(d._address, base, Member(:d))
        (d, base)
    end

    comp_dict() = begin
        d = ObservedDict{String,DictElem,Member}()
        base = DictListen(Any[])
        ChronoSim.ObservedState.update_index(d._address, base, Member(:d))
        (d, base)
    end

    @testset "observed_dict get on missing key reads that key" begin
        d, base = prim_dict()
        d["a"] = 1
        empty!(base.seen)
        @test get(d, "b", 99) == 99
        @test base.seen == [((Member(:d), "b"), :read)]
    end

    @testset "observed_dict get on present key reads that key" begin
        d, base = prim_dict()
        d["a"] = 1
        empty!(base.seen)
        @test get(d, "a", 99) == 1
        @test base.seen == [((Member(:d), "a"), :read)]
    end

    @testset "observed_dict get with callable default reads missing key" begin
        d, base = prim_dict()
        empty!(base.seen)
        @test get(() -> 42, d, "missing") == 42
        @test base.seen == [((Member(:d), "missing"), :read)]
    end

    @testset "observed_dict get! on missing key notifies read then write" begin
        d, base = prim_dict()
        empty!(base.seen)
        @test get!(d, "x", 7) == 7
        @test base.seen == [((Member(:d), "x"), :read), ((Member(:d), "x"), :write)]
    end

    @testset "observed_dict get! on present key reads without writing" begin
        d, base = prim_dict()
        d["x"] = 7
        empty!(base.seen)
        @test get!(d, "x", 100) == 7
        @test base.seen == [((Member(:d), "x"), :read)]
    end

    @testset "observed_dict get! with callable default reads then writes missing key" begin
        d, base = prim_dict()
        empty!(base.seen)
        @test get!(() -> 99, d, "newkey") == 99
        @test base.seen == [((Member(:d), "newkey"), :read), ((Member(:d), "newkey"), :write)]
    end

    @testset "observed_dict haskey reads the queried key when present" begin
        d, base = prim_dict()
        d["a"] = 1
        empty!(base.seen)
        @test haskey(d, "a") == true
        @test base.seen == [((Member(:d), "a"), :read)]
    end

    @testset "observed_dict haskey reads the queried key when absent" begin
        d, base = prim_dict()
        empty!(base.seen)
        @test haskey(d, "zzz") == false
        @test base.seen == [((Member(:d), "zzz"), :read)]
    end

    @testset "observed_dict pop! on compound value floods element and empties its address" begin
        d, base = comp_dict()
        d["k"] = DictElem(5, "five")
        elem = d["k"]
        empty!(base.seen)
        result = pop!(d, "k")
        @test result === elem
        @test !haskey(d.dict, "k")
        @test ((Member(:d), "k", Member(:value)), :write) in base.seen
        @test ((Member(:d), "k", Member(:label)), :write) in base.seen
        @test elem._address.container === nothing
    end

    @testset "observed_dict pop! on primitive value writes the removed key" begin
        d, base = prim_dict()
        d["k"] = 5
        empty!(base.seen)
        @test pop!(d, "k") == 5
        @test !haskey(d.dict, "k")
        @test base.seen == [((Member(:d), "k"), :write)]
    end

    @testset "observed_dict pop! on missing key throws KeyError" begin
        d, _ = prim_dict()
        @test_throws KeyError pop!(d, "nope")
        dc, _ = comp_dict()
        @test_throws KeyError pop!(dc, "nope")
    end

    @testset "observed_dict pop! with default returns default and reads missing key" begin
        d, base = prim_dict()
        empty!(base.seen)
        @test pop!(d, "absent", -1) == -1
        @test base.seen == [((Member(:d), "absent"), :read)]

        dc, basec = comp_dict()
        fallback = DictElem(0, "def")
        empty!(basec.seen)
        @test pop!(dc, "absent", fallback) === fallback
        @test basec.seen == [((Member(:d), "absent"), :read)]
    end

    @testset "observed_dict setindex! getindex delete! notifications unchanged" begin
        d, base = prim_dict()
        empty!(base.seen)
        d["a"] = 1
        @test base.seen == [((Member(:d), "a"), :write)]

        empty!(base.seen)
        @test d["a"] == 1
        @test base.seen == [((Member(:d), "a"), :read)]

        empty!(base.seen)
        delete!(d, "a")
        @test base.seen == [((Member(:d), "a"), :write)]

        # delete! on an absent key emits nothing, matching the _delete! guard.
        empty!(base.seen)
        delete!(d, "absent")
        @test isempty(base.seen)
    end
end
