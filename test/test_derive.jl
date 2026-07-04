using ReTest
using ChronoSim
using ChronoSim.ObservedState
import ChronoSim: precondition, generators

# Phase 3: production taint pass + @precondition/@domain macros. These tests use a
# small in-file model (not ElevatorExample) so the derived generators() methods do
# not clash with the hand-written @conditionsfor generators the elevator tests use.

############################ In-file test model ############################

module DeriveModel
using ChronoSim
using ChronoSim.ObservedState
import ChronoSim: precondition, generators

@enum Color red green blue

@keyedby Cell Int64 begin
    value::Int64
    flag::Bool
end
@keyedby Link2 Tuple{Int64,Int64} begin
    on::Bool
end
@keyedby GridCell NTuple{2,Int64} begin
    weight::Int64
end
@observedphysical Board begin
    cell::ObservedVector{Cell,Member}
    link::ObservedDict{Tuple{Int64,Int64},Link2,Member}
    grid::ObservedArray{GridCell,2,Member}
    n::Int64
end
function Board(ncell::Int)
    cells = ObservedArray{Cell,Member}(undef, ncell)
    for i in eachindex(cells)
        cells[i] = Cell(i, false)
    end
    links = ObservedDict{Tuple{Int64,Int64},Link2,Member}()
    for i in 1:ncell, j in 1:ncell
        links[(i, j)] = Link2(false)
    end
    # Distinct axis extents (ncell × ncell+1) so a component→axis mapping bug is
    # observable: axes(grid, 1) != axes(grid, 2).
    grid = ObservedArray{GridCell,Member}(undef, ncell, ncell + 1)
    for i in 1:ncell, j in 1:(ncell + 1)
        grid[i, j] = GridCell(0)
    end
    Board(cells, links, grid, ncell)
end

# Clean single-field: two reads bind the same field, no domain needed.
struct Toggle <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::Toggle, state)
    c = state.cell[evt.idx]
    return c.flag && c.value > 0
end

# Literal index -> LiteralIndex guard; zero event fields.
struct FirstFlag <: SimEvent end
@precondition precondition(evt::FirstFlag, state) = state.cell[1].flag

# Loop over fixed-extent vector taints the element index -> widened trigger; the
# clean read binds idx and needs no domain, but the widened one does.
struct AnyFlag <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::AnyFlag, state)
    seen = false
    for i in 1:length(state.cell)
        if state.cell[i].flag
            seen = true
        end
    end
    return seen && state.cell[evt.idx].value > 0
end
@domain AnyFlag.idx = eachindex(physical.cell)

# Dict read with a state-derived tuple key -> widened trigger on the dict.
struct Route <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::Route, state)
    c = state.cell[evt.idx]
    return state.link[(c.value, c.value)].on
end
@domain Route.idx = eachindex(physical.cell)

# Two clean reads binding different fields: each trigger binds one, enumerates the
# other over its domain.
struct Cross <: SimEvent
    i::Int64
    j::Int64
end
@precondition function precondition(evt::Cross, state)
    a = state.cell[evt.i].value
    b = state.cell[evt.j].flag
    return a > 0 && b
end
@domain Cross.i = eachindex(physical.cell)
@domain Cross.j = eachindex(physical.cell)

# Vector-keyed inference (OpenElevatorDoors-shaped): a widened trigger enumerates
# the field, and NO @domain is written — the clean read cell[evt.idx] supplies
# eachindex(physical.cell).
struct DoorScan <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::DoorScan, state)
    seen = false
    for i in 1:length(state.cell)
        if state.cell[i].flag
            seen = true
        end
    end
    return seen && state.cell[evt.idx].value > 0
end

# Dict whole-key inference: `lk` is a whole Tuple key into `link`, enumerated as
# keys(physical.link) when the cell trigger fires. `ci` is vector-keyed. No @domain.
struct DictWhole <: SimEvent
    lk::Tuple{Int64,Int64}
    ci::Int64
end
@precondition function precondition(evt::DictWhole, state)
    a = state.link[evt.lk].on
    b = state.cell[evt.ci].value
    return a && b > 0
end

