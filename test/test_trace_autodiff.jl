using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using Distributions
using Random
using ForwardDiff
import ChronoSim: precondition, generators, enable, fire!

# End-to-end automatic-differentiation acceptance test for the migration to the
# CompetingClocks high-level SamplingContext interface. The whole point of the
# migration is that a ChronoSim trace log-likelihood becomes differentiable via
# `ForwardDiff.gradient(loglik, θ)`.
#
# The model is the two-clock exponential race of test_trace_eval.jl, but the
# rates come from a module global `RATES` (a `Ref{NTuple{2,Any}}`) so a caller
# can push ForwardDiff.Dual numbers all the way into `enable()`. The Ref is
# `Any`-typed so the SAME closure serves both plain Float64 evaluation and
# Dual-valued gradient/hessian evaluation. Loading ForwardDiff activates
# CompetingClocks' `CompetingClocksForwardDiffExt`, which strips Duals across the
# primal (sampling) boundary while the likelihood watcher keeps them.
module TraceADRace
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

# Rates reach enable() Dual-generically: `Any` element type so (Float64, Float64)
# and (Dual, Dual) tuples both fit. Exponential in Distributions.jl is
# parameterized by SCALE, so rate λ means Exponential(1/λ).
const RATES = Ref{NTuple{2,Any}}((2.0, 3.0))

@keyedby ADCell Int64 begin
    a::Int64
    b::Int64
end

@observedphysical ADBoard begin
    cell::ObservedVector{ADCell,Member}
end

