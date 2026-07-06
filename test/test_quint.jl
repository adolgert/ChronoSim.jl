using ReTest
using ChronoSim
using ChronoSim.ObservedState
using Distributions
using Random
import ChronoSim: precondition, enable, fire!, generators

# Self-contained fixture exercising the schema/printer/effect surface: a 2-field
# @keyedby vector, a tuple-keyed dict with a single-field (collapsing) element, an
# ObservedSet field, a written scalar (var) and an unwritten scalar (promoted
# const), a Param const, one enum, and a Float64 field (erased). @precondition /
# @fire / @fragment / @invariant are real (Phase 2 landed), so nothing is stubbed.
module QuintFix
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, enable, fire!

@enum Color red green blue

@keyedby Cell Int64 begin
    value::Int64
    active::Bool
end

@keyedby Tag Tuple{Int64,Color} begin
    marked::Bool
end

@observedphysical Board begin
    cells::ObservedVector{Cell,Member}
    tags::ObservedDict{Tuple{Int64,Color},Tag,Member}
    flags::ObservedSet{Int64,Member}
    counter::Int64
    capacity::Int64
    limit::Param{Int64}
    temperature::Float64
end

function Board(n::Int)
    cells = ObservedArray{Cell,Member}(undef, n)
    for i in 1:n
        cells[i] = Cell(i, true)
    end
    tags = ObservedDict{Tuple{Int64,Color},Tag,Member}()
    Board(cells, tags, ObservedSet{Int64,Member}(), 0, 100, 100, 20.0)
end

@fragment double(x) = x * 2

struct Bump <: SimEvent
    i::Int64
end
@precondition function precondition(evt::Bump, state)
    c = state.cells[evt.i]
    return c.value >= 1 && c.active && double(c.value) <= state.capacity
end
enable(::Bump, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::Bump, state, when, rng)
    c = state.cells[evt.i]
    c.value += 1
    state.counter += 1
end

# an event whose guard reads a Float64 field -> :float_read
struct Warm <: SimEvent
    i::Int64
end
@precondition function precondition(evt::Warm, state)
    return state.temperature >= 1.0 && state.cells[evt.i].active
end
enable(::Warm, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::Warm, state, when, rng)
    state.cells[evt.i].value += 1
end

@invariant "values nonneg" function (physical)
    all(c.value >= 0 for c in physical.cells)
end
@invariant "temp gate" function (physical)
    all(physical.temperature >= 0.0 || c.active for c in physical.cells)
end

# ---- fixtures for the refusal / idiom testsets ----

# the reviewer's miscompilation reproduction: a loop whose element write reads a
# scalar the same loop increments (Julia: 10,11; independent folds: 10,10)
struct Overlap <: SimEvent
    i::Int64
end
@precondition precondition(evt::Overlap, state) = state.cells[evt.i].value >= 0
enable(::Overlap, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::Overlap, state, when, rng)
    for i in eachindex(state.cells)
        state.cells[i].value = state.counter
        state.counter += 1
    end
end

# a @fragment whose body is outside the fragment (while loop): its refusal must
# gather into the QuintCompileError, naming the helper
@fragment function spin(x)
    while x > 0
        x -= 1
    end
    return x
end
struct Spinner <: SimEvent
    i::Int64
end
@precondition precondition(evt::Spinner, state) = spin(state.cells[evt.i].value) == 0
enable(::Spinner, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::Spinner, state, when, rng)
    state.counter += 1
end

# min-by over an unordered dict-key domain -> :unordered_fold (D8 v1 ruling)
struct DictScan <: SimEvent
    i::Int64
end
@precondition precondition(evt::DictScan, state) = state.cells[evt.i].value >= 0
enable(::DictScan, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::DictScan, state, when, rng)
    cnt = 0
    for k in keys(state.tags)
        if state.tags[k].marked
            cnt += 1
        end
    end
    state.counter = cnt