# Dict tuple-component projection (deduplicated): `fl` is component 1 of `link`'s
# tuple key, enumerated as unique(k[1] for k in keys(link)). No @domain.
struct DictComp <: SimEvent
    fl::Int64
    ci::Int64
end
@precondition function precondition(evt::DictComp, state)
    a = state.link[(evt.fl, evt.fl)].on
    b = state.cell[evt.ci].value
    return a && b > 0
end

# N-D array component → axes(c, m): `r` is axis 1 of `grid`, `c` is axis 2. No @domain.
struct GridEv <: SimEvent
    r::Int64
    c::Int64
    ci::Int64
end
@precondition function precondition(evt::GridEv, state)
    a = state.grid[evt.r, evt.c].weight
    b = state.cell[evt.ci].value
    return a > 0 && b > 0
end

# Enum-typed free field: no read binds `color`, so it is enumerated over its
# finite fieldtype instances(Color). No @domain.
struct ColorEv <: SimEvent
    color::Color
    ci::Int64
end
@precondition precondition(evt::ColorEv, state) = state.cell[evt.ci].value > 0

# Bool-typed free field: enumerated over (false, true). No @domain.
struct BoolEv <: SimEvent
    active::Bool
    ci::Int64
end
@precondition precondition(evt::BoolEv, state) = state.cell[evt.ci].value > 0

# Explicit @domain overrides container-key inference: `idx` is vector-keyed
# (eachindex would be 1:3) but the explicit domain restricts it to [1] so the two
# sources are distinguishable.
struct OverrideEv <: SimEvent
    idx::Int64
    ci::Int64
end
@precondition function precondition(evt::OverrideEv, state)
    a = state.cell[evt.idx].flag
    b = state.cell[evt.ci].value
    return a && b > 0
end
@domain OverrideEv.idx = [1]

# Zero-field event with a widened trigger: the loop taints the index, and the
# empty product of zero domains must still yield exactly one event.
struct ZeroField <: SimEvent end
@precondition function precondition(evt::ZeroField, state)
    seen = false
    for i in 1:length(state.cell)
        if state.cell[i].flag
            seen = true
        end
    end
    return seen
end

# @fragment helpers (Phase 7). A container param inlines to a whole-container read
# (widened here by the loop); an element param bound to evt.idx yields a CLEAN
# FieldBinding through substitution — the reads become visible without leaving the
# fragment.
@fragment function any_flagged(cells)
    seen = false
    for i in 1:length(cells)
        if cells[i].flag
            seen = true
        end
    end
    return seen
end
@fragment value_positive(cells, k) = cells[k].value > 0
struct FragScan <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::FragScan, state)
    return any_flagged(state.cell) && value_positive(state.cell, evt.idx)
end

# Two call sites of the same helper stay independent (α-rename): each binds its own
# evt field cleanly. Vector-keyed idx/jdx need no @domain (cell trigger supplies it).
struct FragTwo <: SimEvent
    idx::Int64
    jdx::Int64
end
@precondition function precondition(evt::FragTwo, state)
    tmp = 3  # caller local named like the helper's local must not collide
    return value_positive(state.cell, evt.idx) && value_positive(state.cell, evt.jdx) && tmp > 0
end
@domain FragTwo.idx = eachindex(physical.cell)
@domain FragTwo.jdx = eachindex(physical.cell)

# Nested helpers (a calls b): value_positive is reached two frames deep.
@fragment cell_ok(cells, k) = value_positive(cells, k)
struct FragNested <: SimEvent
    idx::Int64
end
@precondition precondition(evt::FragNested, state) = cell_ok(state.cell, evt.idx)

# A helper's RESULT used as an index is tainted (sound): cell[j].flag widens, while
# the cell.value read INSIDE the helper (keyed by evt.idx) stays clean.
@fragment pick_value(cells, k) = cells[k].value
struct FragIndex <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::FragIndex, state)
    j = pick_value(state.cell, evt.idx)
    return state.cell[j].flag > 0
end

# Precondition recursion: the caller passes its OWN evt.ci into the constructor, so the
# inlined read cell[evt.ci].value keeps a CLEAN FieldBinding(:ci).
struct FragInner <: SimEvent
    ci::Int64
