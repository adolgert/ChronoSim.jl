using ReTest
using ChronoSim
using ChronoSim: ProbePolicy, NoPolicy
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: CombinedNextReaction
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

# Fixtures reused from test_skeleton.jl: the SkeletonRace (two-clock exponential
# race) and SkeletonFlip (WakeFast/WakeSlow, survivor disabled after the flip so
# the sampler can exhaust) modules. Both are submodules of ChronoSimTests, in
# scope here at test-run time regardless of include order. All references live
# inside function/testset bodies (deferred), so alphabetical include order
# (test_replay before test_skeleton) is fine.

# Build a race sim with the given policy. The rng passed is overwritten by
# replay's copy!(sim.rng, skeleton.rng_state), so any seed works for a factory.
function _race_sim(policy; seed=0, observer=nothing)
    return SimulationFSM(
        SkeletonRace.RaceBoard(1), [SkeletonRace.FireA, SkeletonRace.FireB];
        rng=Xoshiro(seed), sampler=CombinedNextReaction{Tuple,Float64}(),
        observer=(observer === nothing ? ((a...) -> nothing) : observer), policy=policy,
    )
end

# Record n race steps and return the skeleton (optionally with an observer).
function _record_race(n; seed, observer=nothing)
    rec = RecordSkeleton()
    sim = _race_sim(rec; seed=seed, observer=observer)
    ChronoSim.run(sim, SkeletonRace.init!, (p, i, e, w) -> i > n)
    return recorded_skeleton(rec)
end

# A factory suitable for replay: the same construction as the recorded run.
_race_factory(policy) = (_race_sim(policy; seed=999), SkeletonRace.init!)

function _flip_sim(policy; seed=0)
    return SimulationFSM(
        SkeletonFlip.WakeBoard(1), [SkeletonFlip.WakeFast, SkeletonFlip.WakeSlow];
        rng=Xoshiro(seed), sampler=CombinedNextReaction{Tuple,Float64}(), policy=policy,
    )
end
function _record_flip(; seed)
    rec = RecordSkeleton()
    sim = _flip_sim(rec; seed=seed)
    ChronoSim.run(sim, SkeletonFlip.init!, (p, i, e, w) -> false)
    return recorded_skeleton(rec)
end
_flip_factory(policy) = (_flip_sim(policy; seed=999), SkeletonFlip.init!)

# Replace step i of a skeleton with newstep, preserving concrete types.
function _with_step(skel, i, newstep)
    steps = copy(skel.steps)
    steps[i] = newstep
    return typeof(skel)(skel.rng_state, skel.metadata, skel.init, steps)
end

@testset "replay reproduces a recorded run" begin
    skel = _record_race(50; seed=12345)
    records = Tuple{Int,Any,Float64}[]
    p(sim, step, phase, event, when) =
        phase === :postfire && push!(records, (step, clock_key(event), when))
    sim = replay(_race_factory, skel; probes=(p,))
    @test sim isa SimulationFSM
    @test records == [(i, s.clock, s.when) for (i, s) in enumerate(skel.steps)]
end

@testset "replay upto state matches original" begin
    # Snapshot the original run's state after step 17 via its observer, then
    # confirm replay(...; upto=17) reproduces it exactly. (SkeletonRace has one
    # cell; both fields are snapshotted -- design named cell[2], which does not
    # exist in the RaceBoard(1) fixture.)
    idx = Ref(-1)                    # init call makes it 0; step k makes it k
    snap = Ref((0, 0, 0.0))
    observer = (phys, when, evt, changed) -> begin
        idx[] += 1
        idx[] == 17 && (snap[] = (phys.cell[1].a, phys.cell[1].b, when))
    end
    skel = _record_race(40; seed=222, observer=observer)
    sim = replay(_race_factory, skel; upto=17)
    @test sim.physical.cell[1].a == snap[][1]
    @test sim.physical.cell[1].b == snap[][2]
    @test sim.when == skel.steps[17].when
end

@testset "replay upto zero returns initialized sim" begin
    skel = _record_race(20; seed=222)
    phases = Symbol[]
    p(sim, step, phase, event, when) = push!(phases, phase)
    sim = replay(_race_factory, skel; upto=0, probes=(p,))
    @test sim.when == skel.init.when
    @test phases == [:init]