function ADBoard(n::Int)
    cells = ObservedArray{ADCell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = ADCell(0, 0)
    end
    return ADBoard(cells)
end

struct ADFireA <: SimEvent
    idx::Int64
end
@precondition precondition(evt::ADFireA, state) = state.cell[evt.idx].a >= 0
enable(::ADFireA, state, when) = (Exponential(1 / RATES[][1]), when)
fire!(evt::ADFireA, state, when, rng) = (state.cell[evt.idx].a += 1; nothing)

struct ADFireB <: SimEvent
    idx::Int64
end
@precondition precondition(evt::ADFireB, state) = state.cell[evt.idx].b >= 0
enable(::ADFireB, state, when) = (Exponential(1 / RATES[][2]), when)
fire!(evt::ADFireB, state, when, rng) = (state.cell[evt.idx].b += 1; nothing)

function init!(state, when, rng)
    state.cell[1].a = 0
    state.cell[1].b = 0
    return nothing
end
end # module

# Event names carry the AD prefix so they cannot collide with test_trace_eval.jl's
# FireA/FireB in the shared ChronoSimTests module (a conflicting `using` import is
# silently ignored, which would shadow these Dual-carrying events).
using .TraceADRace: ADBoard, ADFireA, ADFireB, RATES

# A FIXED, hardcoded trace: both clocks are always enabled and the fired clock is
# re-enabled at each step, so the analytic score below is exact. ADFireA fires at
# 0.3 and 1.1, ADFireB fires at 0.7.
const AD_TRACE = Tuple{Float64,Tuple}[
    (0.3, (:ADFireA, 1)),
    (0.7, (:ADFireB, 1)),
    (1.1, (:ADFireA, 1)),
]

# n_a = firings of ADFireA, n_b = firings of ADFireB, t_N = last trace time.
const AD_NA = 2
const AD_NB = 1
const AD_TN = 1.1

# The differentiable closure: set rates from θ, build an evaluation sim whose
# likelihood eltype matches θ, and return the log-likelihood of the fixed trace.
# For an exponential race where both clocks are always enabled and the fired
# clock is re-enabled each step, the per-step term is
#   log(λ_fired) - (λa + λb) * Δt
# and summing telescopes Δt to t_N (t_0 = 0), giving
#   n_a*log(λa) + n_b*log(λb) - (λa + λb)*t_N.
function loglik(θ)
    RATES[] = (θ[1], θ[2])
    sim = SimulationFSM(
        ADBoard(1), [ADFireA, ADFireB];
        rng=Xoshiro(7), step_likelihood=true, likelihood_eltype=eltype(θ),
        key_type=Tuple,
    )
    return trace_likelihood(sim, TraceADRace.init!, AD_TRACE).loglikelihood
end

# Closed-form log-likelihood, gradient (score), and hessian at rate vector λ.
_ad_analytic(λ) = AD_NA * log(λ[1]) + AD_NB * log(λ[2]) - (λ[1] + λ[2]) * AD_TN
_ad_score(λ) = [AD_NA / λ[1] - AD_TN, AD_NB / λ[2] - AD_TN]
# Hessian of the log-likelihood is diagonal: ∂²/∂λ_k² = -n_k/λ_k², off-diagonal 0.
_ad_hessian(λ) = [-AD_NA/λ[1]^2 0.0; 0.0 -AD_NB/λ[2]^2]

@testset "trace_autodiff Float64 value matches analytic" begin
    λ = [2.0, 3.0]
    v = loglik(λ)
    @test v isa Float64
    @test v ≈ _ad_analytic(λ) atol = 1e-10
end

@testset "trace_autodiff gradient matches analytic score" begin
    λ = [2.0, 3.0]
    g = ForwardDiff.gradient(loglik, λ)
    @test all(isfinite, g)
    @test g ≈ _ad_score(λ) atol = 1e-10
end

@testset "trace_autodiff hessian matches analytic" begin
    λ = [2.0, 3.0]
    H = ForwardDiff.hessian(loglik, λ)
    @test all(isfinite, H)
    @test H ≈ _ad_hessian(λ) atol = 1e-10
end

@testset "trace_autodiff one closure serves Float64 and Dual" begin
    # Plain Float64 input returns a Float64.
    @test loglik([2.0, 3.0]) isa Float64
    # A Dual-valued input threads Duals through enable() and returns a Dual whose
    # value is the primal log-likelihood and whose partials are the score.
    θd = [
        ForwardDiff.Dual{:t}(2.0, 1.0, 0.0),
        ForwardDiff.Dual{:t}(3.0, 0.0, 1.0),
    ]
    r = loglik(θd)
    @test r isa ForwardDiff.Dual
    @test ForwardDiff.value(r) ≈ _ad_analytic([2.0, 3.0]) atol = 1e-10
    @test collect(ForwardDiff.partials(r)) ≈ _ad_score([2.0, 3.0]) atol = 1e-10
end

@testset "trace_autodiff infeasible trace under Dual is -Inf" begin
    # Same closure structure, but an infeasible trace: step 2 names a clock key
    # that is not enabled. The result must be infeasible with a Dual-valued -Inf.
    function loglik_bad(θ)
        RATES[] = (θ[1], θ[2])
        sim = SimulationFSM(
            ADBoard(1), [ADFireA, ADFireB];
            rng=Xoshiro(7), step_likelihood=true, likelihood_eltype=eltype(θ),
            key_type=Tuple,
        )
        bad_trace = Tuple{Float64,Tuple}[
            (0.3, (:ADFireA, 1)),
            (0.7, (:ADFireA, 99)),   # not enabled
        ]
        return trace_likelihood(sim, TraceADRace.init!, bad_trace)
    end

    θd = [
        ForwardDiff.Dual{:t}(2.0, 1.0, 0.0),
        ForwardDiff.Dual{:t}(3.0, 0.0, 1.0),
    ]
    ev = loglik_bad(θd)
    @test ev.feasible == false
    @test ev.loglikelihood isa ForwardDiff.Dual
    @test isinf(ForwardDiff.value(ev.loglikelihood))
    @test ForwardDiff.value(ev.loglikelihood) == -Inf

    # Leave the module global in its default state for any later reader.
    RATES[] = (2.0, 3.0)
end
