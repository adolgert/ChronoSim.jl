using ReTest
using ChronoSim
using ChronoSim.ObservedState
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

# Fixture module: a small keyed board exercising every construct the corpus of
# derived preconditions uses (field access, indexing, tuple keys, operators,
# whitelisted reads, @fragment helper calls, precondition-recursion, reducer
# over a generator, and a for/continue/|=/&= loop prelude), plus the deliberate
# refusal cases (an opaque call, a nested return).
module GuardBoard
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

@keyedby GCell Int64 begin
    a::Int64
    b::Int64
end

@keyedby GSlot Tuple{Int64,Symbol} begin
    a::Int64
end

@observedphysical GBoard begin
    cell::ObservedVector{GCell,Member}
    slot::ObservedDict{Tuple{Int64,Symbol},GSlot,Member}
end

function GBoard(cellvals::Vector{<:Tuple})
    cells = ObservedArray{GCell,Member}(undef, length(cellvals))
    for i in eachindex(cells)
        cells[i] = GCell(cellvals[i][1], cellvals[i][2])
    end
    slot = ObservedDict{Tuple{Int64,Symbol},GSlot,Member}()
    return GBoard(cells, slot)
end

@fragment both_positive(c) = c.a > 0 && c.b > 0

struct GEvt <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::GEvt, state)
    cell = state.cell[evt.idx]
    return cell.a >= 1 && (cell.b == 2 || cell.b == 3) && both_positive(cell)
end
enable(::GEvt, state, when) = (Exponential(1.0), when)
fire!(::GEvt, state, when, rng) = nothing

struct GKey <: SimEvent
    f::Int64
end
@precondition function precondition(evt::GKey, state)
    return haskey(state.slot, (evt.f, :up)) && state.slot[(evt.f, :up)].a > 0
end
enable(::GKey, state, when) = (Exponential(1.0), when)
fire!(::GKey, state, when, rng) = nothing

struct GLoop <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::GLoop, state)
    cell = state.cell[evt.idx]
    acc = true
    flag = false
    for k in eachindex(state.cell)
        c = state.cell[k]
        c.a > 0 || continue
        flag |= c.b > 0
        acc &= c.a >= 1
    end
    return cell.a >= 0 && flag && acc
end
enable(::GLoop, state, when) = (Exponential(1.0), when)
fire!(::GLoop, state, when, rng) = nothing

struct GBad <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::GBad, state)
    return state.cell[evt.idx].a >= 0 && sqrt(2.0) > 1.0
end
enable(::GBad, state, when) = (Exponential(1.0), when)
fire!(::GBad, state, when, rng) = nothing

struct GRet <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::GRet, state)
    cell = state.cell[evt.idx]
    if cell.a > 100
        return false
    end
    return cell.a >= 0
end
enable(::GRet, state, when) = (Exponential(1.0), when)
fire!(::GRet, state, when, rng) = nothing

struct GAny <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::GAny, state)
    cell = state.cell[evt.idx]
    return cell.a >= 0 && any(c.b > 0 for c in state.cell)
end
enable(::GAny, state, when) = (Exponential(1.0), when)
fire!(::GAny, state, when, rng) = nothing

struct GRec <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::GRec, state)
    return precondition(GEvt(evt.idx), state)
end
enable(::GRec, state, when) = (Exponential(1.0), when)
fire!(::GRec, state, when, rng) = nothing

# Hand-written twin: a plain precondition method, never registered by
# @precondition. guard_clauses must refuse it with :no_precondition.
struct GPlain <: SimEvent
    idx::Int64
end
precondition(evt::GPlain, state) = state.cell[evt.idx].a >= 0
enable(::GPlain, state, when) = (Exponential(1.0), when)
fire!(::GPlain, state, when, rng) = nothing

end # module GuardBoard

using .GuardBoard: GBoard, GEvt, GKey, GLoop, GBad, GRet, GAny, GRec, GPlain, GSlot

@testset "guard_clauses hand computed values" begin
    state = GBoard([(1, 5)])
    res = guard_clauses(GEvt(1), state)
    @test res == [
        ("cell.a >= 1", true),
        ("cell.b == 2 || cell.b == 3", false),
        ("both_positive(cell)", true),
    ]
end

@testset "guard_clauses all true equals precondition" begin
    state = GBoard([(1, 2)])
    res = guard_clauses(GEvt(1), state)
    @test all(v === true for (_, v) in res)
    @test precondition(GEvt(1), state) == true
end

@testset "guard_clauses exception as value" begin
    state = GBoard([(1, 2)])            # slot dict is empty; (9, :up) absent
    res = guard_clauses(GKey(9), state)
    @test res[1][2] === false
    @test res[2][2] isa KeyError
    @test precondition(GKey(9), state) == false
end

@testset "guard_clauses loop prelude" begin
    # cells all have a>0 (so acc stays true) but b==0 (so flag stays false).
    state = GBoard([(2, 0), (3, 0), (1, 0)])
    res = guard_clauses(GLoop(1), state)
    @test res == [
        ("cell.a >= 0", true),
        ("flag", false),
        ("acc", true),
    ]
end

@testset "guard_clauses unsupported call" begin
    state = GBoard([(1, 2)])
    err = try
        guard_clauses(GBad(1), state)
        nothing
    catch e
        e
    end
    @test err isa GuardEvalError
    @test err.kind == :unsupported_call
    @test occursin("sqrt", err.construct)
end

@testset "guard_clauses early return" begin
    state = GBoard([(200, 0)])          # cell.a > 100 triggers the nested return
    err = try
        guard_clauses(GRet(1), state)
        nothing
    catch e
        e
    end
    @test err isa GuardEvalError
    @test err.kind == :early_return
end

@testset "guard_clauses unregistered event" begin
    state = GBoard([(1, 2)])
    err = try
        guard_clauses(GPlain(1), state)
        nothing
    catch e
        e
    end
    @test err isa GuardEvalError
    @test err.kind == :no_precondition
    @test occursin("@conditionsfor", err.message)
end

@testset "guard_clauses does not mutate state" begin
    state = GBoard([(1, 2)])
    result = capture_state_changes(state) do
        guard_clauses(GEvt(1), state)
    end
    @test isempty(result.changes)
    v1 = guard_clauses(GEvt(1), state)
    v2 = guard_clauses(GEvt(1), state)
    @test v1 == v2
end

@testset "guard_clauses reducer and recursion" begin
    state = GBoard([(1, 5), (0, 0)])
    resany = guard_clauses(GAny(1), state)
    @test [v for (_, v) in resany] == [true, true]      # cell.a>=0 and some b>0
    resrec = guard_clauses(GRec(1), state)
    @test length(resrec) == 1
    @test resrec[1][2] == precondition(GEvt(1), state)
end
