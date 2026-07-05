using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: CombinedNextReaction
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

# The verified two-clock exponential race (same shape as test_trace_eval.jl's
# fixture). Both clocks are perpetually enabled, so the trajectory is a competing
# exponential race with rates LA and LB. Firing an event increments its field,
# re-proposing it through its derived generator so the survivor keeps running.
module SkeletonRace
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

const LA = 2.0
const LB = 3.0

@keyedby RaceCell Int64 begin
    a::Int64
    b::Int64
end

@observedphysical RaceBoard begin
    cell::ObservedVector{RaceCell,Member}
end

function RaceBoard(n::Int)
    cells = ObservedArray{RaceCell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = RaceCell(0, 0)
    end
    return RaceBoard(cells)
end

struct FireA <: SimEvent
    idx::Int64
end
@precondition precondition(evt::FireA, state) = state.cell[evt.idx].a >= 0
enable(::FireA, state, when) = (Exponential(1 / LA), when)
fire!(evt::FireA, state, when, rng) = (state.cell[evt.idx].a += 1; nothing)

struct FireB <: SimEvent
    idx::Int64
end
@precondition precondition(evt::FireB, state) = state.cell[evt.idx].b >= 0
enable(::FireB, state, when) = (Exponential(1 / LB), when)
fire!(evt::FireB, state, when, rng) = (state.cell[evt.idx].b += 1; nothing)

function init!(state, when, rng)
    state.cell[1].a = 0
    state.cell[1].b = 0
    return nothing
end
end # module

# A guard-flip pair: WakeFast and WakeSlow are both enabled while a cell's phase
# is idle; firing either flips the phase to active, which preemptively disables
# the sibling clock. WakeFast has a much higher rate so it wins deterministically.
module SkeletonFlip
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

@enum WakePhase pidle pactive

const RATE_FAST = 10.0
const RATE_SLOW = 0.1

@keyedby WakeCell Int64 begin
    phase::WakePhase
end

@observedphysical WakeBoard begin
    cell::ObservedVector{WakeCell,Member}
end

function WakeBoard(n::Int)
    cells = ObservedArray{WakeCell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = WakeCell(pidle)
    end
    return WakeBoard(cells)
end

struct WakeFast <: SimEvent
    idx::Int64
end
@precondition precondition(evt::WakeFast, state) = state.cell[evt.idx].phase == pidle
enable(::WakeFast, state, when) = (Exponential(1 / RATE_FAST), when)
fire!(evt::WakeFast, state, when, rng) = (state.cell[evt.idx].phase = pactive; nothing)

struct WakeSlow <: SimEvent
    idx::Int64
end
@precondition precondition(evt::WakeSlow, state) = state.cell[evt.idx].phase == pidle
enable(::WakeSlow, state, when) = (Exponential(1 / RATE_SLOW), when)
fire!(evt::WakeSlow, state, when, rng) = (state.cell[evt.idx].phase = pactive; nothing)

function init!(state, when, rng)
    for i in eachindex(state.cell)
        state.cell[i].phase = pidle
    end
    return nothing
end
end # module

# Fixture names (RaceBoard/FireA/WakeFast/LA/...) intentionally match the
# fixtures in test_policy.jl and test_trace_eval.jl, so they are referenced
# module-qualified to avoid clobbering those files' bare imports.
const _LA = SkeletonRace.LA
const _LB = SkeletonRace.LB

# Build and run a race sim recording a skeleton; return (policy, observer_trace).
# The observer pushes (clock_key(evt), when) for every observed event, including
# the initial InitializeEvent (index 1).
function _race_run(n::Int; seed::Int, metadata=nothing)
    rec = RecordSkeleton(; metadata=metadata)
    obs_traj = Tuple{Tuple,Float64}[]
    observer = (p, when, evt, changed) -> push!(obs_traj, (clock_key(evt), when))
    sim = SimulationFSM(
        SkeletonRace.RaceBoard(1), [SkeletonRace.FireA, SkeletonRace.FireB];
        rng=Xoshiro(seed), sampler=CombinedNextReaction{Tuple,Float64}(),
        observer=observer, policy=rec,
    )
    stop = (p, i, e, w) -> i > n
    ChronoSim.run(sim, SkeletonRace.init!, stop)
    return rec, obs_traj
end

@testset "skeleton records the event sequence" begin
    rec, obs = _race_run(30; seed=424242)
    skel = recorded_skeleton(rec)
    @test [(s.clock, s.when) for s in skel.steps] == obs[2:end]
    @test skel.init.when == 0.0
end

@testset "skeleton rng state is pre-init" begin
    rec, _ = _race_run(10; seed=4211)
    @test recorded_skeleton(rec).rng_state == Xoshiro(4211)
end

@testset "skeleton rng replays exactly" begin
    rec, obs1 = _race_run(20; seed=4242)
    skel = recorded_skeleton(rec)
    obs2 = Tuple{Tuple,Float64}[]
    observer = (p, when, evt, changed) -> push!(obs2, (clock_key(evt), when))
    sim = SimulationFSM(
        SkeletonRace.RaceBoard(1), [SkeletonRace.FireA, SkeletonRace.FireB];
        rng=copy(skel.rng_state), sampler=CombinedNextReaction{Tuple,Float64}(),
        observer=observer,
    )
    stop = (p, i, e, w) -> i > 20
    ChronoSim.run(sim, SkeletonRace.init!, stop)
    @test obs1 == obs2
end

@testset "skeleton enable history carries distributions" begin
    rec, _ = _race_run(30; seed=424242)
    skel = recorded_skeleton(rec)
    initkeys = Dict(er.clock => er for er in skel.init.enabled)
    @test haskey(initkeys, (:FireA, 1))
    @test haskey(initkeys, (:FireB, 1))
    @test initkeys[(:FireA, 1)].distribution == Exponential(1 / _LA)
    @test initkeys[(:FireA, 1)].te == 0.0
    @test initkeys[(:FireB, 1)].distribution == Exponential(1 / _LB)
    @test initkeys[(:FireB, 1)].te == 0.0
    k = findfirst(s -> s.clock == (:FireA, 1), skel.steps)
    @test k !== nothing
    stepk = skel.steps[k]
    er = only(filter(e -> e.clock == (:FireA, 1), stepk.enabled))
    @test er.te == stepk.when
    @test er.distribution == Exponential(1 / _LA)
end

@testset "skeleton disable history on preemption" begin
    rec = RecordSkeleton()
    sim = SimulationFSM(
        SkeletonFlip.WakeBoard(1), [SkeletonFlip.WakeFast, SkeletonFlip.WakeSlow];
        rng=Xoshiro(1234), sampler=CombinedNextReaction{Tuple,Float64}(), policy=rec,
    )
    stop = (p, i, e, w) -> false
    ChronoSim.run(sim, SkeletonFlip.init!, stop)
    skel = recorded_skeleton(rec)
    k = findfirst(s -> s.clock == (:WakeFast, 1), skel.steps)
    @test k !== nothing
    step = skel.steps[k]
    @test step.disabled == [(:WakeSlow, 1)]
    @test !((:WakeFast, 1) in step.disabled)
end

@testset "skeleton proposals recorded per step" begin
    rec, _ = _race_run(30; seed=424242)
    skel = recorded_skeleton(rec)
    @test (:FireA, 1) in skel.init.proposed
    @test (:FireB, 1) in skel.init.proposed
    for s in skel.steps
        @test s.clock in s.proposed
    end
end

@testset "skeleton changed places are durable copies" begin
    rec, _ = _race_run(5; seed=424242)
    skel = recorded_skeleton(rec)
    ch = skel.steps[1].changed
    @test ch isa Vector{Tuple}
    @test !isempty(ch)
    @test ch !== skel.steps[2].changed
    marker = (:__marker__,)
    push!(ch, marker)
    @test marker in skel.steps[1].changed
    @test !(marker in skel.steps[2].changed)
end

@testset "skeleton recording does not perturb the trajectory" begin
    _, obs_rec = _race_run(30; seed=777)
    obs_plain = Tuple{Tuple,Float64}[]
    observer = (p, when, evt, changed) -> push!(obs_plain, (clock_key(evt), when))
    sim = SimulationFSM(
        SkeletonRace.RaceBoard(1), [SkeletonRace.FireA, SkeletonRace.FireB];
        rng=Xoshiro(777), sampler=CombinedNextReaction{Tuple,Float64}(),
        observer=observer,
    )
    stop = (p, i, e, w) -> i > 30
    ChronoSim.run(sim, SkeletonRace.init!, stop)
    @test obs_rec == obs_plain
end

@testset "skeleton save load round trip" begin
    rec, _ = _race_run(20; seed=424242)
    skel = recorded_skeleton(rec)
    path = joinpath(mktempdir(), "s.skel")
    @test load_skeleton(save_skeleton(path, skel)) == skel
end

@testset "skeleton show" begin
    rec, _ = _race_run(20; seed=424242)
    skel = recorded_skeleton(rec)
    block = sprint(show, MIME"text/plain"(), skel)
    @test count(==('\n'), block) == 4          # 5 lines
    @test occursin("steps", block)
    @test occursin("time span", block)
    @test occursin("top events", block)
    @test occursin("FireA", block)
    oneline = sprint(show, skel)
    @test startswith(oneline, "TrajectorySkeleton(")
end

@testset "skeleton before any run errors" begin
    @test_throws ArgumentError recorded_skeleton(RecordSkeleton())
end
