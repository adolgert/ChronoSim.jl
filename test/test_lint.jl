using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: CombinedNextReaction
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

# Phase 3: footprint lints. The kernel case-table tests are the core (every row of
# the design's S/K tables gets an assertion); the fixture models exercise @guard,
# lint edge computation, enumeration, the allowlist, and static⊇dynamic harvest.

using ChronoSim: AddressPattern, masks_intersect, _intersect_verdict, LintEdge,
    LintReport, LintAllow, LintFailure, assert_lint_clean, warnings, print_lint,
    LintHarvest, static_covers_dynamic, guard_spec
using ChronoSim: Member, MEMBERINDEX, FieldBinding, LiteralIndex, TaintedIndex, TupleIndex

const _M = Member
const _IX = MEMBERINDEX
_ap(mask, idxs; subtree=false) = AddressPattern(mask, Any[idxs...], subtree)

########################### Fixture models ###########################

module LintFix
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

@keyedby Cell Int64 begin
    a::Int64
    b::Int64
end

@observedphysical Grid begin
    cell::ObservedVector{Cell,Member}
    d::ObservedDict{Int64,Cell,Member}
    n::Int64
    pp::Param{Int64}
end

function Grid(ncell::Int)
    cells = ObservedArray{Cell,Member}(undef, ncell)
    for i in eachindex(cells)
        cells[i] = Cell(0, 0)
    end
    return Grid(cells, ObservedDict{Int64,Cell,Member}(), 0, 7)
end

# WA: writes cell.a, guards on cell.b, hand-written trigger on cell.b.
struct WA <: SimEvent
    i::Int64
end
@fire function fire!(evt::WA, s, when, rng)
    s.cell[evt.i].a = 1
end
@guard function precondition(evt::WA, s)
    return s.cell[evt.i].b == 0
end
@conditionsfor WA begin
    @reactto changed(cell[j].b) do s
        generate(WA(j))
    end
end

# WB: pure writer of cell.a (for the write→write race).
struct WB <: SimEvent
    i::Int64
end
@fire function fire!(evt::WB, s, when, rng)
    s.cell[evt.i].a = 2
end

# RG: hand-written guard reader of cell.a with a WRONG trigger (cell.b) — the
# write of cell.a by WA/WB is uncovered, so RG warns.
struct RG <: SimEvent
    i::Int64
end
@guard function precondition(evt::RG, s)
    return s.cell[evt.i].a > 0
end
@conditionsfor RG begin
    @reactto changed(cell[j].b) do s
        generate(RG(j))
    end
end

# Der: derived reader of cell.a — its trigger IS its read mask, so never warns.
struct Der <: SimEvent
    i::Int64
end
@precondition function precondition(evt::Der, s)
    return s.cell[evt.i].a > 0
end

# ZeroG: zero-read guard.
struct ZeroG <: SimEvent
    i::Int64
end
@guard function precondition(evt::ZeroG, s)
    return true
end

# WholeG: whole-container read of the dict.
struct WholeG <: SimEvent
    i::Int64
end
@guard function precondition(evt::WholeG, s)
    return length(s.d) > 0
end

# Fragment + recursion.
@fragment readb(cell) = cell.b
struct Base1 <: SimEvent
    i::Int64
end
@guard function precondition(evt::Base1, s)
    return s.cell[evt.i].a > 0
end
struct Rec1 <: SimEvent
    i::Int64
end
@guard function precondition(evt::Rec1, s)
    return precondition(Base1(evt.i), s) && readb(s.cell[evt.i]) == 0
end

# Enumeration fixtures: literal-indexed writer vs @domain-guarded readers.
struct LitW <: SimEvent end
@fire function fire!(evt::LitW, s, when, rng)
    s.cell[1].a = 5
end
struct DomEmpty <: SimEvent
    i::Int64
end
@guard function precondition(evt::DomEmpty, s)
    return s.cell[evt.i].a > 0
end
@domain DomEmpty.i = 2:3
struct DomFull <: SimEvent
    i::Int64
end
@guard function precondition(evt::DomFull, s)
    return s.cell[evt.i].a > 0
end
@domain DomFull.i = 1:3
end # module LintFix

# Seeded missed-trigger bug: Dispatch writes elevator.direction, Stop reads it, but
# Stop's @conditionsfor triggers only on doors_open (the historical StopElevator bug).
module SeededBug
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

