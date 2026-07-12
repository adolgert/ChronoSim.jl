using ReTest
using ChronoSim
using ChronoSim.ParticleFilter
using CompetingClocks: next
using Distributions
using LinearAlgebra
using Random
using Statistics

# ---------------------------------------------------------------------------
# Fixture: the machine-repair model as a MODEL VALUE, with exponential clocks
# so the down-count k = #down is a lumped birth-death CTMC (fail intensity
# (n−k)λ, repair intensity μ·1{k>0}) and the exact forward filter is an
# (n+1)-vector recursion propagated by one matrix exponential per grid step.
# Emission: each down machine is detected independently with probability
# p_detect, so y ~ Binomial(#down, p_detect).
# ---------------------------------------------------------------------------
module PfModels
using ChronoSim, ChronoSim.ObservedState, Distributions
import ChronoSim: precondition, enable, fire!, generators

@keyedby PfMachine Int64 begin
    up::Bool
end
@observedphysical PfShop begin
    machine::ObservedVector{PfMachine,Member}
end

struct PfFail <: SimEvent
    idx::Int
end
struct PfRepair <: SimEvent end

@guard precondition(evt::PfFail, physical) = physical.machine[evt.idx].up
@conditionsfor PfFail begin
    @reactto changed(machine[i].up) do physical
        generate(PfFail(i))
    end
end
enable(::PfFail, physical, θ, when) = (Exponential(inv(θ[1])), when)
fire!(evt::PfFail, physical, when, rng) =
    (physical.machine[evt.idx].up = false; nothing)

@guard precondition(evt::PfRepair, physical) =
    any(!physical.machine[i].up for i in eachindex(physical.machine))
@conditionsfor PfRepair begin
    @reactto changed(machine[i].up) do physical
        generate(PfRepair())
    end
end
enable(::PfRepair, physical, θ, when) = (Exponential(inv(θ[2])), when)
function fire!(::PfRepair, physical, when, rng)
    for i in eachindex(physical.machine)
        if !physical.machine[i].up
            physical.machine[i].up = true
            return nothing
        end
    end
    return nothing
end

function all_up(n::Int)
    m = ObservedArray{PfMachine,Member}(undef, n)
    for i in 1:n
        m[i] = PfMachine(true)
    end
    return PfShop(m)
end

pf_model(n::Int) = ChronoSim.GsmpModel(
    events=(PfFail, PfRepair),
    initial=() -> all_up(n),
    params=(:lambda, :mu),
)

down_count(physical) = count(i -> !physical.machine[i].up, eachindex(physical.machine))

end # module PfModels

using .PfModels: PfModels

# The exact forward filter on the lumped CTMC. The per-step likelihood factor
# is the RATIO log(sum(p .* g) / sum(p)), so an uninformative step (g ≡ 1)
# contributes exactly zero — p .* g is bit-identical to p — which lets the
# uninformative-observation test assert equality with no tolerance.
function pf_generator(θ, n)
    A = zeros(n + 1, n + 1)
    for k in 0:n
        fail = (n - k) * θ[1]
        rep = k > 0 ? θ[2] : 0.0
        A[k + 1, k + 1] = -(fail + rep)
        k < n && (A[k + 2, k + 1] = fail)
        k > 0 && (A[k, k + 1] = rep)
    end
    return A
end

function pf_forward_filter(θ, n, Δ, ys, p_detect)
    P = exp(Δ .* pf_generator(θ, n))
    p = [k == 0 ? 1.0 : 0.0 for k in 0:n]
    means = Float64[]
    logZ = 0.0
    for y in ys
        p = P * p
        g = [p_detect == 0.0 ? 1.0 : pdf(Binomial(k, p_detect), y) for k in 0:n]
        weighted = p .* g
        s = sum(weighted)
        logZ += log(s / sum(p))
        p = weighted ./ s
        push!(means, sum(k * p[k + 1] for k in 0:n))
    end
    return (logZ=logZ, means=means)
end

# The Binomial detection emission; answers the p = 0 case before the library
# call so the uninformative limit is EXACTLY zero log-weight (Distributions'
# binompdf rounds (1-p)^k to 1-eps at p = 0 for some k).
pf_emission(p_detect) = function (physical, y)
    p_detect == 0.0 && return y == 0 ? 0.0 : -Inf
    return logpdf(Binomial(PfModels.down_count(physical), p_detect), y)
end

const PF_θ = [0.5, 1.5]
const PF_N = 5
const PF_Δ = 1.0
const PF_TIMES = [j * PF_Δ for j in 1:8]

# The oracle comparisons divide by a standard error that is itself estimated
# from only 8–12 replicates, so a lucky-small se draw can turn a correct
# filter into a spurious 4σ failure whenever a new Julia version reshuffles
# the RNG stream (1.13.0-rc1 landed one grid point at z = 4.002; the same
# point sits at z = -1.3 with 96 replicates). The floor keeps the tolerance
# above that estimation noise while staying far below any real defect — a
# wrong rate moves these filtering means by ~0.2, not 0.08.
const PF_SE_FLOOR = 0.02

