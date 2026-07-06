using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

# Phase 2: the @fire write-side taint pass. A small in-file model exercises every
# construct in the walker's table (leaf/op-assign/compound writes, set mutators,
# stochastic/when/const/staleness classification, loops/branches, @fragment
# inlining, fire!-recursion, @obswrite) plus can_stop_change.

module FireModel
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: CombinedNextReaction
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

@enum Color red green blue

@keyedby Cell Int64 begin
    a::Int64
    b::Int64
end

@observedphysical Grid begin
    cell::ObservedVector{Cell,Member}
    tags::ObservedSet{Int64,Member}
    d::ObservedDict{Int64,Cell,Member}
    n::Int64
end

function Grid(ncell::Int)
    cells = ObservedArray{Cell,Member}(undef, ncell)
    for i in eachindex(cells)
        cells[i] = Cell(0, 0)
    end
    return Grid(cells, ObservedSet{Int64,Member}(), ObservedDict{Int64,Cell,Member}(), 1)
end

# --- events used by the walker tests (fire! only; no preconditions needed) ---

struct SetA <: SimEvent; i::Int64; end
@fire function fire!(evt::SetA, state, when, rng)
    state.cell[evt.i].a = 1
end

struct CopyAB <: SimEvent; i::Int64; end
@fire function fire!(evt::CopyAB, state, when, rng)
    state.cell[evt.i].b = state.cell[evt.i].a
end

struct LoopW <: SimEvent; end
@fire function fire!(evt::LoopW, state, when, rng)
    for i in eachindex(state.cell)
        state.cell[i].a = 0
    end
end

struct Branchy <: SimEvent; i::Int64; end
@fire function fire!(evt::Branchy, state, when, rng)
    if state.n > 0
        state.cell[evt.i].a = 1
    else
        state.cell[evt.i].b = 2
    end
end

struct OpInc <: SimEvent; i::Int64; end
@fire function fire!(evt::OpInc, state, when, rng)
    state.cell[evt.i].a += 1
end

struct Stoch <: SimEvent; i::Int64; end
@fire function fire!(evt::Stoch, state, when, rng)
    r = rand(rng, 1:3)
    state.cell[evt.i].a = r
    state.cell[evt.i].b = sample(rng, [1, 2, 3])
end

struct Whenny <: SimEvent; i::Int64; end
@fire function fire!(evt::Whenny, state, when, rng)
    state.cell[evt.i].b = when - state.cell[evt.i].a
end

struct ConstW <: SimEvent; i::Int64; end
@fire function fire!(evt::ConstW, state, when, rng)
    c = green
    state.cell[evt.i].a = Int(c)
end

struct Stale <: SimEvent; end
@fire function fire!(evt::Stale, state, when, rng)
    k = state.n
    state.n += 1
    state.cell[1].a = k
end

struct DictPut <: SimEvent; k::Int64; end
@fire function fire!(evt::DictPut, state, when, rng)
    state.d[evt.k] = Cell(1, 2)
end

struct SetMut <: SimEvent; x::Int64; end
@fire function fire!(evt::SetMut, state, when, rng)
    push!(state.tags, evt.x)
    delete!(state.tags, evt.x)
    union!(state.tags, Set([evt.x]))
    empty!(state.tags)
end

struct LocalMut <: SimEvent; x::Int64; end
@fire function fire!(evt::LocalMut, state, when, rng)
    scratch = Set{Int64}()
    push!(scratch, evt.x)
    delete!(scratch, evt.x)
    state.cell[1].a = length(scratch)
end

struct ObsW <: SimEvent; i::Int64; end
@fire function fire!(evt::ObsW, state, when, rng)
    @obswrite state.cell[evt.i].a = 7
end

# fire!-recursion: Caller inlines Callee's write with j substituted.
struct Callee <: SimEvent; j::Int64; end
@fire function fire!(evt::Callee, state, when, rng)
    state.cell[evt.j].a = 9
end
struct Caller <: SimEvent; j::Int64; end
@fire function fire!(evt::Caller, state, when, rng)
    fire!(Callee(evt.j), state, when, rng)
end
struct CallerLoop <: SimEvent; end
@fire function fire!(evt::CallerLoop, state, when, rng)
    for k in eachindex(state.cell)
        fire!(Callee(k), state, when, rng)
    end
end

# @fragment helper that WRITES: its write must be seen from the caller.
@fragment function bump!(cell)
    cell.a = cell.a + 1
end
struct FragW <: SimEvent; i::Int64; end
@fire function fire!(evt::FragW, state, when, rng)
    bump!(state.cell[evt.i])
end

# Non-bang opaque helper receiving state (tolerated with a note).
noisy(cell) = cell.a
struct OpaqueTol <: SimEvent; i::Int64; end
@fire function fire!(evt::OpaqueTol, state, when, rng)
    _ = noisy(state.cell[evt.i])
    state.cell[evt.i].b = 3
end

end # module FireModel