end
@precondition precondition(evt::FragInner, state) = state.cell[evt.ci].value > 0
struct FragOuter <: SimEvent
    ci::Int64
end
@precondition precondition(evt::FragOuter, state) = precondition(FragInner(evt.ci), state)

# Precondition recursion where the caller passes a LOOP variable (not an evt field):
# the inlined read is tainted/widened.
struct FragOuterLoop <: SimEvent
    ci::Int64
end
@precondition function precondition(evt::FragOuterLoop, state)
    seen = false
    for i in 1:length(state.cell)
        if precondition(FragInner(i), state)
            seen = true
        end
    end
    return seen && state.cell[evt.ci].value > 0
end

# Reducer over a generator: the generator body cell[k].flag is visible syntax; the
# loop var taints the flag read (widened) while cell[evt.idx].value binds idx cleanly.
struct FragReduce <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::FragReduce, state)
    return any(state.cell[k].flag for k in 1:length(state.cell)) && state.cell[evt.idx].value > 0
end

end # module DeriveModel

############################ Helpers ############################

const D = ChronoSim
_DM = DeriveModel
MI = ChronoSim.MEMBERINDEX

# Multiset equality: Member/MEMBERINDEX compare by value but define no value-hash,
# so we cannot use Set. (Same rationale as the spike.)
function _derive_subset(a, b)
    remaining = collect(b)
    for x in a
        i = findfirst(y -> y == x, remaining)
        i === nothing && return false
        deleteat!(remaining, i)
    end
    return true
end
_derive_multiset_equal(a, b) = length(a) == length(b) && _derive_subset(a, b)

_derive_collect(gen, physical, inds...) = begin
    acc = Any[]
    gen.generator(e -> push!(acc, e), physical, inds...)
    acc
end

_find_matchstr(gens, ms) = gens[findfirst(g -> g.matchstr == ms, gens)]

############################ Taint pass unit tests ############################

@testset "derive taint pass binds evt.field index as a clean FieldBinding" begin
    body = quote
        person = system.person[evt.person]
        return person.location != person.destination && !person.waiting
    end
    specs, _ = D._derive_readspecs(body, :system, :evt)
    @test all(D.spec_clean, specs)
    for s in specs
        @test s.indices == Any[D.FieldBinding(:person)]
    end
    mss = [s.matchstr for s in specs]
    @test any(m -> m == Any[Member(:person), MI, Member(:location)], mss)
    @test any(m -> m == Any[Member(:person), MI, Member(:destination)], mss)
    @test any(m -> m == Any[Member(:person), MI, Member(:waiting)], mss)
end

@testset "derive taint pass resolves an evt-pure local used as an index to a FieldBinding" begin
    body = quote
        who = evt.person
        return system.person[who].waiting
    end
    specs, _ = D._derive_readspecs(body, :system, :evt)
    @test length(specs) == 1
    @test specs[1].indices == Any[D.FieldBinding(:person)]
    @test D.spec_clean(specs[1])
end

@testset "derive taint pass taints a loop-variable index into a widened read" begin
    body = quote
        found = false
        for pidx in 1:length(system.person)
            if system.person[pidx].waiting
                found = true
            end
        end
        return found && system.person[evt.person].location != 0
    end
    specs, _ = D._derive_readspecs(body, :system, :evt)
    waiting = specs[findfirst(s -> s.matchstr == Any[Member(:person), MI, Member(:waiting)], specs)]
    @test !D.spec_clean(waiting)
    @test waiting.indices == Any[D.TaintedIndex()]
    location = specs[findfirst(
        s -> s.matchstr == Any[Member(:person), MI, Member(:location)], specs
    )]
    @test D.spec_clean(location)
end

@testset "derive taint pass taints reads through a dict-iteration element alias" begin
    body = quote
        any_active = false
        for ((floor, direction), call) in system.calls
            if call.requested
                any_active = true
            end
        end
        return any_active && system.elevator[evt.elevator_idx].doors_open
    end
    specs, _ = D._derive_readspecs(body, :system, :evt)
    requested = specs[findfirst(
        s -> s.matchstr == Any[Member(:calls), MI, Member(:requested)], specs
    )]
    @test !D.spec_clean(requested)
    @test requested.indices == Any[D.TaintedIndex()]