@enum Dir up down stat

@keyedby Elevator Int64 begin
    floor::Int64
    direction::Dir
    doors_open::Bool
end
@observedphysical Sys begin
    elevator::ObservedVector{Elevator,Member}
    floor_cnt::Int64
end
function Sys(n::Int)
    e = ObservedArray{Elevator,Member}(undef, n)
    for i in eachindex(e)
        e[i] = Elevator(1, stat, false)
    end
    return Sys(e, 3)
end

struct Dispatch <: SimEvent
    i::Int64
end
@guard function precondition(evt::Dispatch, s)
    return s.elevator[evt.i].floor > 0
end
@fire function fire!(evt::Dispatch, s, when, rng)
    s.elevator[evt.i].direction = up
end
@conditionsfor Dispatch begin
    @reactto changed(elevator[i].floor) do s
        generate(Dispatch(i))
    end
end

struct Stop <: SimEvent
    i::Int64
end
@guard function precondition(evt::Stop, s)
    e = s.elevator[evt.i]
    return e.direction != stat && !e.doors_open
end
@fire function fire!(evt::Stop, s, when, rng)
    s.elevator[evt.i].doors_open = true
end
# BUG: no trigger on elevator[i].direction, only on doors_open.
@conditionsfor Stop begin
    @reactto changed(elevator[i].doors_open) do s
        generate(Stop(i))
    end
end
end # module SeededBug

# Same as SeededBug but Stop reacts to fired(Dispatch(i)) — the edge is covered.
module SeededFixed
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

@enum Dir up down stat
@keyedby Elevator Int64 begin
    floor::Int64
    direction::Dir
    doors_open::Bool
end
@observedphysical Sys begin
    elevator::ObservedVector{Elevator,Member}
    floor_cnt::Int64
end
function Sys(n::Int)
    e = ObservedArray{Elevator,Member}(undef, n)
    for i in eachindex(e)
        e[i] = Elevator(1, stat, false)
    end
    return Sys(e, 3)
end
struct Dispatch <: SimEvent
    i::Int64
end
@guard function precondition(evt::Dispatch, s)
    return s.elevator[evt.i].floor > 0
end
@fire function fire!(evt::Dispatch, s, when, rng)
    s.elevator[evt.i].direction = up
end
@conditionsfor Dispatch begin
    @reactto changed(elevator[i].floor) do s
        generate(Dispatch(i))
    end
end
struct Stop <: SimEvent
    i::Int64
end
@guard function precondition(evt::Stop, s)
    e = s.elevator[evt.i]
    return e.direction != stat && !e.doors_open
end
@fire function fire!(evt::Stop, s, when, rng)
    s.elevator[evt.i].doors_open = true
end
@conditionsfor Stop begin
    @reactto changed(elevator[i].doors_open) do s
        generate(Stop(i))
    end
    @reactto fired(Dispatch(i)) do s
        generate(Stop(i))
    end
end
end # module SeededFixed

# A tiny runnable model for the harvest / static⊇dynamic test.
module HarvestFix
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: CombinedNextReaction
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

@enum St on off
@keyedby Cell Int64 begin
    s::St
end
@observedphysical Grid begin
    cell::ObservedVector{Cell,Member}
end
function Grid(n::Int)
    c = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(c)
        c[i] = Cell(off)
    end
    return Grid(c)
end
struct Turn <: SimEvent
    i::Int64
end
@guard function precondition(evt::Turn, g)
    return g.cell[evt.i].s == off
end
@conditionsfor Turn begin
    @reactto changed(cell[j].s) do g
        generate(Turn(j))
    end
end
enable(evt::Turn, g, when) = (Exponential(1.0), when)
@fire function fire!(evt::Turn, g, when, rng)
    g.cell[evt.i].s = on
end
struct Reset <: SimEvent
    i::Int64
end
@guard function precondition(evt::Reset, g)
    return g.cell[evt.i].s == on
end
@conditionsfor Reset begin
    @reactto changed(cell[j].s) do g
        generate(Reset(j))
    end
end
enable(evt::Reset, g, when) = (Exponential(2.0), when)
@fire function fire!(evt::Reset, g, when, rng)
    g.cell[evt.i].s = off
