using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: NextReactionMethod
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!
using ChronoSim: WriterIndex, last_writer, value_at, TrajectorySkeleton,
    SkeletonInit, SkeletonStep, EnableRecord, RecordSkeleton, recorded_skeleton,
    CheckInvariants, PolicyStack, InvariantViolation, clock_key

# The 1b/1c race and flip fixtures (SkeletonRace, SkeletonFlip) and 1d's TwinFlag
# are submodules of ChronoSimTests, in scope here at test-run time regardless of
# include order (all references live inside function/testset bodies).

########## Purpose-built fixtures ##########

# WhyGate: a gate that is proposed but never admitted. Tick fires perpetually,
# toggling cell.a (proposes Gate/GateHand, whose precondition a>=3 is never true)
# and cell.b (proposes Tick and GateB, whose precondition b>=3 is never true).
# init writes only b, so Gate (reads a) is first proposed at the first Tick step
# (a Tick writer), while GateB (reads b) is already proposed at init. Sleep reads
# c, which nothing ever writes, so Sleep is never proposed.
module WhyGate
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

@keyedby GateCell Int64 begin
    a::Int64
    b::Int64
    c::Int64
end

@observedphysical GateBoard begin
    cell::ObservedVector{GateCell,Member}
end

function GateBoard(n::Int)
    cells = ObservedArray{GateCell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = GateCell(0, 0, 0)
    end
    return GateBoard(cells)
end

struct Tick <: SimEvent
    idx::Int64
end
@precondition precondition(evt::Tick, state) = state.cell[evt.idx].b >= 0
enable(::Tick, state, when) = (Exponential(1.0), when)
function fire!(evt::Tick, state, when, rng)
    state.cell[evt.idx].a = 1 - state.cell[evt.idx].a
    state.cell[evt.idx].b = 1 - state.cell[evt.idx].b
    return nothing
end

struct Gate <: SimEvent
    idx::Int64
end
@precondition precondition(evt::Gate, state) = state.cell[evt.idx].a >= 3
enable(::Gate, state, when) = (Exponential(1.0), when)
fire!(evt::Gate, state, when, rng) = (state.cell[evt.idx].c += 1; nothing)

# Hand-written twin of Gate (no @precondition, so guard_clauses falls back).
struct GateHand <: SimEvent
    idx::Int64
end
@conditionsfor GateHand begin
    @reactto changed(cell[idx].a) do state
        generate(GateHand(idx))
    end
end
precondition(evt::GateHand, state) = state.cell[evt.idx].a >= 3
enable(::GateHand, state, when) = (Exponential(1.0), when)
fire!(evt::GateHand, state, when, rng) = (state.cell[evt.idx].c += 1; nothing)

# Proposed and rejected at init (reads b, which init writes).
struct GateB <: SimEvent
    idx::Int64
end
@precondition precondition(evt::GateB, state) = state.cell[evt.idx].b >= 3
enable(::GateB, state, when) = (Exponential(1.0), when)
fire!(evt::GateB, state, when, rng) = (state.cell[evt.idx].c += 1; nothing)

# Never proposed: reads c, which nothing writes.
struct Sleep <: SimEvent
    idx::Int64
end
@precondition precondition(evt::Sleep, state) = state.cell[evt.idx].c >= 3
enable(::Sleep, state, when) = (Exponential(1.0), when)
fire!(evt::Sleep, state, when, rng) = (state.cell[evt.idx].a += 1; nothing)

function init!(state, when, rng)
    state.cell[1].b = 1
    return nothing
end
end # module WhyGate

# WhyBlind: a hand-written Blocked(idx) reacting only to changed(cell[idx].a),
# whose plain precondition also reads cell[idx].b (a seeded missing trigger).
# Bump writes cell[2].a (index near-miss vs the queried Blocked(1)'s (cell,1,a)
# trigger) and cell[1].b (container near-miss + the missing trigger). cell[1].a
# is never written, so Blocked(1) is never proposed.
module WhyBlind
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

@keyedby BlindCell Int64 begin
    a::Int64
    b::Int64
end

@observedphysical BlindBoard begin
    cell::ObservedVector{BlindCell,Member}
end

function BlindBoard(n::Int)
    cells = ObservedArray{BlindCell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = BlindCell(0, 0)
    end
    return BlindBoard(cells)
end

struct Blocked <: SimEvent
    idx::Int64
end
@conditionsfor Blocked begin
    @reactto changed(cell[idx].a) do state
        generate(Blocked(idx))
    end
end
# Reads both a and b unconditionally (no short-circuit), so b appears in the
# true read set even when a fails the threshold.
function precondition(evt::Blocked, state)
    av = state.cell[evt.idx].a
    bv = state.cell[evt.idx].b
    return av >= 3 && bv >= 3
end
enable(::Blocked, state, when) = (Exponential(1.0), when)
fire!(evt::Blocked, state, when, rng) = (state.cell[evt.idx].b += 1; nothing)

struct Bump <: SimEvent end
@precondition precondition(evt::Bump, state) = state.cell[2].a >= 0
enable(::Bump, state, when) = (Exponential(1.0), when)
function fire!(evt::Bump, state, when, rng)
    state.cell[2].a = 1 - state.cell[2].a
    state.cell[1].b = 1 - state.cell[1].b
    return nothing
end

function init!(state, when, rng)
    state.cell[2].a = 1
    return nothing
end
end # module WhyBlind

# WhyShapes: every address shape value_at must walk.
module WhyShapes
using ChronoSim
using ChronoSim.ObservedState

@enum Dir up down

@keyedby SCell Int64 begin
    v::Int64
end
@keyedby DCell Tuple{Int64,Dir} begin
    w::Int64
end

@observedphysical ShapeState begin
    cell::ObservedVector{SCell,Member}
    dict::ObservedDict{Tuple{Int64,Dir},DCell,Member}
    scalar::Int64
end

function ShapeState(n::Int)
    cells = ObservedArray{SCell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = SCell(10 * i)
    end
    d = ObservedDict{Tuple{Int64,Dir},DCell,Member}()
    d[(1, up)] = DCell(77)
    return ShapeState(cells, d, 42)
end
end # module WhyShapes

########## Sim / factory helpers ##########

function _why_race_sim(policy; seed=0)
    return SimulationFSM(
        SkeletonRace.RaceBoard(1), [SkeletonRace.FireA, SkeletonRace.FireB];
        rng=Xoshiro(seed), sampler=NextReactionMethod(), key_type=Tuple, policy=policy)
end
_why_race_factory(policy) = (_why_race_sim(policy; seed=999), SkeletonRace.init!)
function _why_record_race(n; seed)
    rec = RecordSkeleton()
    sim = _why_race_sim(rec; seed=seed)
    ChronoSim.run(sim, SkeletonRace.init!, (p, i, e, w) -> i > n)
    return recorded_skeleton(rec)
end

function _why_flip_sim(policy; seed=0)
    return SimulationFSM(
        SkeletonFlip.WakeBoard(1), [SkeletonFlip.WakeFast, SkeletonFlip.WakeSlow];
        rng=Xoshiro(seed), sampler=NextReactionMethod(), key_type=Tuple, policy=policy)
end
_why_flip_factory(policy) = (_why_flip_sim(policy; seed=999), SkeletonFlip.init!)
function _why_record_flip(; seed)
    rec = RecordSkeleton()
    sim = _why_flip_sim(rec; seed=seed)
    ChronoSim.run(sim, SkeletonFlip.init!, (p, i, e, w) -> false)
    return recorded_skeleton(rec)
end

const _GATE_EVENTS =
    [WhyGate.Tick, WhyGate.Gate, WhyGate.GateHand, WhyGate.GateB, WhyGate.Sleep]
function _why_gate_sim(policy; seed=0)
    return SimulationFSM(WhyGate.GateBoard(1), _GATE_EVENTS;
        rng=Xoshiro(seed), sampler=NextReactionMethod(), key_type=Tuple, policy=policy)
end
_why_gate_factory(policy) = (_why_gate_sim(policy; seed=999), WhyGate.init!)
function _why_record_gate(n; seed)
    rec = RecordSkeleton()
    sim = _why_gate_sim(rec; seed=seed)
    ChronoSim.run(sim, WhyGate.init!, (p, i, e, w) -> i > n)
    return recorded_skeleton(rec)
end

function _why_blind_sim(policy; seed=0)
    return SimulationFSM(WhyBlind.BlindBoard(2), [WhyBlind.Blocked, WhyBlind.Bump];
        rng=Xoshiro(seed), sampler=NextReactionMethod(), key_type=Tuple, policy=policy)
end
_why_blind_factory(policy) = (_why_blind_sim(policy; seed=999), WhyBlind.init!)
function _why_record_blind(n; seed)
    rec = RecordSkeleton()
    sim = _why_blind_sim(rec; seed=seed)
    ChronoSim.run(sim, WhyBlind.init!, (p, i, e, w) -> i > n)
    return recorded_skeleton(rec)
end

# A hand-constructed skeleton literal for last_writer semantics.
function _hand_skeleton()
    CK = Tuple
    mem(s) = (Member(s),)
    init = SkeletonInit{CK}(0.0, Tuple[mem(:x)], EnableRecord{CK}[], CK[], CK[])
    s1 = SkeletonStep{CK}((:E, 1), 1.0, Tuple[mem(:y)],
        EnableRecord{CK}[], CK[], CK[])
    s2 = SkeletonStep{CK}((:E, 2), 2.0, Tuple[mem(:y)],
        EnableRecord{CK}[], CK[], CK[])
    return TrajectorySkeleton{CK}(UInt64(0), nothing, init, [s1, s2])
end

########## Tests ##########

@testset "last_writer semantics" begin
    skel = _hand_skeleton()
    @test last_writer(skel, (Member(:x),)) == (step=0, clock=:init, when=0.0)
    # y written at steps 1 and 2.
    @test last_writer(skel, (Member(:y),); at_step=1) == (step=1, clock=(:E, 1), when=1.0)
    @test last_writer(skel, (Member(:y),); at_step=2) == (step=2, clock=(:E, 2), when=2.0)
    @test last_writer(skel, (Member(:y),)) == (step=2, clock=(:E, 2), when=2.0)
    @test last_writer(skel, (Member(:z),)) === nothing
    @test_throws ArgumentError last_writer(skel, (Member(:y),); at_step=-1)
    @test_throws ArgumentError last_writer(skel, (Member(:y),); at_step=3)
end

@testset "writer index equals skeleton method" begin
    skel = _why_record_race(30; seed=424242)
    addrs = Set{Tuple}()
    union!(addrs, skel.init.changed)
    for s in skel.steps
        union!(addrs, s.changed)
    end
    wi = WriterIndex(skel)
    for a in addrs
        @test last_writer(wi, a) == last_writer(skel, a)
    end
end

@testset "value_at walks every address shape" begin
    s = WhyShapes.ShapeState(2)
    @test value_at(s, (Member(:cell), 1, Member(:v))) == 10
    @test value_at(s, (Member(:dict), (1, WhyShapes.up), Member(:w))) == 77
    @test value_at(s, (Member(:scalar),)) == 42
    @test length(value_at(s, (Member(:cell),))) == 2
    @test_throws KeyError value_at(s, (Member(:dict), (2, WhyShapes.down), Member(:w)))
end

@testset "whynot fired" begin
    skel = _why_record_race(40; seed=12345)
    rep = whynot(skel, _why_race_factory, SkeletonRace.FireA(1))
    fired = [i for (i, st) in enumerate(skel.steps) if st.clock == (:FireA, 1)]
    @test rep.stage == :fired
    @test rep.detail.count == length(fired)
    @test length(rep.detail.occurrences) <= 6
    @test rep.detail.occurrences[end] == (fired[end], skel.steps[fired[end]].when)
end

@testset "whynot enabled never fired" begin
    skel = _why_record_flip(; seed=1234)
    rep = whynot(skel, _why_flip_factory, SkeletonFlip.WakeSlow(1))
    @test rep.stage == :enabled_never_fired
    d = rep.detail
    @test length(d.intervals) == 1
    @test d.intervals[1].close_kind == :disabled
    @test d.intervals[1].close_when == skel.steps[1].when
    @test d.preempted_by == [:WakeFast => 1]
    @test d.distributions[1][1] == "Exponential"
    @test d.sampled_time_note == "not exposed by sampler (v1)"
end

@testset "whynot rejected names the clause" begin
    skel = _why_record_gate(30; seed=7777)
    rep = whynot(skel, _why_gate_factory, WhyGate.Gate(1))
    @test rep.stage == :rejected
    @test rep.detail.rejection_steps ==
        [i for i in 0:length(skel.steps) if (:Gate, 1) in ChronoSim._stepish(skel, i).proposed]
    @test length(rep.detail.examined) <= 6
    first_case = rep.detail.examined[1]
    @test first_case.clause_analysis == :clauses
    @test occursin("a >= 3", first_case.failing_clause)
    ra = findfirst(r -> r.address == (Member(:cell), 1, Member(:a)), first_case.reads)
    @test ra !== nothing
    @test first_case.reads[ra].writer.clock[1] == :Tick
end

@testset "whynot rejected hand-written fallback" begin
    skel = _why_record_gate(30; seed=7777)
    rep = whynot(skel, _why_gate_factory, WhyGate.GateHand(1))
    @test rep.stage == :rejected
    first_case = rep.detail.examined[1]
    @test first_case.clause_analysis == :whole_precondition
    @test first_case.verdict === false
    @test !isempty(first_case.reads)
end

@testset "whynot never proposed missing trigger" begin
    skel = _why_record_blind(40; seed=31337)
    rep = whynot(skel, _why_blind_factory, WhyBlind.Blocked(1))
    @test rep.stage == :never_proposed
    @test rep.detail.trigger_source == :hand_written
    @test (Member(:cell), 1, Member(:b)) in rep.detail.missing_triggers
    @test any(nm -> nm.address == (Member(:cell), 2, Member(:a)) &&
                    nm.class == :index_near_miss, rep.detail.near_misses)
end

@testset "whynot never proposed derived instantiation" begin
    skel = _why_record_gate(20; seed=7777)
    rep = whynot(skel, _why_gate_factory, WhyGate.Sleep(1))
    @test rep.stage == :never_proposed
    @test rep.detail.trigger_source == :derivation_spec
    @test (Member(:cell), 1, Member(:c)) in rep.detail.required
    @test rep.detail.missing_triggers == []
end

@testset "whynot rejection at init" begin
    skel = _why_record_gate(20; seed=7777)
    rep = whynot(skel, _why_gate_factory, WhyGate.GateB(1))
    @test rep.stage == :rejected
    @test 0 in rep.detail.rejection_steps
    @test any(c -> c.step == 0, rep.detail.examined)
end

@testset "whynot show bounded" begin
    fired = whynot(_why_record_race(40; seed=12345), _why_race_factory, SkeletonRace.FireA(1))
    enabled = whynot(_why_record_flip(; seed=1234), _why_flip_factory, SkeletonFlip.WakeSlow(1))
    rejected = whynot(_why_record_gate(30; seed=7777), _why_gate_factory, WhyGate.Gate(1))
    nproposed = whynot(_why_record_blind(40; seed=31337), _why_blind_factory, WhyBlind.Blocked(1))
    for rep in (fired, enabled, rejected, nproposed)
        block = sprint(show, MIME"text/plain"(), rep)
        @test count(==('\n'), block) <= 30
    end
    @test occursin("(cell, 1", sprint(show, MIME"text/plain"(), nproposed))
end

@testset "whynot show worst case bounded" begin
    # Synthetic maximal :never_proposed payload: 8 declared triggers, 8 true
    # reads, 7 missing triggers, 6 near-misses, precondition_now === true, an
    # exact-hit anomaly, and an over-long note. The fixture-based show test
    # cannot reach this shape; the ≤30-line budget must hold here too.
    mk(i) = (Member(:cell), i, Member(:a))
    nm(i, cls) = (address=mk(i), step=i, clock=(:E, i), when=Float64(i), class=cls)
    detail = (trigger_source=:hand_written,
        required=Tuple[mk(i) for i in 1:8],
        fired_triggers=Symbol[:Foo, :Bar],
        true_reads=Tuple[mk(i) for i in 1:8],
        precondition_now=true,
        missing_triggers=Tuple[mk(i) for i in 1:7],
        near_misses=[nm(i, :index_near_miss) for i in 1:6],
        near_miss_total=9,
        exact_hits=[nm(9, :exact)],
        note="n"^300)
    rep = ChronoSim.WhynotReport((:Huge, 1), :never_proposed, 100, detail)
    block = sprint(show, MIME"text/plain"(), rep)
    @test count(==('\n'), block) <= 30
    @test occursin("... and 2 more", block)       # required/true_reads overflow (8 - 6)
    @test occursin("... and 1 more", block)       # missing_triggers overflow (7 - 6), no
                                                  # longer silently truncated
    @test occursin("exactly matched", block)      # exact hits surfaced, never dropped
    @test endswith(block, "…")                    # truncated note marked with an ellipsis
end

@testset "whynot rejected show anomaly and case tail" begin
    # verdict === true on a replayed rejection step contradicts the recorded
    # rejection (factory-mismatch smell): the readout says so instead of
    # printing a blank failing clause. With <= 2 examined cases the
    # "showing first and last" tail is omitted.
    case_true = (step=3, when=1.0, clause_analysis=:clauses, verdict=true,
        clauses=Tuple{String,Any}[("a >= 3", true)], failing_clause="",
        reads=[(address=(Member(:cell), 1, Member(:a)), value=3, writer=nothing)])
    detail = (n_proposals=1, rejection_steps=[3], examined=[case_true])
    rep = ChronoSim.WhynotReport((:E, 1), :rejected, 10, detail)
    block = sprint(show, MIME"text/plain"(), rep)
    @test !occursin("showing first and last", block)
    @test occursin("contradicts the recorded rejection", block)
    @test !occursin("failing clause :", block)
    @test count(==('\n'), block) <= 30
    # A many-case report keeps the tail.
    case_false = (step=5, when=2.0, clause_analysis=:clauses, verdict=false,
        clauses=Tuple{String,Any}[("a >= 3", false)], failing_clause="a >= 3",
        reads=[(address=(Member(:cell), 1, Member(:a)), value=0, writer=nothing)])
    many = ChronoSim.WhynotReport((:E, 1), :rejected, 10,
        (n_proposals=3, rejection_steps=[3, 4, 5],
         examined=[case_false, case_false, case_false]))
    @test occursin("showing first and last", sprint(show, MIME"text/plain"(), many))
end

@testset "whystopped violation with unsealed skeleton" begin
    # Recorder AFTER CheckInvariants in the stack: a step-1 violation carries a
    # skeleton whose violating step is not sealed (0 recorded steps). The
    # prior-writer query must degrade to `nothing`, not throw ArgumentError.
    CK = Tuple
    addr = (Member(:cell), 1, Member(:b))
    init = SkeletonInit{CK}(0.0, Tuple[addr], EnableRecord{CK}[], CK[], CK[])
    skel = TrajectorySkeleton{CK}(UInt64(0), nothing, init, SkeletonStep{CK}[])
    v = InvariantViolation("a xor b", TwinFlag, LineNumberNode(1, :here), 1,
        (:Corrupt, 1), 0.5, Tuple[addr], Tuple[addr], Tuple[addr],
        true, skel, nothing)
    rep = whystopped(v)
    @test rep.kind == :invariant_violation
    @test rep.guilty[1].writer == (step=0, clock=:init, when=0.0)
    @test rep.guilty[1].prior_writer === nothing
end

@testset "whyrunning reads writers and stub" begin
    skel = _why_record_race(40; seed=222)
    sim = replay(_why_race_factory, skel)
    rep = whyrunning(sim, skel, p -> p.cell[1].b > 1_000_000)
    @test rep.predicate_value == false
    @test rep.reads[1].address == (Member(:cell), 1, Member(:b))
    @test rep.reads[1].value == sim.physical.cell[1].b
    @test rep.reads[1].writer !== nothing
    @test rep.reachability == "reachability analysis requires effect analysis (not yet run)"
    @test occursin("reachability analysis requires effect analysis (not yet run)",
        sprint(show, MIME"text/plain"(), rep))
end

@testset "whyrunning window and intersection" begin
    skel = _why_record_race(60; seed=222)
    n = length(skel.steps)
    sim = replay(_why_race_factory, skel)
    rep = whyrunning(sim, skel, p -> p.cell[1].a > 1_000_000)
    @test rep.window == max(1, n - 49):n
    @test !isempty(rep.predicate_writes_in_window)
    @test all(pw -> pw.address == (Member(:cell), 1, Member(:a)), rep.predicate_writes_in_window)
    @test rep.top_events[1].event in (:FireA, :FireB)
    @test rep.top_events[1].count >= rep.top_events[end].count
end

@testset "whyrunning four-arg predicate and true predicate" begin
    skel = _why_record_race(30; seed=222)
    sim = replay(_why_race_factory, skel)
    rep = whyrunning(sim, skel, (p, i, e, w) -> w > 0)
    @test rep.predicate_value == true
    @test occursin("TRUE", sprint(show, MIME"text/plain"(), rep))
end

@testset "whyrunning rejects stale sim" begin
    skel = _why_record_race(30; seed=222)
    sim = replay(_why_race_factory, skel; upto=10)
    @test_throws ArgumentError whyrunning(sim, skel, p -> p.cell[1].b > 10)
end

@testset "whystopped violation forensics" begin
    rec = RecordSkeleton()
    policy = PolicyStack(rec, CheckInvariants(TwinFlag))
    sim = SimulationFSM(TwinFlag.FlagBoard(1), [TwinFlag.Tick, TwinFlag.Corrupt];
        rng=Xoshiro(1234), sampler=NextReactionMethod(), key_type=Tuple, policy=policy)
    err = try
        ChronoSim.run(sim, TwinFlag.init!, (p, i, e, w) -> false)
        nothing
    catch e
        e
    end
    @test err isa InvariantViolation
    rep = whystopped(err)
    @test rep.kind == :invariant_violation
    @test rep.guilty[1].writer.clock == (:Corrupt, 1)
    @test rep.guilty[1].prior_writer.step < rep.step
    @test rep.replay_command == err.replay_command
    @test count(==('\n'), sprint(show, MIME"text/plain"(), rep)) <= 30
end

@testset "whystopped end of run" begin
    race = _why_record_race(30; seed=222)
    rep = whystopped(race)
    @test rep.kind == :end_of_run
    @test rep.verdict == :stopped_while_events_enabled
    @test length(rep.still_enabled) == 2
    flip = _why_record_flip(; seed=1234)
    frep = whystopped(flip)
    @test frep.verdict == :no_events_enabled
    @test frep.still_enabled == []
end