end

# integer bitwise -> :bitwise_int; Bool & / | lower to and/or
struct Parity <: SimEvent
    i::Int64
end
@precondition precondition(evt::Parity, state) = (evt.i & 1) == 0 && state.cells[evt.i].active
enable(::Parity, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::Parity, state, when, rng)
    state.counter += 1
end

struct BoolOps <: SimEvent
    i::Int64
end
@precondition function precondition(evt::BoolOps, state)
    c = state.cells[evt.i]
    return (c.active & (c.value > 0)) | false
end
enable(::BoolOps, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::BoolOps, state, when, rng)
    state.counter += 1
end

# loop idiom 2 (existential flag) and 3 (universal flag) in guards
struct AnyActive <: SimEvent
    i::Int64
end
@precondition function precondition(evt::AnyActive, state)
    found = false
    for k in eachindex(state.cells)
        if state.cells[k].active
            found = true
        end
    end
    return found && state.cells[evt.i].value > 0
end
enable(::AnyActive, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::AnyActive, state, when, rng)
    state.counter += 1
end

struct AllActive <: SimEvent
    i::Int64
end
@precondition function precondition(evt::AllActive, state)
    ok = true
    for k in eachindex(state.cells)
        if !state.cells[k].active
            ok = false
        end
    end
    return ok && state.cells[evt.i].value > 0
end
enable(::AllActive, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::AllActive, state, when, rng)
    state.counter += 1
end

# loop idiom 5, effect form: min-by over an ordered index range
struct PickMin <: SimEvent
    i::Int64
end
@precondition precondition(evt::PickMin, state) = state.cells[evt.i].value >= 0
enable(::PickMin, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::PickMin, state, when, rng)
    best = 0
    bestv = 1000
    for k in eachindex(state.cells)
        v = state.cells[k].value
        if v < bestv
            best = k
            bestv = v
        end
    end
    state.counter = best
end

# loop idiom 5, capped-and-breaking scan (the StartDay shape)
struct CapSweep <: SimEvent
    i::Int64
end
@precondition precondition(evt::CapSweep, state) = state.cells[evt.i].value >= 0
enable(::CapSweep, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::CapSweep, state, when, rng)
    n = 0
    for k in eachindex(state.cells)
        if state.cells[k].active
            state.cells[k].value = 0
            n += 1
            if n == 2
                break
            end
        end
    end
    state.counter = n
end

# precondition-recursion: two callers share one precond_Bump def (D12)
struct Wrap1 <: SimEvent
    i::Int64
end
@precondition function precondition(evt::Wrap1, state)
    return !precondition(Bump(evt.i), state) && state.cells[evt.i].value >= 0
end
enable(::Wrap1, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::Wrap1, state, when, rng)
    state.counter += 1
end

struct Wrap2 <: SimEvent
    i::Int64
end
@precondition function precondition(evt::Wrap2, state)
    return !precondition(Bump(evt.i), state) && state.cells[evt.i].value <= 100
end
enable(::Wrap2, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::Wrap2, state, when, rng)
    state.counter += 1
end

# branch-merge in an effect: exactly the written vars become if-expressions
struct Toggle <: SimEvent
    i::Int64
end
@precondition precondition(evt::Toggle, state) = state.cells[evt.i].value >= 0
enable(::Toggle, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::Toggle, state, when, rng)
    if state.cells[evt.i].active
        state.counter = state.counter + 1
    else
        state.cells[evt.i].value = 0
    end
end

# local rebinding before the return (SSA-by-inlining)
struct Rebind <: SimEvent
    i::Int64
end
@precondition function precondition(evt::Rebind, state)
    x = 1
    x = x + 2
    return state.cells[evt.i].value >= x
end
enable(::Rebind, s, w) = (Exponential(1.0), w)
@fire function fire!(evt::Rebind, state, when, rng)
    state.counter += 1
end
end # module QuintFix

