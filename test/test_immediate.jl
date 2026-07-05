using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks: CombinedNextReaction
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!, isimmediate

# Regression fixture for the immediate-event changed-places merge
# (framework.jl modify_state!): an immediate Chain event fires inline whenever
# TimedTick puts `a` ahead of `b`, and its write to `b` must appear in the same
# observer changed_places set as the tick's write to `a`. Before the union! fix
# this path threw a MethodError (push! of a set into a set of tuples).
module ImmediateMerge
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!, isimmediate

@keyedby ChainCell Int64 begin
    a::Int64
    b::Int64
end

@observedphysical ChainBoard begin
    cell::ObservedVector{ChainCell,Member}
end

function ChainBoard(n::Int)
    cells = ObservedArray{ChainCell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = ChainCell(0, 0)
    end
    return ChainBoard(cells)
end

struct TimedTick <: SimEvent
    idx::Int64
end
@precondition precondition(evt::TimedTick, state) = state.cell[evt.idx].a >= 0
enable(::TimedTick, state, when) = (Exponential(1.0), when)
fire!(evt::TimedTick, state, when, rng) = (state.cell[evt.idx].a += 1; nothing)

struct Chain <: SimEvent
    idx::Int64
end
isimmediate(::Type{Chain}) = true
@precondition precondition(evt::Chain, state) =
    state.cell[evt.idx].a > state.cell[evt.idx].b
fire!(evt::Chain, state, when, rng) = (state.cell[evt.idx].b += 1; nothing)

function init!(state, when, rng)
    # Touch the state so deal_with_changes sees changed places and enables
    # the initial event set.
    state.cell[1].a = 0
    state.cell[1].b = 0
    return nothing
end
end # module

_addr_leaf(t) = (x = t[end]; x isa ChronoSim.Member ? x.name : Symbol(x))

@testset "immediate event changes merge into changed_places" begin
    changed_log = Vector{Vector{Tuple}}()
    observer = (p, when, evt, changed) -> begin
        evt isa ChronoSim.InitializeEvent && return nothing
        push!(changed_log, collect(Tuple, changed))
    end
    sim = SimulationFSM(
        ImmediateMerge.ChainBoard(1), [ImmediateMerge.TimedTick, ImmediateMerge.Chain];
        rng=Xoshiro(90210),
        sampler=CombinedNextReaction{Tuple,Float64}(),
        observer=observer,
    )
    ChronoSim.run(sim, ImmediateMerge.init!, (p, i, e, w) -> i > 5)

    @test length(changed_log) >= 5
    # The immediate Chain keeps b in lockstep with a.
    @test sim.physical.cell[1].b == sim.physical.cell[1].a
    @test sim.physical.cell[1].a >= 5
    # Every tick's changed set contains both the tick's write (a) and the
    # inline immediate event's write (b), merged element-wise.
    for changed in changed_log
        leaves = Set(_addr_leaf(t) for t in changed)
        @test :a in leaves
        @test :b in leaves
    end
end
