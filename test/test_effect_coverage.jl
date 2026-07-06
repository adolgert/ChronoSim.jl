using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: CombinedNextReaction
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!, isimmediate

# Phase 2: the CheckEffects runtime oracle (changed ⊆ declared). The seeded-bug
# fixtures hide a write behind a non-!, non-@fragment helper the walker cannot
# see; the oracle catches it at runtime with the right classification.

module OracleModel
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: CombinedNextReaction
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

@keyedby Cell Int64 begin
    a::Int64
    b::Int64
end

@observedphysical Board begin
    cell::ObservedVector{Cell,Member}
    other::ObservedVector{Cell,Member}
    n::Int64
end

function Board(n::Int)
    cell = ObservedArray{Cell,Member}(undef, n)
    other = ObservedArray{Cell,Member}(undef, n)
    for i in 1:n
        cell[i] = Cell(0, 0)
        other[i] = Cell(0, 0)
    end
    return Board(cell, other, n)
end

# Conforming event.
struct Wake <: SimEvent; idx::Int64; end
@precondition precondition(evt::Wake, state) = state.cell[evt.idx].a == 0
enable(::Wake, state, when) = (Exponential(1.0), when)
@fire function fire!(evt::Wake, state, when, rng)
    state.cell[evt.idx].a = 1
end

# A non-!, non-@fragment helper that mutates a container NO WriteSpec names.
sneaky_missing(state, i) = (state.other[i].a = 99; nothing)
struct SneakyMissing <: SimEvent; idx::Int64; end
@fire function fire!(evt::SneakyMissing, state, when, rng)
    state.cell[evt.idx].a = 1        # the only declared write
    sneaky_missing(state, evt.idx)   # hidden write to :other, undeclared
end

# A hidden write to a DIFFERENT LEAF of a covered container.
sneaky_shape(state, i) = (state.cell[i].b = 42; nothing)
struct SneakyShape <: SimEvent; idx::Int64; end
@fire function fire!(evt::SneakyShape, state, when, rng)
    state.cell[evt.idx].a = 1
    sneaky_shape(state, evt.idx)
end

# An @fire'd init event with a hidden write (for the on_init path).
struct BadInit <: SimEvent; end
@fire function fire!(evt::BadInit, state, when, rng)
    state.cell[1].a = 1
    sneaky_missing(state, 1)
end

# A conforming init that only writes cell (for the passing run).
function good_init(state, when, rng)
    for i in 1:state.n
        state.cell[i].a = 0
    end
    return nothing
end
end # module OracleModel

# Keyed ObservedDict mutations: delete!/pop! notify (d, key) for a primitive
# element and per-element-field for a compound one; get! writes c[k] on a miss.
# The walker must declare BOTH the container leaf and the keyed subtree so the
# oracle never false-positives on these (reviewer-reproduced bug class).
module OracleDict
using ChronoSim
using ChronoSim.ObservedState
import ChronoSim: precondition, generators, enable, fire!

@keyedby Elem Int64 begin
    a::Int64
    b::Int64
end

@observedphysical DBoard begin
    prim::ObservedDict{Int64,Int64,Member}
    comp::ObservedDict{Int64,Elem,Member}
end

function DBoard()
    prim = ObservedDict{Int64,Int64,Member}()
    comp = ObservedDict{Int64,Elem,Member}()
    prim[1] = 10
    prim[2] = 20
    comp[1] = Elem(1, 1)
    comp[2] = Elem(2, 2)
    return DBoard(prim, comp)
end

struct DelPrim <: SimEvent; k::Int64; end
@fire fire!(evt::DelPrim, state, when, rng) = delete!(state.prim, evt.k)

struct PopPrim <: SimEvent; k::Int64; end
@fire fire!(evt::PopPrim, state, when, rng) = pop!(state.prim, evt.k)

struct GetPrim <: SimEvent; k::Int64; end
@fire fire!(evt::GetPrim, state, when, rng) = get!(state.prim, evt.k, 7)

struct DelComp <: SimEvent; k::Int64; end
@fire fire!(evt::DelComp, state, when, rng) = delete!(state.comp, evt.k)

struct PopComp <: SimEvent; k::Int64; end
@fire fire!(evt::PopComp, state, when, rng) = pop!(state.comp, evt.k)

struct GetComp <: SimEvent; k::Int64; end
@fire fire!(evt::GetComp, state, when, rng) = get!(state.comp, evt.k, Elem(9, 9))
end # module OracleDict