# Two enums (in separate modules) sharing a constructor name: Quint sum-type
# constructors are bare names, so this is an `:enum_collision` refusal.
module QuintCollideA
@enum ColA shared_val a_only
end
module QuintCollideM
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, enable, fire!
using ..QuintCollideA: ColA
@enum ColB shared_val b_only
@observedphysical CollidePhys begin
    x::ColA
    y::ColB
end
struct CollideEvt <: SimEvent end
end # module QuintCollideM

const QF = QuintFix

@testset "quint schema and constants" begin
    board = QF.Board(3)
    qm = compile_quint(QF, [QF.Bump], board; name="fix")
    rep = qm.report
    # counter is written by Bump -> var; capacity is unwritten -> promoted const;
    # limit is a Param -> const; temperature is Float64 -> erased.
    @test :capacity in rep.promoted
    @test :counter ∉ rep.promoted
    @test any(occursin("temperature", e) for e in rep.erased)
    @test occursin("var counter: int", qm.text)
    @test occursin("pure val capacity = 100", qm.text)
    @test occursin("pure val limit = 100", qm.text)
    @test !occursin("temperature", qm.text)
end

@testset "quint enum and record types" begin
    qm = compile_quint(QF, [QF.Bump], QF.Board(3); name="fix")
    @test occursin("type Color = red | green | blue", qm.text)
    @test occursin("type Cell = { value: int, active: bool }", qm.text)
    # Tag has a single user field -> collapses; tags map value type is `bool`.
    @test (:Tag => :marked) in qm.report.collapsed
    @test !occursin("type Tag =", qm.text)   # collapsed records emit no record type
end

@testset "quint fragment as a def" begin
    qm = compile_quint(QF, [QF.Bump], QF.Board(3); name="fix")
    # @fragment double emitted once as a pure def and called in the guard.
    @test occursin("pure def double(", qm.text)
    @test occursin("double(", qm.text)
end

@testset "quint guard lowering" begin
    qm = compile_quint(QF, [QF.Bump], QF.Board(3); name="fix")
    # `c.value >= 1 and c.active and double(c.value) <= capacity` as all{} conjuncts.
    @test occursin("cells.get(i).value >= 1", qm.text)
    @test occursin("cells.get(i).active", qm.text)
    @test occursin("<= capacity", qm.text)
end

@testset "quint effect frame completeness" begin
    qm = compile_quint(QF, [QF.Bump], QF.Board(3); name="fix")
    body = qm.text
    # Every var is assigned exactly once inside ev_Bump_par.
    par = match(r"(?s)action ev_Bump_par.*?\n    \}"m, body)
    seg = par === nothing ? body : par.match
    for v in ("cells'", "tags'", "flags'", "counter'")
        @test occursin(v * " =", seg)
    end
    # counter increments; cells element updated.
    @test occursin("counter' = (counter + 1)", seg)
    @test occursin("cells.set(i, cells.get(i).with(\"value\"", seg)
end

@testset "quint float read refuses with explanation" begin
    err = try
        compile_quint(QF, [QF.Warm], QF.Board(3); name="fix")
        nothing
    catch e
        e
    end
    @test err isa QuintCompileError
    @test any(en -> en.category === :float_read, err.entries)
    msg = sprint(showerror, err)
    @test occursin("discrete jump skeleton", msg)
end

@testset "quint invariant float read refused-with-report" begin
    qm = compile_quint(QF, [QF.Bump], QF.Board(3); name="fix", invariants=QF)
    inv = qm.report.invariants
    @test any(i -> i.name == "values nonneg" && i.status === :clean, inv)
    @test any(i -> i.name == "temp gate" && i.status === :refused, inv)
    @test occursin("// REFUSED invariant \"temp gate\"", qm.text)
    @test occursin("inv_values_nonneg", qm.text)
end