end
const EVENTS = [Turn, Reset]
function run_it(policy)
    g = Grid(3)
    sim = SimulationFSM(g, EVENTS; sampler=CombinedNextReaction{Tuple,Float64}(),
        rng=Xoshiro(11), policy=policy)
    initf = function (p, when, rng)
        for i in eachindex(p.cell)
            p.cell[i].s = on
        end
    end
    stopf = function (p, step, evt, when)
        return step > 60
    end
    ChronoSim.run(sim, initf, stopf)
    return sim
end
end # module HarvestFix

# Like HarvestFix, but with a PLAIN reader (no @guard/@precondition — it lands in
# unanalyzed_guards) that has real depnet enable dependencies at runtime. Used to
# prove static_covers_dynamic FAILS for unanalyzed readers with harvested reads
# instead of silently skipping them.
module HarvestPlainFix
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: CombinedNextReaction
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

@enum St pon poff
@keyedby Cell Int64 begin
    s::St
end
@observedphysical Grid begin
    cell::ObservedVector{Cell,Member}
end
function Grid(n::Int)
    c = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(c)
        c[i] = Cell(poff)
    end
    return Grid(c)
end
struct Toggle <: SimEvent
    i::Int64
end
@guard function precondition(evt::Toggle, g)
    return g.cell[evt.i].s == poff
end
@conditionsfor Toggle begin
    @reactto changed(cell[j].s) do g
        generate(Toggle(j))
    end
end
enable(evt::Toggle, g, when) = (Exponential(1.0), when)
@fire function fire!(evt::Toggle, g, when, rng)
    g.cell[evt.i].s = pon
end
# Plain: unannotated precondition (reads state -> depnet en edges), hand
# generators; neither guard_spec nor derivation_spec exists for it.
struct Plain <: SimEvent
    i::Int64
end
precondition(evt::Plain, g) = g.cell[evt.i].s == pon
@conditionsfor Plain begin
    @reactto changed(cell[j].s) do g
        generate(Plain(j))
    end
end
enable(evt::Plain, g, when) = (Exponential(1.0), when)
function fire!(evt::Plain, g, when, rng)
    g.cell[evt.i].s = poff
    return nothing
end
const EVENTS = [Toggle, Plain]
function run_it(policy)
    g = Grid(3)
    sim = SimulationFSM(g, EVENTS; sampler=CombinedNextReaction{Tuple,Float64}(),
        rng=Xoshiro(7), policy=policy)
    initf = function (p, when, rng)
        for i in eachindex(p.cell)
            p.cell[i].s = pon
        end
    end
    stopf = function (p, step, evt, when)
        return step > 40
    end
    ChronoSim.run(sim, initf, stopf)
    return sim
end
end # module HarvestPlainFix

########################### Kernel: structural table (S1–S11) ###########################

@testset "lint (Phase 3)" begin

