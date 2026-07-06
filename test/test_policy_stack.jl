using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: NextReactionMethod
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!
import ChronoSim: on_preinit, on_init, on_propose, on_enable, on_disable, on_prefire, on_postfire
import ChronoSim: PolicyStack, find_policy, NoPolicy

# Reuse WakeModel / WakeBoard / WakeFast / WakeSlow from test_policy.jl (included
# earlier in the alphabetical chain). Duplicate the tiny RecordingPolicy locally
# so this file is independent of test_policy.jl's binding name; tag each push so
# two members sharing one log are distinguishable.
mutable struct StackTagPolicy <: ChronoSim.ExecutionPolicy
    tag::Symbol
    log::Vector{Any}
end

on_preinit(p::StackTagPolicy, sim) = (push!(p.log, (p.tag, :preinit)); nothing)
on_init(p::StackTagPolicy, sim, init_evt, changed) =
    (push!(p.log, (p.tag, :init)); nothing)
on_propose(p::StackTagPolicy, sim, event) =
    (push!(p.log, (p.tag, :propose)); nothing)
on_enable(p::StackTagPolicy, sim, ck, event, dist, te) =
    (push!(p.log, (p.tag, :enable)); nothing)
on_disable(p::StackTagPolicy, sim, ck) =
    (push!(p.log, (p.tag, :disable)); nothing)
on_prefire(p::StackTagPolicy, sim, ck, event, when) =
    (push!(p.log, (p.tag, :prefire)); nothing)
on_postfire(p::StackTagPolicy, sim, ck, event, when, changed) =
    (push!(p.log, (p.tag, :postfire)); nothing)

function _stack_sim(n; policy=NoPolicy(), observer=nothing, seed=1234)
    return SimulationFSM(
        WakeBoard(n), [WakeFast, WakeSlow];
        rng=Xoshiro(seed), sampler=NextReactionMethod(), key_type=Tuple,
        observer=observer, policy=policy,
    )
end

# Drives all seven hooks per iteration on the sim's policy; measures allocation.
function _stack_hook_loop(sim, n)
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

@testset "policy stack fans out in member order" begin
    shared = Any[]
    a = StackTagPolicy(:A, shared)
    b = StackTagPolicy(:B, shared)
    sim = _stack_sim(3; policy=PolicyStack(a, b), seed=1234)
    stop = (p, i, e, w) -> false
    ChronoSim.run(sim, WakeModel.init!, stop)

    @test !isempty(shared)
    # For every hook occurrence, member A's entry immediately precedes member B's.
    # A and B see the same hook sequence, so entries strictly alternate A,B,A,B...
    @test all(shared[i][1] == :A for i in 1:2:length(shared))
    @test all(shared[i][1] == :B for i in 2:2:length(shared))
    # And the hook name matches within each A/B pair.
    for i in 1:2:length(shared)
        @test shared[i][2] == shared[i + 1][2]
    end
end

@testset "policy stack drives a real run" begin
    # A single-member stack produces the same tagged log as a bare policy run.
    bare_log = Any[]
    bare = StackTagPolicy(:X, bare_log)
    sim1 = _stack_sim(3; policy=bare, seed=1234)
    ChronoSim.run(sim1, WakeModel.init!, (p, i, e, w) -> false)

    stack_log = Any[]
    stacked = StackTagPolicy(:X, stack_log)
    sim2 = _stack_sim(3; policy=PolicyStack(stacked), seed=1234)
    ChronoSim.run(sim2, WakeModel.init!, (p, i, e, w) -> false)

    @test stack_log == bare_log
end

@testset "policy stack empty and noop are allocation free" begin
    sim = _stack_sim(1; policy=PolicyStack())
    _stack_hook_loop(sim, 1)                # warmup / compile
    @test @allocated(_stack_hook_loop(sim, 100_000)) == 0
end

@testset "find_policy locates members" begin
    rec = RecordSkeleton()
    # WakeModel has no @invariant; use a bare tag policy for the "not found" side.
    tag = StackTagPolicy(:T, Any[])
    @test find_policy(RecordSkeleton, PolicyStack(rec, tag)) === rec
    @test find_policy(RecordSkeleton, tag) === nothing
    # Nested stacks are searched depth-first.
    @test find_policy(RecordSkeleton, PolicyStack(PolicyStack(rec))) === rec
    @test find_policy(StackTagPolicy, PolicyStack(rec, tag)) === tag
    @test find_policy(RecordSkeleton, NoPolicy()) === nothing
end