const FM = FireModel
_es(T) = ChronoSim.effect_spec(T)
_wmask(w) = ChronoSim.write_mask(w)

@testset "fire macro derives clean assignment" begin
    es = _es(FM.SetA)
    @test length(es.writes) == 1
    w = es.writes[1]
    @test _wmask(w) == (Member(:cell), ChronoSim.MEMBERINDEX, Member(:a))
    @test w.op === :assign
    @test w.rhs === :evt_pure
    @test w.rhs_ast == 1
    @test ChronoSim.spec_clean(w)
    @test es.widened_writes == 0
end

@testset "fire macro records rhs reads" begin
    es = _es(FM.CopyAB)
    @test length(es.writes) == 1
    @test es.writes[1].rhs === :state_expr
    @test any(r -> ChronoSim.placekey_mask_index(r.matchstr) ==
                   (Member(:cell), ChronoSim.MEMBERINDEX, Member(:a)), es.reads)
end

@testset "loop widens write indices" begin
    es = _es(FM.LoopW)
    @test length(es.writes) == 1
    @test !ChronoSim.spec_clean(es.writes[1])
    @test es.widened_writes == 1
end

@testset "branches union to both writes" begin
    es = _es(FM.Branchy)
    masks = Set(_wmask(w) for w in es.writes)
    @test (Member(:cell), ChronoSim.MEMBERINDEX, Member(:a)) in masks
    @test (Member(:cell), ChronoSim.MEMBERINDEX, Member(:b)) in masks
    @test length(es.writes) == 2
end

@testset "op-assign is read+write state_expr" begin
    es = _es(FM.OpInc)
    @test length(es.writes) == 1
    @test es.writes[1].rhs === :state_expr
    @test any(r -> ChronoSim.placekey_mask_index(r.matchstr) ==
                   (Member(:cell), ChronoSim.MEMBERINDEX, Member(:a)), es.reads)
end

@testset "stochastic detection" begin
    es = _es(FM.Stoch)
    @test all(w -> w.rhs === :stochastic, es.writes)
    @test length(es.writes) == 2
end

@testset "when demotes to opaque with note" begin
    es = _es(FM.Whenny)
    @test es.writes[1].rhs === :opaque
    @test any(n -> occursin("time-dependent", n), es.notes)
end

@testset "module const is evt_pure" begin
    es = _es(FM.ConstW)
    @test es.writes[1].rhs === :evt_pure
end

@testset "alias staleness demotes to opaque" begin
    es = _es(FM.Stale)
    # writes: (n,) state_expr, then (cell,ℤ,a) opaque via staleness
    strain = findfirst(w -> _wmask(w) == (Member(:cell), ChronoSim.MEMBERINDEX, Member(:a)),
                       es.writes)
    @test strain !== nothing
    @test es.writes[strain].rhs === :opaque
    @test any(n -> occursin("read-before-write", n), es.notes)
    nwrite = findfirst(w -> _wmask(w) == (Member(:n),), es.writes)
    @test es.writes[nwrite].rhs === :state_expr
end

@testset "dict compound setindex is subtree" begin
    es = _es(FM.DictPut)
    w = es.writes[1]
    @test w.subtree === true
    @test w.op === :setindex
    @test _wmask(w) == (Member(:d), ChronoSim.MEMBERINDEX)
end

@testset "set mutators write the set address" begin
    es = _es(FM.SetMut)
    # push!/union!/empty! write the set's own address; keyed delete! additionally
    # declares the keyed subtree shape (sound over-declaration for dict-like
    # containers; an ObservedSet only ever notifies (tags,)).
    @test all(w -> _wmask(w) == (Member(:tags),) ||
                   _wmask(w) == (Member(:tags), ChronoSim.MEMBERINDEX), es.writes)
    @test any(w -> _wmask(w) == (Member(:tags),) && w.op === :push, es.writes)
    @test any(w -> _wmask(w) == (Member(:tags),) && w.op === :union, es.writes)
    @test any(w -> _wmask(w) == (Member(:tags),) && w.op === :empty, es.writes)
    @test any(w -> _wmask(w) == (Member(:tags),) && w.op === :delete && !w.subtree, es.writes)
    @test any(w -> _wmask(w) == (Member(:tags), ChronoSim.MEMBERINDEX) &&
                   w.op === :delete && w.subtree, es.writes)
end

@testset "mutator on a local container is not a write" begin
    es = _es(FM.LocalMut)
    # only the state.cell[1].a write is recorded; scratch push!/delete! are not
    @test length(es.writes) == 1
    @test _wmask(es.writes[1]) == (Member(:cell), ChronoSim.MEMBERINDEX, Member(:a))
end

@testset "obswrite unwraps to a write" begin
    es = _es(FM.ObsW)
    @test any(w -> _wmask(w) == (Member(:cell), ChronoSim.MEMBERINDEX, Member(:a)), es.writes)
end

