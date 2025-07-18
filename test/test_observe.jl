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
        (:(sim.board[ione].fval), :(:board, ione, :fval)),
        (:(state.board[ione, itwo].fval), :(:board, (ione, itwo), :fval)),
        (:(sim.agent[sone].arrow), :(:agent, sone, :arrow)),
        (
            :(sim.chess.board[ione, ithree, itwo].qval),
            :(:chess, :board, (ione, ithree, itwo), :qval),
        ),
        (:(pstate.flip[(sone, itwo)]), :(:flip, (sone, itwo))),
        (:(pstate.flip[tone]), :(:flip, tone)),
        (:(state.jug.places[tone]), :(:jug, :places, tone)),
        (:(sim.cnt), :((:cnt,))),
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
        vals::ObservedArray{OMRContained,1}
        cnt::Int64
    end

    physical = OMRPhysical(ObservedArray{OMRContained,1}([OMRContained(x) for x in 1:10]), 10)
    output = []
    what_read = capture_state_reads(physical) do 
        push!(output, @observe physical.cnt)
        fv = @observe physical.vals[3].fval
        push!(output, fv)
    end
    @test output[1] == physical.cnt
    @test output[2] == physical.vals[3].fval
    @test length(what_read.reads) == 2
    @test (:cnt,) in what_read.reads
    @test (:vals, 3, :fval) in what_read.reads

    wrote = capture_state_changes(physical) do
        incr = 0.125
        @observe physical.cnt = 12
        @observe physical.vals[7].fval = incr
    end
    @test length(wrote.changes) == 2
    @test (:cnt,) in wrote.changes
    @test (:vals, 7, :fval) in wrote.changes
end