# Immediate-event fixture (mirrors test_immediate.jl) with @fire on both events.
module OracleImmediate
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

struct TimedTick <: SimEvent; idx::Int64; end
@precondition precondition(evt::TimedTick, state) = state.cell[evt.idx].a >= 0
enable(::TimedTick, state, when) = (Exponential(1.0), when)
@fire function fire!(evt::TimedTick, state, when, rng)
    state.cell[evt.idx].a += 1
end

struct Chain <: SimEvent; idx::Int64; end
isimmediate(::Type{Chain}) = true
@precondition precondition(evt::Chain, state) = state.cell[evt.idx].a > state.cell[evt.idx].b
@fire function fire!(evt::Chain, state, when, rng)
    state.cell[evt.idx].b += 1
end

function init!(state, when, rng)
    state.cell[1].a = 0
    state.cell[1].b = 0
    return nothing
end
end # module OracleImmediate

const OM = OracleModel
const OI = OracleImmediate

# Fire an event and return the captured changed-place set.
function _fire_changes(T, args...; n=3)
    board = OM.Board(n)
    r = ChronoSim.capture_state_changes(board) do
        fire!(T(args...), board, 0.0, Xoshiro(1))
    end
    return board, r.changes
end

@testset "oracle passes a conforming fire" begin
    _, changes = _fire_changes(OM.Wake, 1)
    chk = ChronoSim.CheckEffects([OM.Wake])
    @test ChronoSim.verify_write_coverage(OM.Wake, changes, chk) === nothing
end

@testset "oracle passes a conforming full run" begin
    board = OM.Board(3)
    sim = SimulationFSM(board, [OM.Wake]; rng=Xoshiro(7),
        sampler=CombinedNextReaction{Tuple,Float64}(),
        policy=ChronoSim.CheckEffects([OM.Wake]))
    ChronoSim.run(sim, OM.good_init, (p, i, e, w) -> i > 5)
    @test sim.when >= 0.0
end

@testset "seeded hidden write throws missing_container (definition of done)" begin
    _, changes = _fire_changes(OM.SneakyMissing, 1)
    chk = ChronoSim.CheckEffects([OM.SneakyMissing])
    err = @test_throws ChronoSim.EffectCoverageError ChronoSim.verify_write_coverage(
        OM.SneakyMissing, changes, chk)
    @test err.value.classification === :missing_container
    @test err.value.address == (Member(:other), 1, Member(:a))
end

@testset "seeded shape miss throws shape_mismatch" begin
    _, changes = _fire_changes(OM.SneakyShape, 1)
    chk = ChronoSim.CheckEffects([OM.SneakyShape])
    err = @test_throws ChronoSim.EffectCoverageError ChronoSim.verify_write_coverage(
        OM.SneakyShape, changes, chk)
    @test err.value.classification === :shape_mismatch
    @test err.value.address == (Member(:cell), 1, Member(:b))
end

@testset "unannotated event types are skipped" begin
    # An event without an effect_spec passes regardless of what it changed.
    _, changes = _fire_changes(OM.SneakyMissing, 1)
    chk = ChronoSim.CheckEffects([OM.Wake])
    @test ChronoSim.verify_write_coverage(ChronoSim.InitializeEvent, changes, chk) === nothing
end

@testset "oracle checks the init event (on_init)" begin
    board = OM.Board(3)
    sim = SimulationFSM(board, [OM.Wake]; rng=Xoshiro(9),
        sampler=CombinedNextReaction{Tuple,Float64}(),
        policy=ChronoSim.CheckEffects([OM.Wake]))
    err = @test_throws ChronoSim.EffectCoverageError ChronoSim.run(
        sim, OM.BadInit(), (p, i, e, w) -> i > 3)
    @test err.value.classification === :missing_container
end

@testset "immediate event writes are attributed under the union" begin
    # With Chain (immediate) in the CheckEffects list, its write to b is unioned in
    # and the postfire check on TimedTick passes.
    board = OI.ChainBoard(1)
    sim = SimulationFSM(board, [OI.TimedTick, OI.Chain]; rng=Xoshiro(90210),
        sampler=CombinedNextReaction{Tuple,Float64}(),
        policy=ChronoSim.CheckEffects([OI.TimedTick, OI.Chain]))
    ChronoSim.run(sim, OI.init!, (p, i, e, w) -> i > 5)
    @test board.cell[1].b == board.cell[1].a

    # Drop Chain from the union: the immediate write to b is now undeclared and the
    # postfire check on TimedTick throws.
    board2 = OI.ChainBoard(1)
    sim2 = SimulationFSM(board2, [OI.TimedTick, OI.Chain]; rng=Xoshiro(90210),
        sampler=CombinedNextReaction{Tuple,Float64}(),
        policy=ChronoSim.CheckEffects([OI.TimedTick]))   # Chain excluded
    err = @test_throws ChronoSim.EffectCoverageError ChronoSim.run(
        sim2, OI.init!, (p, i, e, w) -> i > 5)
    @test err.value.classification === :shape_mismatch