end

@testset "derive taint pass scopes a branch alias: read tracked inside, no leak after" begin
    body = quote
        total = 0
        if evt.flag
            p = system.person[evt.person]
            if p.waiting
                total = 1
            end
        end
        return total + system.person[evt.person].location
    end
    specs, _ = D._derive_readspecs(body, :system, :evt)
    # The in-branch read through `p` is tracked (clean, evt.person-keyed); the alias
    # does not leak a spurious read past the branch.
    @test length(specs) == 2
    waiting = specs[findfirst(s -> s.matchstr == Any[Member(:person), MI, Member(:waiting)], specs)]
    @test D.spec_clean(waiting)
    @test waiting.indices == Any[D.FieldBinding(:person)]
    @test any(s -> s.matchstr == Any[Member(:person), MI, Member(:location)], specs)
end

@testset "derive taint pass makes a literal index a LiteralIndex" begin
    body = quote
        return system.cell[1].flag
    end
    specs, _ = D._derive_readspecs(body, :system, :evt)
    @test specs[1].indices == Any[D.LiteralIndex(1)]
    @test D.spec_clean(specs[1])
end

@testset "derive taint pass widens an affine evt index and records a note" begin
    body = quote
        return system.cell[evt.idx + 1].flag
    end
    specs, notes = D._derive_readspecs(body, :system, :evt)
    @test specs[1].indices == Any[D.TaintedIndex()]
    @test !isempty(notes)
end

@testset "derive taint pass makes a state-derived tuple key a tainted TupleIndex" begin
    body = quote
        elevator = system.elevator[evt.elevator_idx]
        return system.calls[(elevator.floor, elevator.direction)].requested
    end
    specs, _ = D._derive_readspecs(body, :system, :evt)
    calls = specs[findfirst(s -> s.matchstr == Any[Member(:calls), MI, Member(:requested)], specs)]
    @test calls.indices[1] isa D.TupleIndex
    @test !D.spec_clean(calls)
    # The nested key contributes clean reads of the elevator's floor and direction.
    @test any(s -> s.matchstr == Any[Member(:elevator), MI, Member(:floor)], specs)
    @test any(s -> s.matchstr == Any[Member(:elevator), MI, Member(:direction)], specs)
end

@testset "derive taint pass reads container[key] for a haskey per-key form" begin
    body = quote
        return haskey(system.calls, (evt.floor, evt.dir))
    end
    specs, _ = D._derive_readspecs(body, :system, :evt)
    @test length(specs) == 1
    @test specs[1].matchstr == Any[Member(:calls), MI]
    @test specs[1].indices[1] isa D.TupleIndex
end

############################ Macro-time fragment errors ############################

@testset "derive @precondition errors when a helper receives state" begin
    err = @test_throws LoadError @eval @precondition function precondition(evt::HelperEv, state)
        return isempty(people_waiting(state.person, 1))
    end
    @test occursin("opaque function", sprint(showerror, err.value.error))
end

@testset "derive @precondition errors on a zero-read precondition" begin
    err = @test_throws LoadError @eval @precondition precondition(evt::EmptyEv, state) = evt.idx > 0
    @test occursin("reads no physical state", sprint(showerror, err.value.error))
end

@testset "derive @precondition errors on an uncovered whole-container dict read" begin
    err = @test_throws LoadError @eval @precondition function precondition(evt::LenEv, state)
        return length(state.calls) > 0
    end
    @test occursin("no covering", sprint(showerror, err.value.error))
end

############################ Setup-time domain check ############################

@testset "derive derived_generators demands a domain for an unbound field" begin
    @eval module MissingDomainMod
    using ChronoSim
    import ChronoSim: precondition, generators
    struct NeedsDomain <: SimEvent
        a::Int64
        b::Int64
    end
    @precondition precondition(evt::NeedsDomain, state) = state.arr[evt.a].v > 0
    end
    err = @test_throws ErrorException generators(MissingDomainMod.NeedsDomain)
    @test occursin("@domain NeedsDomain.b", sprint(showerror, err.value))
