using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: NextReactionMethod
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!
import ChronoSim: CheckInvariants, InvariantViolation, PolicyStack, module_invariants,
    find_policy, NoPolicy, clock_key, InitializeEvent

# A two-flag cell: `a` and `b`. The safety property is "a xor b": at most one is
# nonzero. Tick (fast) sets a=1 on a fresh cell; Corrupt (slow) sets b=1. When a
# cell has already been Ticked (a=1) and is then Corrupted (b=1) the invariant
# breaks, and the guilty write is exactly cell[idx].b.
module TwinFlag
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

const RATE_FAST = 100.0
const RATE_SLOW = 0.05

@keyedby FlagCell Int64 begin
    a::Int64
    b::Int64
end

@observedphysical FlagBoard begin
    cell::ObservedVector{FlagCell,Member}
end

function FlagBoard(n::Int)
    cells = ObservedArray{FlagCell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = FlagCell(0, 0)
    end
    return FlagBoard(cells)
end

struct Tick <: SimEvent
    idx::Int64
end
@precondition precondition(evt::Tick, state) = state.cell[evt.idx].a == 0
enable(::Tick, state, when) = (Exponential(1 / RATE_FAST), when)
fire!(evt::Tick, state, when, rng) = (state.cell[evt.idx].a = 1; nothing)

struct Corrupt <: SimEvent
    idx::Int64
end
@precondition precondition(evt::Corrupt, state) = state.cell[evt.idx].b == 0
enable(::Corrupt, state, when) = (Exponential(1 / RATE_SLOW), when)
fire!(evt::Corrupt, state, when, rng) = (state.cell[evt.idx].b = 1; nothing)

function init!(state, when, rng)
    for i in eachindex(state.cell)
        state.cell[i].a = 0
        state.cell[i].b = 0
    end
    return nothing
end

@invariant "a xor b" function (physical)
    all(c.a == 0 || c.b == 0 for c in physical.cell)
end

@invariant "counts nonnegative" function (physical)
    all(c.a >= 0 && c.b >= 0 for c in physical.cell)
end
end # module TwinFlag

using .TwinFlag: FlagBoard, Tick, Corrupt

# An empty module registers no invariants: constructing CheckInvariants errors.
module NoInvariants
using ChronoSim
end # module

# A scratch module whose invariant returns a non-Bool.
module BadInvariant
using ChronoSim
import ChronoSim: precondition, enable, fire!
@invariant "bad" physical -> 1
end # module

function _twin_sim(n, transitions; policy=NoPolicy(), observer=nothing, seed=1234)
    return SimulationFSM(
        FlagBoard(n), transitions;
        rng=Xoshiro(seed), sampler=NextReactionMethod(), key_type=Tuple,
        observer=observer, policy=policy,
    )
end

# Run to completion and return the thrown exception (or nothing).
function _catch_run(sim, initializer, stop=(p, i, e, w) -> false)
    try
        ChronoSim.run(sim, initializer, stop)
        return nothing
    catch e
        return e
    end
end

@testset "invariant macro registers def" begin
    defs = module_invariants(TwinFlag)
    @test length(defs) == 2
    @test defs[1].name == "a xor b"
    @test defs[2].name == "counts nonnegative"
    board = FlagBoard(2)
    @test defs[1].checker(board) isa Bool
    @test defs[1].statesym === :physical
    @test defs[1].body isa Expr
    @test defs[1].source isa LineNumberNode
    @test occursin("test_invariant.jl", String(defs[1].source.file))
end

@testset "invariant redeclaration overwrites in place" begin
    before = module_invariants(TwinFlag)
    @test length(before) == 2
    # Re-register "a xor b" with a different body; count and order must be stable.
    @eval TwinFlag @invariant "a xor b" function (physical)
        all(c.a >= 0 for c in physical.cell)
    end
    after = module_invariants(TwinFlag)
    @test length(after) == 2
    @test after[1].name == "a xor b"
    @test after[2].name == "counts nonnegative"
    # Restore the real body so later testsets in this file see the true invariant.
    @eval TwinFlag @invariant "a xor b" function (physical)
        all(c.a == 0 || c.b == 0 for c in physical.cell)
    end
end

@testset "invariant macro rejects bad shapes" begin
    @test_throws LoadError @eval @invariant "x" function (a, b)
        true
    end
    @test_throws LoadError @eval @invariant "x" (physical...) -> true
    @test_throws LoadError @eval @invariant "x" function f(physical)
        true
    end
    @test_throws LoadError @eval @invariant :notastring physical -> true
end

@testset "checkinvariants requires registered module" begin
    @test_throws ArgumentError CheckInvariants(NoInvariants)
end

@testset "passing invariants run silently and count fires" begin
    calls = Ref(0)
    obs = (p, when, evt, changed) -> (calls[] += 1; nothing)
    policy = CheckInvariants(TwinFlag)
    sim = _twin_sim(3, [Tick]; policy=policy, observer=obs, seed=1234)
    err = _catch_run(sim, TwinFlag.init!)
    @test err === nothing
    @test policy.fires == calls[] - 1
    @test policy.fires >= 1
end

@testset "violation carries the full payload" begin
    policy = CheckInvariants(TwinFlag)
    sim = _twin_sim(1, [Tick, Corrupt]; policy=policy, seed=1234)
    e = _catch_run(sim, TwinFlag.init!)
    @test e isa InvariantViolation
    @test e.name == "a xor b"
    @test e.step >= 1
    @test e.event == (:Corrupt, 1)
    @test e.when > 0
    @test e.guilty == [(Member(:cell), 1, Member(:b))]
    @test all(a in e.reads for a in e.guilty)
    @test all(a in e.changed for a in e.guilty)
    @test e.reproduced == true
    @test e.skeleton === nothing
    @test e.replay_command === nothing
end

@testset "violation at init has step zero" begin
    function corrupt_init!(state, when, rng)
        state.cell[1].a = 1
        state.cell[1].b = 1
        return nothing
    end
    policy = CheckInvariants(TwinFlag)
    sim = _twin_sim(1, [Tick, Corrupt]; policy=policy, seed=1234)
    e = _catch_run(sim, corrupt_init!)
    @test e isa InvariantViolation
    @test e.step == 0
    @test e.event == clock_key(InitializeEvent())
    @test e.replay_command === nothing
    @test e.skeleton === nothing
end

@testset "violation showerror text" begin
    policy = CheckInvariants(TwinFlag)
    sim = _twin_sim(1, [Tick, Corrupt]; policy=policy, seed=1234)
    e = _catch_run(sim, TwinFlag.init!)
    @test e isa InvariantViolation
    text = sprint(showerror, e)
    @test occursin("InvariantViolation: invariant \"a xor b\"", text)
    @test occursin("guilty", text)
    @test occursin("(cell, 1, ", text)
    @test occursin("replay", text)
    @test count(==('\n'), text) <= 30
end

@testset "composition attaches the skeleton prefix" begin
    rec = RecordSkeleton()
    policy = PolicyStack(rec, CheckInvariants(TwinFlag))
    sim = _twin_sim(1, [Tick, Corrupt]; policy=policy, seed=1234)
    e = _catch_run(sim, TwinFlag.init!)
    @test e isa InvariantViolation
    @test e.skeleton !== nothing
    @test length(e.skeleton.steps) == e.step
    @test e.replay_command == "replay(sim_factory, skeleton; upto=$(e.step - 1))"
end

@testset "non boolean invariant errors clearly" begin
    policy = CheckInvariants(BadInvariant)
    sim = _twin_sim(1, [Tick]; policy=policy, seed=1234)
    e = _catch_run(sim, TwinFlag.init!)
    @test e !== nothing
    @test !(e isa InvariantViolation)
    msg = sprint(showerror, e)
    @test occursin("bad", msg)
    @test occursin("not Bool", msg)
end