@testset "fire recursion inlines callee writes" begin
    es = _es(FM.Caller)
    @test length(es.writes) == 1
    w = es.writes[1]
    @test _wmask(w) == (Member(:cell), ChronoSim.MEMBERINDEX, Member(:a))
    @test ChronoSim.spec_clean(w)              # evt.j substituted -> FieldBinding(:j), clean
    es2 = _es(FM.CallerLoop)
    @test !ChronoSim.spec_clean(es2.writes[1]) # loop var k -> tainted
end

@testset "fragment helper writes are seen" begin
    es = _es(FM.FragW)
    @test any(w -> _wmask(w) == (Member(:cell), ChronoSim.MEMBERINDEX, Member(:a)), es.writes)
end

@testset "opaque non-bang call is tolerated with note" begin
    es = _es(FM.OpaqueTol)
    @test any(n -> occursin("noisy", n) && occursin("receives state", n), es.notes)
    @test any(w -> _wmask(w) == (Member(:cell), ChronoSim.MEMBERINDEX, Member(:b)), es.writes)
end

@testset "unrecognized bang on state errors at expansion" begin
    err = try
        @macroexpand FireModel.@fire function fire!(evt::FireModel.SetA, state, when, rng)
            sort!(state.cell)
        end
        nothing
    catch e
        e
    end
    @test err !== nothing
    msg = sprint(showerror, err)
    @test occursin("sort!", msg)
    @test occursin("recognized", msg)
end

@testset "zero-write body errors at expansion" begin
    err = try
        @macroexpand FireModel.@fire function fire!(evt::FireModel.SetA, state, when, rng)
            x = state.cell[evt.i].a
            return x
        end
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test occursin("writes no physical state", sprint(showerror, err))
end

@testset "effect_spec dedup merges identical branch writes" begin
    # A write to the same address in both branches collapses to one spec.
    es = ChronoSim._derive_effectspecs(
        quote
            if state.n > 0
                state.cell[evt.i].a = 5
            else
                state.cell[evt.i].a = 5
            end
        end, :state, :evt, :when, :rng, FireModel)
    @test length(es.writes) == 1
end

@testset "derivation_report prints WRITES for an effect-only event" begin
    txt = sprint(io -> ChronoSim.derivation_report(io, FM.LoopW))
    @test occursin("WRITES", txt)
    @test occursin("WIDENED", txt)
    @test occursin("rhs mix:", txt)
    @test occursin("triggers: none derived", txt)   # no @precondition on LoopW
end

########################### can_stop_change ###########################

@testset "stop reads writable -> can_change" begin
    reads = [(Member(:cell), 1, Member(:a))]
    sw = ChronoSim.can_stop_change(reads, [FM.SetA, FM.CopyAB])
    @test sw.verdict === :can_change
    @test :SetA in Set(h.event for h in sw.hits)
end

@testset "unwritable read -> cannot_change" begin
    # nothing writes cell[ℤ].b except CopyAB/Branchy; use SetA + OpInc which only write .a
    reads = [(Member(:cell), 1, Member(:b))]
    sw = ChronoSim.can_stop_change(reads, [FM.SetA, FM.OpInc])
    @test sw.verdict === :cannot_change
end

@testset "missing spec -> unknown" begin
    reads = [(Member(:cell), 1, Member(:b))]
    sw = ChronoSim.can_stop_change(reads, [FM.SetA, ChronoSim.InitializeEvent])
    @test sw.verdict === :unknown
    @test :InitializeEvent in sw.unanalyzed
end

@testset "enabled/disabled split" begin
    reads = [(Member(:cell), 1, Member(:a))]
    # Only SetA hits (writes cell.a); the currently-enabled OpInc is not analyzed
    # here, so the sole hitter is a disabled event.
    sw = ChronoSim.can_stop_change(reads, [FM.SetA]; enabled_types=[FM.OpInc])
    @test sw.verdict === :can_change
    @test sw.disabled_hits == [:SetA]
    @test isempty(sw.enabled_hits)
    txt = sprint(show, MIME"text/plain"(), sw)
    @test occursin("none of the currently-enabled", txt)
    @test occursin("SetA", txt)
end

@testset "subtree write intersects descendant read" begin
    reads = [(Member(:d), 1, Member(:a))]
    sw = ChronoSim.can_stop_change(reads, [FM.DictPut])
    @test sw.verdict === :can_change
end

@testset "v1 kernel truth table" begin
    mi = ChronoSim.MEMBERINDEX
    @test ChronoSim._v1_masks_intersect((Member(:c), mi), false, (Member(:c), mi))
    @test ChronoSim._v1_masks_intersect((Member(:c), mi), false, (Member(:c), 3))
    @test !ChronoSim._v1_masks_intersect((Member(:c), mi), false, (Member(:c),))
    @test !ChronoSim._v1_masks_intersect((Member(:c), mi), false, (Member(:x), mi))
    @test ChronoSim._v1_masks_intersect((Member(:c), mi), true, (Member(:c), mi, Member(:a)))
    @test !ChronoSim._v1_masks_intersect((Member(:c), mi), true, (Member(:c),))
end