end

############################ Macro end-to-end behavior ############################

@testset "derive Toggle binds its single field from every clean trigger" begin
    board = _DM.Board(3)
    gens = generators(_DM.Toggle)
    @test length(gens) == 2
    mss = [g.matchstr for g in gens]
    @test _derive_multiset_equal(
        mss, Any[Any[Member(:cell), MI, Member(:value)], Any[Member(:cell), MI, Member(:flag)]]
    )
    for g in gens
        @test _derive_collect(g, board, 2) == Any[_DM.Toggle(2)]
    end
end

@testset "derive FirstFlag guards on its literal index" begin
    board = _DM.Board(3)
    g = only(generators(_DM.FirstFlag))
    @test g.matchstr == Any[Member(:cell), MI, Member(:flag)]
    @test _derive_collect(g, board, 1) == Any[_DM.FirstFlag()]
    @test _derive_collect(g, board, 2) == Any[]
end

@testset "derive AnyFlag widens the loop-tainted trigger and binds the clean one" begin
    board = _DM.Board(3)
    gens = generators(_DM.AnyFlag)
    widened = _find_matchstr(gens, Any[Member(:cell), MI, Member(:flag)])
    @test _derive_multiset_equal(
        _derive_collect(widened, board, 2), Any[_DM.AnyFlag(1), _DM.AnyFlag(2), _DM.AnyFlag(3)]
    )
    clean = _find_matchstr(gens, Any[Member(:cell), MI, Member(:value)])
    @test _derive_collect(clean, board, 2) == Any[_DM.AnyFlag(2)]
end

@testset "derive Route widens a dict tuple-key read over its field domain" begin
    board = _DM.Board(3)
    gens = generators(_DM.Route)
    widened = _find_matchstr(gens, Any[Member(:link), MI, Member(:on)])
    @test _derive_multiset_equal(
        _derive_collect(widened, board, (1, 1)), Any[_DM.Route(1), _DM.Route(2), _DM.Route(3)]
    )
    clean = _find_matchstr(gens, Any[Member(:cell), MI, Member(:value)])
    @test _derive_collect(clean, board, 2) == Any[_DM.Route(2)]
end

@testset "derive Cross binds one field and enumerates the other per trigger" begin
    board = _DM.Board(3)
    gens = generators(_DM.Cross)
    on_value = _find_matchstr(gens, Any[Member(:cell), MI, Member(:value)])
    @test _derive_multiset_equal(
        _derive_collect(on_value, board, 2), Any[_DM.Cross(2, 1), _DM.Cross(2, 2), _DM.Cross(2, 3)]
    )
    on_flag = _find_matchstr(gens, Any[Member(:cell), MI, Member(:flag)])
    @test _derive_multiset_equal(
        _derive_collect(on_flag, board, 2), Any[_DM.Cross(1, 2), _DM.Cross(2, 2), _DM.Cross(3, 2)]
    )
end

############################ Diagnostics ############################

@testset "derive derivation_report labels CLEAN and WIDENED triggers with matchstrs" begin
    txt = sprint(io -> D.derivation_report(io, _DM.AnyFlag))
    @test occursin("WIDENED", txt)
    @test occursin("CLEAN", txt)
    @test occursin("[cell, ℤ, flag]", txt)
    @test occursin("[cell, ℤ, value]", txt)
    @test occursin("AnyFlag.idx", txt)
end

############################ Domain inference (Phase 4B) ############################

@testset "derive vector-keyed field needs no @domain: widened trigger enumerates eachindex" begin
    board = _DM.Board(3)
    gens = generators(_DM.DoorScan)  # no @domain method exists for DoorScan.idx
    widened = _find_matchstr(gens, Any[Member(:cell), MI, Member(:flag)])
    @test _derive_multiset_equal(
        _derive_collect(widened, board, 2), Any[_DM.DoorScan(1), _DM.DoorScan(2), _DM.DoorScan(3)]
    )
end