end

@testset "keyed dict delete!/pop!/get! declare both container and keyed specs" begin
    for (T, op) in ((OracleDict.DelPrim, :delete), (OracleDict.PopPrim, :pop),
                    (OracleDict.GetPrim, :get!))
        es = ChronoSim.effect_spec(T)
        @test length(es.writes) == 2
        leaf = findfirst(w -> ChronoSim.write_mask(w) == (Member(:prim),), es.writes)
        keyed = findfirst(w -> ChronoSim.write_mask(w) ==
                               (Member(:prim), ChronoSim.MEMBERINDEX), es.writes)
        @test leaf !== nothing && keyed !== nothing
        @test !es.writes[leaf].subtree
        @test es.writes[keyed].subtree
        @test es.writes[keyed].op === op
        @test es.writes[keyed].indices == Any[ChronoSim.FieldBinding(:k)] ||
              es.writes[keyed].indices[1] isa ChronoSim.FieldBinding
    end
    # get! also records the per-key read (its miss path is absence-dependent).
    esg = ChronoSim.effect_spec(OracleDict.GetPrim)
    @test any(r -> ChronoSim.placekey_mask_index(r.matchstr) ==
                   (Member(:prim), ChronoSim.MEMBERINDEX), esg.reads)
end

# Fire T on a fresh DBoard and check the oracle against the REAL captured changes.
function _dict_oracle_pass(T, k)
    board = OracleDict.DBoard()
    r = ChronoSim.capture_state_changes(board) do
        fire!(T(k), board, 0.0, Xoshiro(1))
    end
    chk = ChronoSim.CheckEffects([T])
    return ChronoSim.verify_write_coverage(T, r.changes, chk)
end

@testset "oracle passes keyed dict mutations (primitive and compound elements)" begin
    # Primitive: delete!/pop! notify (prim, k); get! miss notifies (prim, k).
    @test _dict_oracle_pass(OracleDict.DelPrim, 1) === nothing
    @test _dict_oracle_pass(OracleDict.PopPrim, 2) === nothing
    @test _dict_oracle_pass(OracleDict.GetPrim, 99) === nothing   # miss path writes
    @test _dict_oracle_pass(OracleDict.GetPrim, 1) === nothing    # hit path: read only
    # Compound: delete!/pop! notify per-element-field (comp, k, a)/(comp, k, b);
    # get! miss inserts a compound element (notify_all per field).
    @test _dict_oracle_pass(OracleDict.DelComp, 1) === nothing
    @test _dict_oracle_pass(OracleDict.PopComp, 2) === nothing
    @test _dict_oracle_pass(OracleDict.GetComp, 99) === nothing
end

# Absent-oracle hot path (1a test_policy.jl precedent): the postfire hook with the
# default NoPolicy compiles to nothing and allocates nothing.
function _postfire_loop(sim, n)
    total = 0
    for i in 1:n
        ChronoSim.on_postfire(sim.policy, sim, nothing, nothing, 0.0, nothing)
        total += i
    end
    return total
end

@testset "postfire hook is allocation free when CheckEffects is absent" begin
    board = OM.Board(1)
    sim = SimulationFSM(board, [OM.Wake]; rng=Xoshiro(3),
        sampler=CombinedNextReaction{Tuple,Float64}())
    _postfire_loop(sim, 1)     # warmup / compile
    @test @allocated(_postfire_loop(sim, 100_000)) == 0
end

@testset "showerror is bounded and greppable" begin
    _, changes = _fire_changes(OM.SneakyMissing, 1)
    chk = ChronoSim.CheckEffects([OM.SneakyMissing])
    err = try
        ChronoSim.verify_write_coverage(OM.SneakyMissing, changes, chk)
        nothing
    catch e
        e
    end
    msg = sprint(showerror, err)
    @test occursin("EffectCoverageError", msg)
    @test occursin("missing_container", msg)
    @test occursin("SneakyMissing", msg)
    @test count(==('\n'), msg) <= 30
end