end

@testset "replay divergence wrong clock" begin
    skel = _record_race(20; seed=333)
    orig = skel.steps[9]
    other = orig.clock[1] === :FireA ? (:FireB, orig.clock[2]) : (:FireA, orig.clock[2])
    ST = eltype(skel.steps)
    badstep = ST(other, orig.when, orig.changed, orig.enabled, orig.disabled, orig.proposed)
    skel2 = _with_step(skel, 9, badstep)
    err = try
        replay(_race_factory, skel2)
        nothing
    catch e
        e
    end
    @test err isa ReplayDivergence
    @test err.step == 9
    @test err.expected == (other, orig.when)
    @test err.actual == (orig.clock, orig.when)
end

@testset "replay divergence wrong time" begin
    skel = _record_race(20; seed=333)
    orig = skel.steps[9]
    ST = eltype(skel.steps)
    badstep = ST(orig.clock, orig.when + 1e-9, orig.changed, orig.enabled,
        orig.disabled, orig.proposed)
    skel2 = _with_step(skel, 9, badstep)
    err = try
        replay(_race_factory, skel2)
        nothing
    catch e
        e
    end
    @test err isa ReplayDivergence
    @test err.step == 9
    @test occursin("time differs by", sprint(showerror, err))
end

@testset "replay divergence sampler exhausted" begin
    skel = _record_flip(; seed=1234)
    @test length(skel.steps) == 1                 # survivor disabled after the flip
    extra = skel.steps[1]
    steps2 = vcat(skel.steps, [extra])
    skel2 = typeof(skel)(skel.rng_state, skel.metadata, skel.init, steps2)
    err = try
        replay(_flip_factory, skel2)
        nothing
    catch e
        e
    end
    @test err isa ReplayDivergence
    @test err.actual === nothing
    @test err.step == length(steps2)
end

@testset "replay rejects bad factory" begin
    skel = _record_race(10; seed=444)
    badfac = policy -> (_race_sim(NoPolicy(); seed=1), SkeletonRace.init!)
    @test_throws ArgumentError replay(badfac, skel)
    @test_throws ArgumentError replay(_race_factory, skel; upto=length(skel.steps) + 1)
end

@testset "probe arguments and phases" begin
    skel = _record_race(5; seed=99)
    seq = Tuple{Int,Symbol}[]
    whenchecks = Bool[]
    clockok = Bool[]
    p(sim, step, phase, event, when) = begin
        push!(seq, (step, phase))
        if phase === :prefire
            push!(whenchecks, sim.when < when)
            push!(clockok, event isa SimEvent && clock_key(event) == skel.steps[step].clock)
        elseif phase === :postfire
            push!(whenchecks, sim.when == when)
        end
    end
    replay(_race_factory, skel; probes=(p,))
    expected = vcat([(0, :init)], reduce(vcat, [[(i, :prefire), (i, :postfire)] for i in 1:5]))
    @test seq == expected
    @test all(whenchecks)
    @test all(clockok)
end

@testset "probe policy works in a forward run" begin
    seq = Tuple{Int,Symbol}[]
    p(sim, step, phase, event, when) = push!(seq, (step, phase))
    sim = _race_sim(ProbePolicy((p,)); seed=55)
    ChronoSim.run(sim, SkeletonRace.init!, (pp, i, e, w) -> i > 4)
    expected = vcat([(0, :init)], reduce(vcat, [[(i, :prefire), (i, :postfire)] for i in 1:4]))
    @test seq == expected
end

@testset "replay does not perturb determinism" begin
    skel = _record_race(30; seed=717)
    rec1 = Tuple{Int,Any,Float64}[]
    rec2 = Tuple{Int,Any,Float64}[]
    mk(store) = (sim, step, phase, event, when) ->
        phase === :postfire && push!(store, (step, clock_key(event), when))
    replay(_race_factory, skel; probes=(mk(rec1),))
    replay(_race_factory, skel; probes=(mk(rec2),))
    @test rec1 == rec2
    @test !isempty(rec1)
end