@testset "quint value emitter canonical order" begin
    b1 = QF.Board(2)
    b1.tags[(2, QF.green)] = QF.Tag(true)
    b1.tags[(1, QF.red)] = QF.Tag(false)
    b2 = QF.Board(2)
    b2.tags[(1, QF.red)] = QF.Tag(false)
    b2.tags[(2, QF.green)] = QF.Tag(true)
    q1 = compile_quint(QF, [QF.Bump], b1; name="fix")
    q2 = compile_quint(QF, [QF.Bump], b2; name="fix")
    m1 = match(r"tags' = (Map\(.*?\))", q1.text)
    m2 = match(r"tags' = (Map\(.*?\))", q2.text)
    @test m1.captures[1] == m2.captures[1]   # insertion-order independent
end

@testset "quint widening reconciliation (zero silent widenings)" begin
    qm = compile_quint(QF, [QF.Bump], QF.Board(3); name="fix")
    nmark = count(_ -> true, eachmatch(r"// WIDENED", qm.text))
    @test nmark == length(qm.report.widenings)
end

@testset "quint mutation hook is local and recorded" begin
    qm0 = compile_quint(QF, [QF.Bump], QF.Board(3); name="fix")
    qmm = compile_quint(QF, [QF.Bump], QF.Board(3); name="fix",
        mutate_for_test=(event=:Bump, from=:>=, to=:>, occurrence=1))
    @test qmm.report.mutated != ""
    @test occursin("Bump", qmm.report.mutated)
    @test qm0.text != qmm.text        # the operator flip changed the emission
end

@testset "quint refusals gathered into one error" begin
    err = try
        compile_quint(QF, [QF.Bump, QF.Warm], QF.Board(3); name="fix", invariants=QF)
        nothing
    catch e
        e
    end
    @test err isa QuintCompileError
    # Warm's float read is one refusal; the error gathers all before throwing.
    @test length(err.entries) >= 1
end

@testset "quint skip_events / assume_true_guards" begin
    qm = compile_quint(QF, [QF.Bump, QF.Warm], QF.Board(3); name="fix",
        skip_events=[:Warm])
    @test qm.partial
    @test any(e -> e.name === :Warm && e.status === :skipped, qm.report.events)
    @test !occursin("ev_Warm", qm.text)
    # assume_true_guards compiles the guard as `true`.
    qm2 = compile_quint(QF, [QF.Bump], QF.Board(3); name="fix", assume_true_guards=[:Bump])
    @test any(e -> e.name === :Bump && e.status === :assumed_true_guard, qm2.report.events)
end

@testset "quint toolchain discovery" begin
    # With no CHRONOSIM_QUINT and no quint on PATH the checker is unavailable.
    withenv("CHRONOSIM_QUINT" => nothing, "PATH" => "") do
        tc = ChronoSim.find_quint_toolchain()
        @test tc.quint === nothing
    end
    # A directory with a node_modules/.bin/quint is found.
    d = mktempdir()
    mkpath(joinpath(d, "node_modules", ".bin"))
    binp = joinpath(d, "node_modules", ".bin", "quint")
    write(binp, "#!/bin/sh\n")
    chmod(binp, 0o755)
    tc2 = ChronoSim.find_quint_toolchain(; quint_dir=d, java_home=nothing)
    @test tc2.quint !== nothing
end

@testset "quint loop overlap refuses (reviewer reproduction)" begin
    # Julia assigns counter=10 then 11; independent folds would assign 10, 10 —
    # the compiler must refuse, never silently miscompile.
    err = try
        compile_quint(QF, [QF.Overlap], QF.Board(2); name="fix")
        nothing
    catch e
        e
    end
    @test err isa QuintCompileError
    ent = only(filter(e -> e.category === :loop_read_write_overlap, err.entries))
    @test ent.subject === :Overlap
    @test occursin("counter", ent.construct)
end