@testset "derive dict whole-key field is inferred as keys(container)" begin
    board = _DM.Board(3)
    gens = generators(_DM.DictWhole)
    # cell.value trigger binds ci; lk is free, enumerated over keys(physical.link).
    clean = _find_matchstr(gens, Any[Member(:cell), MI, Member(:value)])
    expected = Any[_DM.DictWhole(k, 2) for k in keys(board.link)]
    @test _derive_multiset_equal(_derive_collect(clean, board, 2), expected)
end

@testset "derive dict tuple-component field is inferred and deduplicated" begin
    board = _DM.Board(3)
    gens = generators(_DM.DictComp)
    clean = _find_matchstr(gens, Any[Member(:cell), MI, Member(:value)])
    got = _derive_collect(clean, board, 2)
    # keys(link) has 9 entries but only 3 distinct first components: dedup to 3.
    @test _derive_multiset_equal(
        got, Any[_DM.DictComp(1, 2), _DM.DictComp(2, 2), _DM.DictComp(3, 2)]
    )
    @test length(got) == 3
end

@testset "derive N-D array component maps to axes(container, m)" begin
    board = _DM.Board(3)  # grid is 3×4, so axes(grid,1)=1:3, axes(grid,2)=1:4
    gens = generators(_DM.GridEv)
    clean = _find_matchstr(gens, Any[Member(:cell), MI, Member(:value)])
    got = _derive_collect(clean, board, 2)
    expected = Any[_DM.GridEv(r, c, 2) for r in axes(board.grid, 1) for c in axes(board.grid, 2)]
    @test _derive_multiset_equal(got, expected)
    # Distinct extents confirm r came from axis 1 (1:3) and c from axis 2 (1:4).
    @test length(got) == 12
end

@testset "derive Enum-typed free field enumerates instances of the type" begin
    board = _DM.Board(3)
    g = only(generators(_DM.ColorEv))
    @test _derive_multiset_equal(
        _derive_collect(g, board, 2),
        Any[_DM.ColorEv(_DM.red, 2), _DM.ColorEv(_DM.green, 2), _DM.ColorEv(_DM.blue, 2)],
    )
end

@testset "derive Bool-typed free field enumerates (false, true)" begin
    board = _DM.Board(3)
    g = only(generators(_DM.BoolEv))
    @test _derive_multiset_equal(
        _derive_collect(g, board, 2), Any[_DM.BoolEv(false, 2), _DM.BoolEv(true, 2)]
    )
end

@testset "derive explicit @domain overrides container-key inference" begin
    board = _DM.Board(3)
    gens = generators(_DM.OverrideEv)
    # cell.value trigger binds ci; idx is free. Container-key would give 1:3, but
    # the explicit @domain OverrideEv.idx = [1] must win.
    clean = _find_matchstr(gens, Any[Member(:cell), MI, Member(:value)])
    @test _derive_collect(clean, board, 2) == Any[_DM.OverrideEv(1, 2)]
end

@testset "derive zero-field event with a widened trigger generates exactly one event" begin
    board = _DM.Board(3)
    g = only(generators(_DM.ZeroField))
    @test _derive_collect(g, board, 2) == Any[_DM.ZeroField()]
end

@testset "derive missing-domain error reports all three attempted sources" begin
    @eval module ThreeAttemptMod
    using ChronoSim
    import ChronoSim: precondition, generators
    struct Unresolvable <: SimEvent
        a::Int64
        b::Float64
    end
    @precondition precondition(evt::Unresolvable, state) = state.arr[evt.a].v > 0
    end
    err = @test_throws ErrorException generators(ThreeAttemptMod.Unresolvable)
    msg = sprint(showerror, err.value)
    @test occursin("no @domain method", msg)
    @test occursin("not container-keyed", msg)
    @test occursin("not finite", msg)
    @test occursin("@domain Unresolvable.b", msg)
end