@testset "lint kernel structural table" begin
    # S1: no index positions.
    @test _intersect_verdict(_ap((_M(:floor_cnt),), []), _ap((_M(:floor_cnt),), [])) === :overlap
    # S2: leaf Member differs.
    @test _intersect_verdict(_ap((_M(:person), _IX, _M(:waiting)), [TaintedIndex()]),
        _ap((_M(:person), _IX, _M(:location)), [TaintedIndex()])) === :disjoint
    # S3: container differs.
    @test _intersect_verdict(_ap((_M(:person), _IX, _M(:waiting)), [TaintedIndex()]),
        _ap((_M(:elevator), _IX, _M(:waiting)), [TaintedIndex()])) === :disjoint
    # S4: Member vs MEMBERINDEX at position 2.
    @test _intersect_verdict(_ap((_M(:calls), _IX, _M(:requested)), [TaintedIndex()]),
        _ap((_M(:calls), _M(:requested)), [])) === :disjoint
    # S5: length mismatch, no subtree.
    @test _intersect_verdict(_ap((_M(:strains), _IX), [TaintedIndex()]),
        _ap((_M(:strains), _IX, _M(:infectivity)), [TaintedIndex()])) === :disjoint
    # S6: subtree prefix covers descendant (both argument orders — the reversed
    # order exercises the other branch of the subtree alignment condition).
    @test _intersect_verdict(_ap((_M(:strains), _IX), [TaintedIndex()]; subtree=true),
        _ap((_M(:strains), _IX, _M(:infectivity)), [TaintedIndex()])) === :overlap
    @test _intersect_verdict(_ap((_M(:strains), _IX, _M(:infectivity)), [TaintedIndex()]),
        _ap((_M(:strains), _IX), [TaintedIndex()]; subtree=true)) === :overlap
    # S7: whole-container subtree read, no shared index position (both orders).
    @test _intersect_verdict(_ap((_M(:strains),), []; subtree=true),
        _ap((_M(:strains), _IX, _M(:infectivity)), [TaintedIndex()])) === :overlap
    @test _intersect_verdict(_ap((_M(:strains), _IX, _M(:infectivity)), [TaintedIndex()]),
        _ap((_M(:strains),), []; subtree=true)) === :overlap
    # A LONGER subtree pattern does not cover a SHORTER leaf (one-directional).
    @test _intersect_verdict(_ap((_M(:strains), _IX), [TaintedIndex()]; subtree=true),
        _ap((_M(:strains),), [])) === :disjoint
    # S8: equal subtree.
    @test _intersect_verdict(_ap((_M(:locations), _IX), [TaintedIndex()]; subtree=true),
        _ap((_M(:locations), _IX), [TaintedIndex()]; subtree=true)) === :overlap
    # S9: prefix Member mismatch.
    @test _intersect_verdict(_ap((_M(:actors), _IX), [TaintedIndex()]; subtree=true),
        _ap((_M(:locations), _IX, _M(:individuals)), [TaintedIndex()])) === :disjoint
    # S10: one disjoint among several positions dominates.
    @test _intersect_verdict(
        _ap((_M(:board), _IX, _IX, _M(:piece)), [LiteralIndex(1), LiteralIndex(2)]),
        _ap((_M(:board), _IX, _IX, _M(:piece)), [LiteralIndex(1), LiteralIndex(9)])) === :disjoint
    # S11: overlap + possible -> possible.
    @test _intersect_verdict(
        _ap((_M(:board), _IX, _IX, _M(:piece)), [LiteralIndex(1), FieldBinding(:x)]),
        _ap((_M(:board), _IX, _IX, _M(:piece)), [LiteralIndex(1), FieldBinding(:y)])) === :possible
end

########################### Kernel: index table (K1–K12) ###########################

@testset "lint kernel index table" begin
    m = (_M(:c), _IX)
    verdict(ia, ib) = _intersect_verdict(_ap(m, [ia]), _ap(m, [ib]))
    both(ia, ib, exp) = (@test verdict(ia, ib) === exp; @test verdict(ib, ia) === exp)

    both(TaintedIndex(), LiteralIndex(3), :overlap)            # K1 vs literal
    both(TaintedIndex(), FieldBinding(:f), :overlap)           # K1 vs field binding
    @test verdict(TaintedIndex(), TaintedIndex()) === :overlap # K1 vs itself
    @test verdict(LiteralIndex(3), LiteralIndex(3)) === :overlap  # K2
    both(LiteralIndex(3), LiteralIndex(4), :disjoint)          # K3
    both(LiteralIndex(3), FieldBinding(:f), :possible)         # K4
    @test verdict(FieldBinding(:f), FieldBinding(:g)) === :possible  # K5
    # K6: TupleIndex fold, equal length.
    @test verdict(TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)]),
        TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)])) === :overlap
    @test verdict(TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)]),
        TupleIndex(Any[LiteralIndex(1), LiteralIndex(9)])) === :disjoint
    @test verdict(TupleIndex(Any[LiteralIndex(1), FieldBinding(:f)]),
        TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)])) === :possible
    # K7: TupleIndex lengths differ.
    both(TupleIndex(Any[LiteralIndex(1)]),
        TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)]), :disjoint)
    # K8: TupleIndex vs TaintedIndex.
    both(TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)]), TaintedIndex(), :overlap)
    # K9: TupleIndex vs LiteralIndex(tuple) matching arity.
    both(TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)]), LiteralIndex((1, 2)), :overlap)
    both(TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)]), LiteralIndex((1, 9)), :disjoint)
    # K10: TupleIndex vs LiteralIndex wrong arity / non-tuple.
    both(TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)]), LiteralIndex((1, 2, 3)), :disjoint)
    both(TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)]), LiteralIndex(5), :disjoint)
    # K11: TupleIndex vs FieldBinding.
    both(TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)]), FieldBinding(:f), :possible)
    # K12: same field, same "event" — still domain-dependent.
    @test verdict(FieldBinding(:f), FieldBinding(:f)) === :possible
end