@testset "quint fragment refusal gathers (while-loop helper)" begin
    err = try
        compile_quint(QF, [QF.Spinner], QF.Board(2); name="fix")
        nothing
    catch e
        e
    end
    @test err isa QuintCompileError
    ent = only(filter(e -> e.category === :while_loop, err.entries))
    @test ent.subject === :spin              # the helper is named, not a raw abort
    @test occursin("while", ent.construct)
    @test ent.hint != ""
end

@testset "quint unordered fold refuses (D8 v1 ruling)" begin
    err = try
        compile_quint(QF, [QF.DictScan], QF.Board(2); name="fix")
        nothing
    catch e
        e
    end
    @test err isa QuintCompileError
    @test any(e -> e.category === :unordered_fold && e.subject === :DictScan, err.entries)
end

@testset "quint bitwise: int refuses, Bool lowers to and/or" begin
    err = try
        compile_quint(QF, [QF.Parity], QF.Board(2); name="fix")
        nothing
    catch e
        e
    end
    @test err isa QuintCompileError
    @test any(e -> e.category === :bitwise_int && e.subject === :Parity, err.entries)
    qm = compile_quint(QF, [QF.BoolOps], QF.Board(2); name="fix")
    @test occursin(".active and (", qm.text)
    @test occursin(" or false", qm.text)
end

@testset "quint enum collision refuses" begin
    phys = QuintCollideM.CollidePhys(QuintCollideA.shared_val, QuintCollideM.shared_val)
    err = try
        compile_quint(QuintCollideM, [QuintCollideM.CollideEvt], phys; name="collide")
        nothing
    catch e
        e
    end
    @test err isa QuintCompileError
    ent = only(err.entries)
    @test ent.category === :enum_collision
    @test occursin("shared_val", ent.construct)
    @test occursin("ColA", ent.construct) && occursin("ColB", ent.construct)
end

@testset "quint loop idioms 2 and 3 (exists / forall)" begin
    q2 = compile_quint(QF, [QF.AnyActive], QF.Board(3); name="fix")
    @test occursin(".exists(k => cells.get(k).active)", q2.text)
    q3 = compile_quint(QF, [QF.AllActive], QF.Board(3); name="fix")
    @test occursin(".forall(k => not(not(cells.get(k).active)))", q3.text) ||
          occursin(".forall(k =>", q3.text)
end

@testset "quint loop idiom 5: ordered min-by foldl" begin
    qm = compile_quint(QF, [QF.PickMin], QF.Board(3); name="fix")
    @test occursin("range(1, 4).foldl(", qm.text)     # 3 cells -> range(1, 4)
    @test occursin("best:", qm.text) && occursin("bestv:", qm.text)
    @test occursin("counter' = (range(1, 4).foldl(", qm.text)
end

@testset "quint loop idiom 5: capped scan with break (StartDay shape)" begin
    qm = compile_quint(QF, [QF.CapSweep], QF.Board(3); name="fix")
    @test occursin(".foldl({ cells: cells, n: 0, _stop: false }", qm.text)
    @test occursin("_stop:", qm.text)
    @test occursin("range(1, 4)", qm.text)
    # both the container and the counter project out of the same fold
    @test occursin(").cells", qm.text) && occursin(").n", qm.text)
end

@testset "quint precond recursion: one shared def for two callers" begin
    qm = compile_quint(QF, [QF.Bump, QF.Wrap1, QF.Wrap2], QF.Board(3); name="fix")
    @test count(_ -> true, eachmatch(r"pure def precond_Bump\(", qm.text)) == 1
    @test count(_ -> true, eachmatch(r"precond_Bump\(", qm.text)) == 3   # def + 2 calls
end

@testset "quint branch merge covers exactly the written vars" begin
    qm = compile_quint(QF, [QF.Toggle], QF.Board(3); name="fix")
    par = match(r"(?s)action ev_Toggle_par.*?\n    \}"m, qm.text).match
    @test occursin("counter' = (if (cells.get(i).active) (counter + 1) else counter)", par)
    @test occursin("cells' = (if (cells.get(i).active) cells else cells.set(i,", par)
    @test occursin("tags' = tags", par)               # untouched vars framed unchanged