@testset "derive derivation_report shows per-field domain provenance" begin
    # container-key provenance shows the resolved container path.
    dw = sprint(io -> D.derivation_report(io, _DM.DictWhole))
    @test occursin("DictWhole.lk: container-key(physical.link)", dw)
    @test occursin("DictWhole.ci: container-key(physical.cell)", dw)
    # finite-type provenance names the type.
    ce = sprint(io -> D.derivation_report(io, _DM.ColorEv))
    @test occursin("finite-type(", ce)
    be = sprint(io -> D.derivation_report(io, _DM.BoolEv))
    @test occursin("BoolEv.active: finite-type(Bool)", be)
    # explicit provenance is labeled explicit even when inference could apply.
    oe = sprint(io -> D.derivation_report(io, _DM.OverrideEv))
    @test occursin("OverrideEv.idx: explicit", oe)
end

############################ @fragment inlining (Phase 7) ############################

@testset "derive @fragment container param widens; element param via evt.idx stays clean" begin
    specs = D.derivation_spec(_DM.FragScan)
    flag = specs[findfirst(s -> s.matchstr == Any[Member(:cell), MI, Member(:flag)], specs)]
    @test !D.spec_clean(flag)  # any_flagged's loop over the whole container taints the index
    value = specs[findfirst(s -> s.matchstr == Any[Member(:cell), MI, Member(:value)], specs)]
    @test D.spec_clean(value)
    @test value.indices == Any[D.FieldBinding(:idx)]  # substitution carried evt.idx into the helper
end

@testset "derive @fragment inlined helper generates events end-to-end" begin
    board = _DM.Board(3)
    gens = generators(_DM.FragScan)
    widened = _find_matchstr(gens, Any[Member(:cell), MI, Member(:flag)])
    @test _derive_multiset_equal(
        _derive_collect(widened, board, 2), Any[_DM.FragScan(1), _DM.FragScan(2), _DM.FragScan(3)]
    )
    clean = _find_matchstr(gens, Any[Member(:cell), MI, Member(:value)])
    @test _derive_collect(clean, board, 2) == Any[_DM.FragScan(2)]
end

@testset "derive @fragment two call sites are independent and bind their own fields" begin
    specs = D.derivation_spec(_DM.FragTwo)
    cleans = filter(s -> s.matchstr == Any[Member(:cell), MI, Member(:value)], specs)
    @test any(s -> s.indices == Any[D.FieldBinding(:idx)], cleans)
    @test any(s -> s.indices == Any[D.FieldBinding(:jdx)], cleans)
end

@testset "derive @fragment nested helper (a calls b) inlines to a clean read" begin
    specs = D.derivation_spec(_DM.FragNested)
    value = only(specs)
    @test value.matchstr == Any[Member(:cell), MI, Member(:value)]
    @test value.indices == Any[D.FieldBinding(:idx)]
    @test D.spec_clean(value)
end

@testset "derive @fragment result used as an index is tainted; inner read stays clean" begin
    specs = D.derivation_spec(_DM.FragIndex)
    flag = specs[findfirst(s -> s.matchstr == Any[Member(:cell), MI, Member(:flag)], specs)]
    @test !D.spec_clean(flag)  # cell[j].flag with j the helper's opaque return value
    @test flag.indices == Any[D.TaintedIndex()]
    value = specs[findfirst(s -> s.matchstr == Any[Member(:cell), MI, Member(:value)], specs)]
    @test D.spec_clean(value)  # cell[evt.idx].value read inside pick_value
    @test value.indices == Any[D.FieldBinding(:idx)]
end

@testset "derive precondition-recursion passing evt.field keeps a clean binding" begin
    specs = D.derivation_spec(_DM.FragOuter)
    value = only(specs)
    @test value.matchstr == Any[Member(:cell), MI, Member(:value)]
    @test D.spec_clean(value)
    @test value.indices == Any[D.FieldBinding(:ci)]  # FragInner's evt.ci -> caller's evt.ci
end

@testset "derive precondition-recursion passing a loop var yields a widened read" begin
    specs = D.derivation_spec(_DM.FragOuterLoop)
    inlined = specs[findfirst(
        s -> s.matchstr == Any[Member(:cell), MI, Member(:value)] && !D.spec_clean(s), specs
    )]
    @test inlined.indices == Any[D.TaintedIndex()]  # FragInner(i) with i the caller's loop var