@testset "particle_filter: the model-value constructor builds a resumable live sim whose split advance reproduces a one-shot advance bit for bit" begin
    model = PfModels.pf_model(PF_N)
    seed = UInt64(0xC0457AB1)
    a = SimulationFSM(model, PF_θ; seed=seed)
    ChronoSim.initialize!(a, ChronoSim.model_initial(model))
    b = SimulationFSM(model, PF_θ; seed=seed)
    ChronoSim.initialize!(b, ChronoSim.model_initial(model))
    for τ in PF_TIMES
        advance!(a, τ)
    end
    nb = advance!(b, PF_TIMES[end])
    @test nb > 3
    @test a.when == b.when
    @test ChronoSim.ObservedState._state_equal(a.physical, b.physical)
    @test next(a.sampler) == next(b.sampler)
    # θ is read positionally against the model's declared names, so a wrong
    # length is refused at construction.
    @test_throws ArgumentError SimulationFSM(model, [0.5]; seed=seed)
end

@testset "particle_filter: systematic resampling offspring counts stay within one of the expected counts and a degenerate weight vector collapses to one ancestor" begin
    rng = Xoshiro(0x5A5A)
    N = 64
    anc = Vector{Int}(undef, N)
    for _ in 1:10
        w = rand(rng, N); w ./= sum(w)
        systematic_resample!(anc, w, rand(rng))
        counts = zeros(Int, N)
        for a in anc; counts[a] += 1; end
        @test all(floor(N * w[i]) <= counts[i] <= ceil(N * w[i]) for i in 1:N)
    end
    w = zeros(N); w[17] = 1.0
    systematic_resample!(anc, w, rand(rng))
    @test all(==(17), anc)
end

@testset "particle_filter: with uninformative observations the marginal-likelihood estimate is exactly one and the filtering means match the unconditional CTMC marginal within four standard errors" begin
    model = PfModels.pf_model(PF_N)
    ys = zeros(Int, length(PF_TIMES))
    marg = pf_forward_filter(PF_θ, PF_N, PF_Δ, ys, 0.0).means
    R, N = 8, 300
    master = Xoshiro(0xB11D)
    results = [bootstrap_filter(model, PF_θ, PF_TIMES, ys;
                   emission_loglikelihood=pf_emission(0.0),
                   statistic=PfModels.down_count,
                   nparticles=N, seed=rand(master, UInt64)) for _ in 1:R]
    # Every log-weight is literally 0.0, so logsumexp(0…0) − log(N) is the
    # same float subtracted from itself: Ẑ ≡ 1 with no tolerance.
    @test all(r.logZ == 0.0 for r in results)
    for j in eachindex(PF_TIMES)
        ms = [r.stats[j] for r in results]
        se = std(ms) / sqrt(R)
        @test se < 0.08
        @test abs(mean(ms) - marg[j]) < 4 * max(se, PF_SE_FLOOR)
    end
end

@testset "particle_filter: the filtering means match the exact forward-filter oracle within four standard errors and the likelihood-domain marginal estimate is unbiased" begin
    model = PfModels.pf_model(PF_N)
    p_detect = 0.6
    obs_rng = Xoshiro(0x0B5EED)
    ys = simulate_observations(obs_rng, model, PF_θ, PF_TIMES;
        observe=(rng, physical) -> rand(rng, Binomial(PfModels.down_count(physical), p_detect)))
    oracle = pf_forward_filter(PF_θ, PF_N, PF_Δ, ys, p_detect)
    R, N = 12, 500
    master = Xoshiro(0xF117E2)
    results = [bootstrap_filter(model, PF_θ, PF_TIMES, ys;
                   emission_loglikelihood=pf_emission(p_detect),
                   statistic=PfModels.down_count,
                   nparticles=N, seed=rand(master, UInt64)) for _ in 1:R]
    for j in eachindex(PF_TIMES)
        ms = [r.stats[j] for r in results]
        se = std(ms) / sqrt(R)
        @test se < 0.08
        @test abs(mean(ms) - oracle.means[j]) < 4 * max(se, PF_SE_FLOOR)
    end
    # Ẑ/Z is dimensionless and O(1); its mean over replicates is one because
    # the always-resample recursion keeps Ẑ unbiased (the pseudo-marginal
    # license). The log domain would carry Jensen bias — ratios, not logs.
    ratios = [exp(r.logZ - oracle.logZ) for r in results]
    se_r = std(ratios) / sqrt(R)
    @test se_r < 0.10
    @test abs(mean(ratios) - 1.0) < 4 * max(se_r, PF_SE_FLOOR)
end

@testset "particle_filter: the filter refuses mismatched observation lengths and non-increasing observation times" begin
    model = PfModels.pf_model(PF_N)
    kw = (emission_loglikelihood=pf_emission(0.6), nparticles=4, seed=UInt64(1))
    @test_throws ArgumentError bootstrap_filter(model, PF_θ, [1.0, 2.0], [0]; kw...)
    @test_throws ArgumentError bootstrap_filter(model, PF_θ, [1.0, 1.0], [0, 0]; kw...)
    @test_throws ArgumentError bootstrap_filter(model, PF_θ, [2.0, 1.0], [0, 0]; kw...)
    @test_throws ArgumentError bootstrap_filter(model, PF_θ, Float64[], Int[]; kw...)
end