@testset "masks_intersect boolean" begin
    m = (_M(:c), _IX)
    cases = [
        (TaintedIndex(), LiteralIndex(3)),
        (TaintedIndex(), FieldBinding(:f)),
        (TaintedIndex(), TaintedIndex()),
        (LiteralIndex(3), LiteralIndex(3)),
        (LiteralIndex(3), LiteralIndex(4)),
        (LiteralIndex(3), FieldBinding(:f)),
        (FieldBinding(:f), FieldBinding(:g)),
        (FieldBinding(:f), FieldBinding(:f)),
        (TupleIndex(Any[LiteralIndex(1)]), TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)])),
        (TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)]), LiteralIndex((1, 2))),
        (TupleIndex(Any[LiteralIndex(1), LiteralIndex(2)]), LiteralIndex(5)),
        (TupleIndex(Any[LiteralIndex(1), FieldBinding(:f)]), TaintedIndex()),
    ]
    for (ia, ib) in cases
        a = _ap(m, [ia])
        b = _ap(m, [ib])
        @test masks_intersect(a, b) == (_intersect_verdict(a, b) !== :disjoint)
        @test masks_intersect(b, a) == (_intersect_verdict(b, a) !== :disjoint)
    end
    # Structural pairs (mask/subtree level), same identity.
    spairs = [
        (_ap((_M(:a), _IX, _M(:x)), [TaintedIndex()]), _ap((_M(:a), _IX, _M(:y)), [TaintedIndex()])),
        (_ap((_M(:a), _IX), [TaintedIndex()]; subtree=true),
         _ap((_M(:a), _IX, _M(:x)), [TaintedIndex()])),
        (_ap((_M(:a),), []; subtree=true), _ap((_M(:b), _IX), [TaintedIndex()])),
        (_ap((_M(:n),), []), _ap((_M(:n),), [])),
    ]
    for (a, b) in spairs
        @test masks_intersect(a, b) == (_intersect_verdict(a, b) !== :disjoint)
        @test masks_intersect(b, a) == (_intersect_verdict(b, a) !== :disjoint)
    end
end

@testset "pattern from concrete place" begin
    p = AddressPattern((_M(:calls), (3, :Up), _M(:requested)))
    @test p.mask == (_M(:calls), _IX, _M(:requested))
    @test length(p.indices) == 1
    @test p.indices[1] isa LiteralIndex
    @test p.indices[1].value == (3, :Up)
end

########################### @guard derivation ###########################

@testset "guard macro derives reads" begin
    gs = guard_spec(LintFix.WA)
    masks = Set(ChronoSim.placekey_mask_index(s.matchstr) for s in gs.reads)
    @test (_M(:cell), _IX, _M(:b)) in masks
    # runtime behavior identical to an unannotated copy
    g = LintFix.Grid(2)
    @test ChronoSim.precondition(LintFix.WA(1), g) == true
end

@testset "guard tolerates zero reads" begin
    gs = guard_spec(LintFix.ZeroG)
    @test isempty(gs.reads)
    @test "reads no state" in gs.notes
end

@testset "guard converts whole reads" begin
    gs = guard_spec(LintFix.WholeG)
    @test gs.whole_containers == [_M(:d)]
end

@testset "guard inlines recursion and fragments" begin
    gs = guard_spec(LintFix.Rec1)
    masks = Dict{Tuple,Any}()
    for s in gs.reads
        masks[ChronoSim.placekey_mask_index(s.matchstr)] = s.indices
    end
    @test haskey(masks, (_M(:cell), _IX, _M(:a)))   # from precondition(Base1) recursion
    @test haskey(masks, (_M(:cell), _IX, _M(:b)))   # from readb fragment
    @test masks[(_M(:cell), _IX, _M(:a))][1] == FieldBinding(:i)
    @test masks[(_M(:cell), _IX, _M(:b))][1] == FieldBinding(:i)
end

@testset "guard opaque state call errors" begin
    @test_throws Exception @eval module _GuardOpaque
        using ChronoSim
        using ChronoSim.ObservedState
        import ChronoSim: precondition
        @keyedby Cell Int64 begin
            a::Int64
        end
        @observedphysical Grid begin
            cell::ObservedVector{Cell,Member}
        end
        opaque_helper(x) = x.a
        struct Bad <: SimEvent
            i::Int64
        end
        @guard function precondition(evt::Bad, s)
            return opaque_helper(s.cell[evt.i]) > 0
        end
    end
