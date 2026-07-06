using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: NextReactionMethod
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!
import ChronoSim: on_preinit, on_init, on_propose, on_enable, on_disable, on_prefire, on_postfire

# A guard-flip pair: WakeFast and WakeSlow are both enabled while a cell's phase
# is idle; firing either flips the phase to active, which preemptively disables
# the sibling clock (the one that did not fire). WakeFast is given a much higher
# rate so it wins the race deterministically under a fixed seed.
module WakeModel
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

using .WakeModel: WakeBoard, WakeFast, WakeSlow, RATE_FAST, RATE_SLOW

# A policy that records every hook it sees as (hook::Symbol, payload).
mutable struct RecordingPolicy <: ChronoSim.ExecutionPolicy
    log::Vector{Any}
end
RecordingPolicy() = RecordingPolicy(Any[])

on_init(p::RecordingPolicy, sim, init_evt, changed_places) =
    (push!(p.log, (:init, changed_places)); nothing)
on_propose(p::RecordingPolicy, sim, event) =
    (push!(p.log, (:propose, event)); nothing)
on_enable(p::RecordingPolicy, sim, clock_key, event, distribution, te) =
    (push!(p.log, (:enable, (clock_key, distribution, te))); nothing)
on_disable(p::RecordingPolicy, sim, clock_key) =
    (push!(p.log, (:disable, clock_key)); nothing)
on_prefire(p::RecordingPolicy, sim, clock_key, event, when) =
    (push!(p.log, (:prefire, (clock_key, when))); nothing)
on_postfire(p::RecordingPolicy, sim, clock_key, event, when, changed_places) =
    (push!(p.log, (:postfire, (clock_key, changed_places))); nothing)

function _wake_sim(n; policy=ChronoSim.NoPolicy(), observer=nothing, seed=1234)
    return SimulationFSM(
        WakeBoard(n), [WakeFast, WakeSlow];
        rng=Xoshiro(seed), sampler=NextReactionMethod(), key_type=Tuple,
        observer=observer, policy=policy,
    )
end

# Calls all seven hooks on the sim's policy per iteration; used to measure the
# no-op path's allocation.
function _hook_loop(sim, n)
    total = 0
    for i in 1:n
        on_preinit(sim.policy, sim)
        on_init(sim.policy, sim, nothing, nothing)
        on_propose(sim.policy, sim, nothing)
        on_enable(sim.policy, sim, nothing, nothing, nothing, 0.0)
        on_disable(sim.policy, sim, nothing)
        on_prefire(sim.policy, sim, nothing, nothing, 0.0)
        on_postfire(sim.policy, sim, nothing, nothing, 0.0, nothing)
        total += i
    end
    return total
end

@testset "policy default is NoPolicy" begin
    sim = _wake_sim(1)
    @test sim.policy === ChronoSim.NoPolicy()
    @test typeof(sim).parameters[4] == ChronoSim.NoPolicy
end

@testset "policy hooks fire in order" begin
    observer_calls = Ref(0)
    obs = (p, when, evt, changed) -> (observer_calls[] += 1; nothing)
    policy = RecordingPolicy()
    sim = _wake_sim(3; policy=policy, observer=obs, seed=1234)
    stop = (p, i, e, w) -> false
    ChronoSim.run(sim, WakeModel.init!, stop)
    log = policy.log

    # :init occurs exactly once and marks the end of initialization: it precedes
    # every fire. (The initial clocks are proposed/enabled during init, before
    # on_init runs -- see the design's hook placement in initialize!, so :init is
    # not literally the first log entry, it is the first lifecycle boundary.)
    init_positions = [i for (i, e) in enumerate(log) if e[1] == :init]
    @test length(init_positions) == 1

    # Both :propose and :enable happen (during init, clocks are proposed then enabled).
    @test any(e -> e[1] == :propose, log)
    @test any(e -> e[1] == :enable, log)

    # Each fired step shows :prefire before its :postfire.
    prefire_positions = [i for (i, e) in enumerate(log) if e[1] == :prefire]
    postfire_positions = [i for (i, e) in enumerate(log) if e[1] == :postfire]
    @test length(prefire_positions) == length(postfire_positions)
    @test length(prefire_positions) >= 3
    for (pf, po) in zip(prefire_positions, postfire_positions)
        @test pf < po
    end
    # on_init precedes every fire.
    @test init_positions[1] < prefire_positions[1]

    # Every :postfire payload carries a nonempty changed_places.
    for e in log
        if e[1] == :postfire
            @test !isempty(e[2][2])
        end
    end

    # One :prefire per fired step; observer is called once at init plus once per fire.
    @test length(prefire_positions) == observer_calls[] - 1
end

@testset "policy on_enable carries the distribution" begin
    policy = RecordingPolicy()
    sim = _wake_sim(1; policy=policy, seed=1234)
    stop = (p, i, e, w) -> false
    ChronoSim.run(sim, WakeModel.init!, stop)
    enables = [e[2] for e in policy.log if e[1] == :enable]
    @test !isempty(enables)
    # Some enable payload is (clock_key, Exponential, te::Float64) with a model rate.
    @test any(enables) do (ck, dist, te)
        dist isa Exponential && te isa Float64 &&
            (rate(dist) ≈ RATE_FAST || rate(dist) ≈ RATE_SLOW)
    end
end

@testset "policy on_disable fires on preemption" begin
    policy = RecordingPolicy()
    sim = _wake_sim(1; policy=policy, seed=1234)
    stop = (p, i, e, w) -> false
    ChronoSim.run(sim, WakeModel.init!, stop)
    log = policy.log

    # WakeFast wins the race under this seed (RATE_FAST >> RATE_SLOW).
    fired = first(e[2][1] for e in log if e[1] == :prefire)
    @test fired == (:WakeFast, 1)

    disables = [e[2] for e in log if e[1] == :disable]
    @test disables == [(:WakeSlow, 1)]          # exactly one, the sibling
    @test !any(==( (:WakeFast, 1) ), disables)  # never the fired key
end

@testset "policy noop hooks are allocation free" begin
    sim = _wake_sim(1)
    _hook_loop(sim, 1)                # warmup / compile
    @test @allocated(_hook_loop(sim, 100_000)) == 0
end