end

@testset "quint local rebinding (SSA-by-inlining)" begin
    qm = compile_quint(QF, [QF.Rebind], QF.Board(3); name="fix")
    @test occursin(">= (1 + 2)", qm.text)             # the rebound local inlines its final value
end

@testset "quint mutation no-op occurrence leaves module untouched" begin
    qm0 = compile_quint(QF, [QF.Bump], QF.Board(3); name="fix")
    qmn = compile_quint(QF, [QF.Bump], QF.Board(3); name="fix",
        mutate_for_test=(event=:Bump, from=:>=, to=:>, occurrence=99))
    @test qmn.report.mutated == ""                    # occurrence never reached
    @test qmn.text == qm0.text
    # and a mutation naming an event whose guard lacks `from` entirely
    qmx = compile_quint(QF, [QF.Bump], QF.Board(3); name="fix",
        mutate_for_test=(event=:Bump, from=:<, to=:<=, occurrence=1))
    @test qmx.report.mutated == ""
    @test qmx.text == qm0.text
end

@testset "quint partial module marking" begin
    qm = compile_quint(QF, [QF.Bump, QF.Warm], QF.Board(3); name="fix", skip_events=[:Warm])
    @test qm.partial
    @test occursin("// PARTIAL: skipped events (skip_events): Warm", qm.text)
end

@testset "quint validate_trace convenience form rejects unknown kwargs" begin
    # (qualified: the legacy test/elevatortla.jl exports an unrelated `validate_trace`)
    @test_throws ArgumentError ChronoSim.validate_trace(QF, [QF.Bump], QF.Board(3),
        nothing, identity; bogus=1)
end

@testset "quint stage-1 failure localization parses the violated state" begin
    # A deterministic trace run prints t_i per state; the LAST t_i names the
    # violating recorded state (t_i = n -> TraceStates[n-1] -> step n-1).
    CK = Tuple
    ER = ChronoSim.EnableRecord{CK}
    steps = [ChronoSim.SkeletonStep{CK}((:EvtA, 1), 1.5, Tuple[], ER[], CK[], CK[]),
             ChronoSim.SkeletonStep{CK}((:EvtB, 2), 2.5, Tuple[], ER[], CK[], CK[])]
    skel = TrajectorySkeleton{CK}(Xoshiro(1), nothing,
        ChronoSim.SkeletonInit{CK}(0.0, Tuple[], ER[], CK[], CK[]), steps)
    log = joinpath(mktempdir(), "s1.log")
    write(log, "[State 0]\n  t_i: 1\n[State 1]\n  t_i: 2\n[State 2]\n  t_i: 3\n[violation]\n")
    ff = ChronoSim._stage1_failure(log, skel)
    @test ff.step == 2 && ff.event === :EvtB && ff.when == 2.5 && ff.stage === :invariants
    # a violation at the initial state names :__init__
    write(log, "[State 0]\n  t_i: 1\n[violation]\n")
    ff0 = ChronoSim._stage1_failure(log, skel)
    @test ff0.step == 0 && ff0.event === :__init__
end

@testset "quint toolchain skip text" begin
    # The install instructions quoted on a :skipped verdict name the pinned versions.
    @test occursin("@informalsystems/quint@0.32.0", ChronoSim._INSTALL_QUINT)
    @test occursin("Temurin", ChronoSim._INSTALL_JAVA)
    @test occursin("JAVA_HOME", ChronoSim._INSTALL_JAVA)
    # An unavailable toolchain reports neither checker.
    tc = ChronoSim.QuintToolchain(nothing, nothing, Dict{String,String}())
    @test !ChronoSim.quint_available(tc)
    @test !ChronoSim.java_available(tc)
end