end

########################### lint edge computation ###########################

@testset "lint finds write→guard edge" begin
    r = lint([LintFix.WA, LintFix.RG])
    e = findfirst(x -> x.kind === :write_guard && x.writer === :WA && x.reader === :RG, r.edges)
    @test e !== nothing
    edge = r.edges[e]
    @test edge.overlap_mask == (_M(:cell), _IX, _M(:a))
    @test edge.level === :warning
end

@testset "derived reader never warns" begin
    r = lint([LintFix.WA, LintFix.WB, LintFix.Der])
    der_edges = [e for e in r.edges if e.kind === :write_guard && e.reader === :Der]
    @test !isempty(der_edges)
    @test all(e -> e.trigger_covered && e.level === :info, der_edges)
end

@testset "seeded missed trigger warns" begin
    r = lint([SeededBug.Dispatch, SeededBug.Stop])
    ws = warnings(r)
    stop_dir = [e for e in ws
                if e.reader === :Stop && e.overlap_mask == (_M(:elevator), _IX, _M(:direction))]
    @test length(stop_dir) == 1
    @test stop_dir[1].writer === :Dispatch
    @test length(ws) == 1
end

@testset "fired trigger covers edge" begin
    r = lint([SeededFixed.Dispatch, SeededFixed.Stop])
    e = findfirst(x -> x.kind === :write_guard && x.writer === :Dispatch && x.reader === :Stop &&
        x.overlap_mask == (_M(:elevator), _IX, _M(:direction)), r.edges)
    @test e !== nothing
    @test r.edges[e].trigger_covered
    @test r.edges[e].level === :info
    @test isempty(warnings(r))
end

@testset "seeded write→write race" begin
    r = lint([LintFix.WA, LintFix.WB])
    ww = [e for e in r.edges if e.kind === :write_write]
    a_races = [e for e in ww if e.overlap_mask == (_M(:cell), _IX, _M(:a))]
    @test length(a_races) == 1
    @test all(e -> e.level === :info, ww)
    # A == B produces no write→write edge.
    @test all(e -> e.writer !== e.reader, ww)
end

########################### enumeration refinement ###########################

@testset "enumeration demotes empty overlap" begin
    r = lint([LintFix.LitW, LintFix.DomEmpty]; physical=LintFix.Grid(5))
    e = findfirst(x -> x.kind === :write_guard && x.writer === :LitW && x.reader === :DomEmpty,
        r.edges)
    @test e !== nothing
    @test r.edges[e].verdict === :empty
    @test r.edges[e].level === :info
    @test occursin("provably empty", r.edges[e].note)
end

@testset "enumeration inhabited stays" begin
    r = lint([LintFix.LitW, LintFix.DomFull]; physical=LintFix.Grid(5))
    e = findfirst(x -> x.kind === :write_guard && x.writer === :LitW && x.reader === :DomFull,
        r.edges)
    @test e !== nothing
    @test r.edges[e].verdict === :overlap
    @test r.edges[e].level === :warning
end

@testset "enumeration cap reported" begin
    r = lint([LintFix.LitW, LintFix.DomFull]; physical=LintFix.Grid(5), enum_cap=2)
    @test any(c -> occursin("enumeration cap hit", c), r.caps)
    e = findfirst(x -> x.kind === :write_guard && x.writer === :LitW && x.reader === :DomFull,
        r.edges)
    @test r.edges[e].verdict === :possible
end

@testset "no physical caps loudly" begin
    r = lint([LintFix.WA, LintFix.RG])
    @test any(c -> occursin("index enumeration skipped", c), r.caps)
    @test any(c -> occursin("dead-address reflection skipped", c), r.caps)
end

@testset "dead address detected" begin
    r = lint([LintFix.WA, LintFix.WB, LintFix.RG, LintFix.WholeG]; physical=LintFix.Grid(3))
    @test :n in r.dead_addresses      # never written, never guard-read
    @test !(:pp in r.dead_addresses)  # Param field is unobserved-by-design
    @test !(:cell in r.dead_addresses)
    @test !(:d in r.dead_addresses)   # WholeG reads the whole container
end

@testset "unanalyzed listed" begin
    r = lint([LintFix.WA, LintFix.Der])
    @test :Der in r.unanalyzed_effects   # no @fire
    @test :WB ∉ r.events                  # sanity
    r2 = lint([LintFix.WA, LintFix.WB])
    @test :WB in r2.unanalyzed_guards    # no @guard / @precondition
    @test :WA ∉ r2.unanalyzed_guards
