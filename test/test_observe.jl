using ReTest
using ChronoSim
using ChronoSim.ObservedState

@testset "observe access_to_placekey" begin
    sim = ()
    state = ()
    pstate = ()
    ione = 7
    itwo = 13
    ithree = 1
    sone = "hi"
    stwo = "there"
    tone = (4, 9)
    ttwo = (3, 6)

    testset = [
        (:(sim.board[ione].fval), :(Member(:board), ione, Member(:fval))),
        (:(state.board[ione, itwo].fval), :(Member(:board), (ione, itwo), Member(:fval))),
        (:(sim.agent[sone].arrow), :(Member(:agent), sone, Member(:arrow))),
        (
            :(sim.chess.board[ione, ithree, itwo].qval),
            :(Member(:chess), Member(:board), (ione, ithree, itwo), Member(:qval)),
        ),
        (:(pstate.flip[(sone, itwo)]), :(Member(:flip), (sone, itwo))),
        (:(pstate.flip[tone]), :(Member(:flip), tone)),
        (:(state.jug.places[tone]), :(Member(:jug), Member(:places), tone)),
        (:(sim.cnt), :((Member(:cnt),))),
    ]
    for (expr, expected) in testset
        @test ChronoSim.ObservedState.access_to_placekey(expr) == expected
    end
end

@testset "observe macro read" begin
    @keyedby OMRContained Int begin
        fval::Float64
    end
    @observedphysical OMRPhysical begin
        vals::ObservedArray{OMRContained,1,Member}
        cnt::Int64
    end

    physical = OMRPhysical(
        ObservedArray{OMRContained,1,Member}([OMRContained(x) for x in 1:10]), 10
    )
    output = []
    what_read = capture_state_reads(physical) do
        push!(output, @obsread physical.cnt)
        fv = @obsread physical.vals[3].fval
        push!(output, fv)
    end
    @test output[1] == physical.cnt
    @test output[2] == physical.vals[3].fval
    @test length(what_read.reads) == 2
    @test (Member(:cnt),) in what_read.reads
    @test (Member(:vals), 3, Member(:fval)) in what_read.reads

    wrote = capture_state_changes(physical) do
        incr = 0.125
        @obswrite physical.cnt = 12
        @obswrite physical.vals[7].fval = incr
    end
    @test length(wrote.changes) == 2
    @test (Member(:cnt),) in wrote.changes
    @test (Member(:vals), 7, Member(:fval)) in wrote.changes
end