end

@testset "derive reducer over a generator walks the generator body" begin
    specs = D.derivation_spec(_DM.FragReduce)
    flag = specs[findfirst(s -> s.matchstr == Any[Member(:cell), MI, Member(:flag)], specs)]
    @test !D.spec_clean(flag)  # k is a loop-var index inside any(... for k in ...)
    value = specs[findfirst(s -> s.matchstr == Any[Member(:cell), MI, Member(:value)], specs)]
    @test D.spec_clean(value)
    @test value.indices == Any[D.FieldBinding(:idx)]
end

############################ @fragment macro-time errors ############################

@testset "derive @fragment rejects varargs parameters" begin
    err = @test_throws LoadError @eval @fragment frag_varargs(xs...) = xs
    @test occursin("varargs", sprint(showerror, err.value.error))
end

@testset "derive @fragment rejects keyword arguments" begin
    err = @test_throws LoadError @eval @fragment frag_kwargs(x; k=1) = x + k
    @test occursin("keyword", sprint(showerror, err.value.error))
end

@testset "derive an unregistered helper with a state argument still errors" begin
    err = @test_throws LoadError @eval module UnregHelperMod
    using ChronoSim
    import ChronoSim: precondition, generators
    struct UnregEv <: SimEvent
        i::Int64
    end
    @precondition precondition(evt::UnregEv, state) = not_a_fragment(state.cell, evt.i)
    end
    @test occursin("opaque function", sprint(showerror, err.value.error))
end

@testset "derive precondition-recursion into an undefined event type errors" begin
    err = @test_throws LoadError @eval module RecUndefMod
    using ChronoSim
    import ChronoSim: precondition, generators
    struct RecCaller <: SimEvent
        i::Int64
    end
    @precondition precondition(evt::RecCaller, state) = precondition(NeverDefinedEvt(evt.i), state)
    end
    @test occursin("not defined", sprint(showerror, err.value.error))
end

@testset "derive precondition-recursion with a constructor arity mismatch errors" begin
    err = @test_throws LoadError @eval module RecArityMod
    using ChronoSim
    import ChronoSim: precondition, generators
    struct ArInner <: SimEvent
        i::Int64
    end
    @precondition precondition(evt::ArInner, state) = state.cell[evt.i].value > 0
    struct ArOuter <: SimEvent
        i::Int64
    end
    @precondition precondition(evt::ArOuter, state) = precondition(ArInner(evt.i, evt.i), state)
    end
    @test occursin("constructor argument", sprint(showerror, err.value.error))
end

@testset "derive precondition self-recursion errors with the cycle named" begin
    err = @test_throws LoadError @eval module RecCycleMod
    using ChronoSim
    import ChronoSim: precondition, generators
    struct SelfEv <: SimEvent
        i::Int64
    end
    @precondition precondition(evt::SelfEv, state) = precondition(SelfEv(evt.i), state)
    end
    @test occursin("recursive @fragment inlining", sprint(showerror, err.value.error))
end

@testset "derive mutually recursive @fragment helpers error with the cycle named" begin
    err = @test_throws LoadError @eval module FragCycleMod
    using ChronoSim
    import ChronoSim: precondition, generators
    @fragment frag_a(cells, k) = frag_b(cells, k)
    @fragment frag_b(cells, k) = frag_a(cells, k)
    struct FragCycEv <: SimEvent
        i::Int64
    end
    @precondition precondition(evt::FragCycEv, state) = frag_a(state.cell, evt.i)
    end
    msg = sprint(showerror, err.value.error)
    @test occursin("recursive @fragment inlining", msg)
    @test occursin("frag_a -> frag_b -> frag_a", msg)
end

@testset "derive a reducer applied to a bare state container still errors" begin
    err = @test_throws LoadError @eval module ReducerBareMod
    using ChronoSim
    import ChronoSim: precondition, generators
    struct BareRedEv <: SimEvent
        i::Int64
    end
    @precondition precondition(evt::BareRedEv, state) = any(some_predicate, state.cell)
    end
    @test occursin("opaque function", sprint(showerror, err.value.error))
end