end

########################### report display ###########################

@testset "rate note always printed" begin
    r = lint([LintFix.WA, LintFix.RG])
    txt = sprint(show, MIME"text/plain"(), r)
    @test occursin("write→rate edges: not analyzed", txt)
end

@testset "report bounded and greppable" begin
    r = lint([LintFix.WA, LintFix.WB, LintFix.RG, LintFix.Der])
    summary = sprint(show, MIME"text/plain"(), r)
    @test count(==('\n'), summary) <= 30
    @test !occursin('\e', summary)   # no ANSI color
    full = sprint(print_lint, r)
    @test count(l -> startswith(l, "edge "), split(full, '\n')) == length(r.edges)
end

@testset "module scan entry" begin
    r_mod = lint(HarvestFix)
    r_vec = lint(HarvestFix.EVENTS)
    @test r_mod.events == r_vec.events
    @test issorted(r_mod.events)
    @test Set(r_mod.events) == Set([:Turn, :Reset])
end

########################### allowlist ###########################

@testset "assert_lint_clean allowlist" begin
    r = lint([LintFix.WA, LintFix.WB, LintFix.RG])
    @test !isempty(warnings(r))
    @test_throws LintFailure assert_lint_clean(r)
    allow = [LintAllow(; reader=:RG, mask="[cell, ℤ, a]",
        reason="RG intentionally narrows to cell.b triggers")]
    @test assert_lint_clean(r; allow=allow) === r
    # an unused (stale) entry prints a notice to `io` but does not fail
    stale = [LintAllow(; reader=:RG, mask="[cell, ℤ, a]", reason="ok"),
        LintAllow(; reader=:Nobody, mask="[x]", reason="stale")]
    buf = IOBuffer()
    @test assert_lint_clean(r; allow=stale, io=buf) === r
    notice = String(take!(buf))
    @test occursin("stale LintAllow", notice)
    @test occursin("Nobody", notice)
end

########################### harvest + static covers dynamic ###########################

@testset "harvest + static covers dynamic" begin
    harvest = LintHarvest()
    HarvestFix.run_it(harvest)
    @test !isempty(harvest.pairs)
    report = lint(HarvestFix.EVENTS; physical=HarvestFix.Grid(3))
    dc = static_covers_dynamic(report, harvest; ignore_writers=[:InitializeEvent])
    @test dc.covered
    # Artificially filter Turn's edges -> the comparison must find missing coverage.
    bad_edges = [e for e in report.edges if e.reader !== :Turn]
    bad_gi = filter(kv -> kv.first !== :Turn, report.guard_index)
    bad = LintReport(report.events, bad_edges, report.dead_addresses,
        report.unanalyzed_guards, report.unanalyzed_effects, report.rate_note,
        report.caps, bad_gi)
    dc2 = static_covers_dynamic(bad, harvest; ignore_writers=[:InitializeEvent])
    @test !dc2.covered
end

@testset "unanalyzed reader with depnet edges fails coverage" begin
    # Plain has no guard_spec/derivation_spec but acquires real enable deps at
    # runtime; static_covers_dynamic must report its harvested reads as missing,
    # not silently skip them (the theorem's read clause).
    harvest = LintHarvest()
    HarvestPlainFix.run_it(harvest)
    @test any(rd -> rd[1] === :Plain, harvest.read_deps)
    report = lint(HarvestPlainFix.EVENTS; physical=HarvestPlainFix.Grid(3))
    @test :Plain in report.unanalyzed_guards
    dc = static_covers_dynamic(report, harvest; ignore_writers=[:InitializeEvent])
    @test !dc.covered
    @test any(mr -> mr[1] === :Plain, dc.missing_reads)
end

@testset "edge mask covers place one-directionally" begin
    em = (_M(:strains),)                       # a subtree edge's overlap mask
    pm = (_M(:strains), _IX, _M(:infectivity)) # a deeper concrete place, masked
    @test ChronoSim._edge_mask_covers_place(em, pm)      # prefix covers deeper place
    @test !ChronoSim._edge_mask_covers_place(pm, em)     # deeper mask never covers shallower place
    @test ChronoSim._edge_mask_covers_place(pm, pm)      # equality covers
end

end  # @testset "lint (Phase 3)"
