using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: NextReactionMethod
using Distributions
using Random
using ForwardDiff
import ChronoSim: precondition, generators, enable, reenable, fire!, enable_recipe

# =============================================================================
# Milestone 2: the θ (parameter) seam, guarantee G4. θ becomes an explicit
# AbstractVector argument to `enable`/`reenable` so an estimator can re-evaluate
# the seam at a θ (possibly dual-valued) the forward run never saw, without
# re-instantiating global state. These tests exercise the backward-compatible
# fallback, the four-argument seam end to end, the ForwardDiff gradient through
# `sim.params`, the `params=` kwarg on `trace_likelihood`, and the θ-free
# `DistRecipe` layer behind the seam.
# =============================================================================

# A pre-seam model: its events define ONLY the three-argument `enable`. It must
# run identically through the new four-argument call sites (the default four-arg
# `enable` drops θ and forwards to this three-arg method). Rates are hardcoded.
module ThetaLegacy
using ChronoSim, ChronoSim.ObservedState, Distributions
import ChronoSim: precondition, generators, enable, fire!
@keyedby Cell Int64 begin
    a::Int64
    b::Int64
end
@observedphysical Board begin
    cell::ObservedVector{Cell,Member}
end
function Board(n::Int)
    m = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Cell(0, 0)
    end
    return Board(m)
end
struct FireA <: SimEvent
    idx::Int64
end
@precondition precondition(e::FireA, s) = s.cell[e.idx].a >= 0
enable(::FireA, s, when) = (Exponential(1 / 2.0), when)
fire!(e::FireA, s, when, rng) = (s.cell[e.idx].a += 1; nothing)
struct FireB <: SimEvent
    idx::Int64
end
@precondition precondition(e::FireB, s) = s.cell[e.idx].b >= 0
enable(::FireB, s, when) = (Exponential(1 / 3.0), when)
fire!(e::FireB, s, when, rng) = (s.cell[e.idx].b += 1; nothing)
init!(s, when, rng) = (s.cell[1].a = 0; s.cell[1].b = 0; nothing)
end # module

# The two-clock exponential race defined through the FOUR-argument seam: each
# event reads its rate from θ (θ[1] governs FireA, θ[2] governs FireB). No module
# global; θ arrives as `sim.params`.
module ThetaSeam
using ChronoSim, ChronoSim.ObservedState, Distributions
import ChronoSim: precondition, generators, enable, fire!
@keyedby Cell Int64 begin
    a::Int64
    b::Int64
end
@observedphysical Board begin
    cell::ObservedVector{Cell,Member}
end
function Board(n::Int)
    m = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Cell(0, 0)
    end
    return Board(m)
end
struct FireA <: SimEvent
    idx::Int64
end
@precondition precondition(e::FireA, s) = s.cell[e.idx].a >= 0
# Exponential is parameterized by SCALE, so a rate θ[1] means Exponential(inv(θ[1])).
enable(::FireA, s, θ, when) = (Exponential(inv(θ[1])), when)
fire!(e::FireA, s, when, rng) = (s.cell[e.idx].a += 1; nothing)
struct FireB <: SimEvent
    idx::Int64
end
@precondition precondition(e::FireB, s) = s.cell[e.idx].b >= 0
enable(::FireB, s, θ, when) = (Exponential(inv(θ[2])), when)
fire!(e::FireB, s, when, rng) = (s.cell[e.idx].b += 1; nothing)
init!(s, when, rng) = (s.cell[1].a = 0; s.cell[1].b = 0; nothing)
end # module

# The same race, but each event opts into the θ-free recipe layer: it defines
# `enable_recipe` (the one source of truth for the distribution's structure) and
# derives its four-argument `enable` with `enable_from_recipe`. mult=1.0, so the
# realized rate is exactly θ[param] — identical to the hand-written model below.
module ThetaRecipe
using ChronoSim, ChronoSim.ObservedState, Distributions
import ChronoSim: precondition, generators, enable, fire!, enable_recipe
using ChronoSim: DistRecipe, FAM_EXPONENTIAL, enable_from_recipe
@keyedby Cell Int64 begin
    a::Int64
    b::Int64
end
@observedphysical Board begin
    cell::ObservedVector{Cell,Member}
end
function Board(n::Int)
    m = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Cell(0, 0)
    end
    return Board(m)
end
struct FireA <: SimEvent
    idx::Int64
end
@precondition precondition(e::FireA, s) = s.cell[e.idx].a >= 0
enable_recipe(::FireA, s, when) = (DistRecipe(FAM_EXPONENTIAL, 1, 1.0, NaN), when)
enable(e::FireA, s, θ, when) = enable_from_recipe(e, s, θ, when)
fire!(e::FireA, s, when, rng) = (s.cell[e.idx].a += 1; nothing)
struct FireB <: SimEvent
    idx::Int64
end
@precondition precondition(e::FireB, s) = s.cell[e.idx].b >= 0
enable_recipe(::FireB, s, when) = (DistRecipe(FAM_EXPONENTIAL, 2, 1.0, NaN), when)
enable(e::FireB, s, θ, when) = enable_from_recipe(e, s, θ, when)
fire!(e::FireB, s, when, rng) = (s.cell[e.idx].b += 1; nothing)
init!(s, when, rng) = (s.cell[1].a = 0; s.cell[1].b = 0; nothing)
end # module

# The same race with the distribution written by hand in the four-argument
# `enable`, mirroring `build_distribution` EXACTLY (inv(1.0 * θ[param])) so the
# recipe route and this route cannot differ even at the bit level.
module ThetaHand
using ChronoSim, ChronoSim.ObservedState, Distributions
import ChronoSim: precondition, generators, enable, fire!
@keyedby Cell Int64 begin
    a::Int64
    b::Int64
end
@observedphysical Board begin
    cell::ObservedVector{Cell,Member}
end
function Board(n::Int)
    m = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Cell(0, 0)
    end
    return Board(m)
end
struct FireA <: SimEvent
    idx::Int64
end
@precondition precondition(e::FireA, s) = s.cell[e.idx].a >= 0
enable(::FireA, s, θ, when) = (Exponential(inv(1.0 * θ[1])), when)
fire!(e::FireA, s, when, rng) = (s.cell[e.idx].a += 1; nothing)
struct FireB <: SimEvent
    idx::Int64
end
@precondition precondition(e::FireB, s) = s.cell[e.idx].b >= 0
enable(::FireB, s, θ, when) = (Exponential(inv(1.0 * θ[2])), when)
fire!(e::FireB, s, when, rng) = (s.cell[e.idx].b += 1; nothing)
init!(s, when, rng) = (s.cell[1].a = 0; s.cell[1].b = 0; nothing)
end # module

# --- helpers -----------------------------------------------------------------

# Run the forward executor and record the (when, clock_key) trace, skipping the
# synthetic InitializeEvent. `params` threads the θ seam; a pre-seam model passes
# the default empty vector.
function _theta_trace(Board, events, init!; seed, nsteps, params=Float64[])
    trace = Tuple{Float64,Tuple}[]
    obs = (p, w, e, c) -> (e isa ChronoSim.InitializeEvent) ? nothing :
          push!(trace, (w, clock_key(e)))
    sim = SimulationFSM(
        Board, events; rng=Xoshiro(seed), key_type=Tuple, observer=obs, params=params,
    )
    ChronoSim.run(sim, init!, (p, i, e, w) -> i > nsteps)
    return trace
end

# The fixed, hand-checkable trace used by the gradient tests: FireA at 0.3 and
# 1.1, FireB at 0.7. Both clocks are always enabled and the fired clock is
# re-proposed, so the analytic score below is exact.
const FIXED_TRACE = Tuple{Float64,Tuple}[
    (0.3, (:FireA, 1)),
    (0.7, (:FireB, 1)),
    (1.1, (:FireA, 1)),
]
const FIXED_NA = 2
const FIXED_NB = 1
const FIXED_TN = 1.1

# The θ-seam log-likelihood closure. A fresh evaluation sim is built each call;
# θ arrives through the constructor `params=` by default, or `via_kwarg=true`
# routes it through the `trace_likelihood` kwarg instead.
function _seam_loglik(θ; trace=FIXED_TRACE, via_kwarg::Bool=false)
    if via_kwarg
        sim = SimulationFSM(
            ThetaSeam.Board(1), [ThetaSeam.FireA, ThetaSeam.FireB];
            rng=Xoshiro(7), key_type=Tuple, step_likelihood=true,
            likelihood_eltype=eltype(θ),
        )
        return trace_likelihood(sim, ThetaSeam.init!, trace; params=θ).loglikelihood
    else
        sim = SimulationFSM(
            ThetaSeam.Board(1), [ThetaSeam.FireA, ThetaSeam.FireB];
            rng=Xoshiro(7), key_type=Tuple, step_likelihood=true,
            likelihood_eltype=eltype(θ), params=θ,
        )
        return trace_likelihood(sim, ThetaSeam.init!, trace).loglikelihood
    end
end

# =============================================================================
# (a) Backward compatibility: a pre-seam (three-argument-enable-only) model runs
#     bit-for-bit identically through the new four-argument call sites.
# =============================================================================

@testset "theta: a model defining only the old three-argument enable runs bit-for-bit unchanged" begin
    # WHY exact literals: the default four-arg `enable` must forward to the
    # three-arg method with no perturbation, so the seeded trajectory is the same
    # trajectory the seam itself produces. Re-pinned for milestone 4: randomness
    # ownership moved into keyed streams derived from a master seed (the FSM now
    # takes master_seed = rand(Xoshiro(seed), UInt64) when given rng=Xoshiro(seed),
    # then seeds the sampler's per-clock streams from it), so the stream LAYOUT
    # changed and the concrete draws differ from the pre-milestone-4 pin. The
    # invariant under test -- that the three-arg-only model runs bit-for-bit like
    # the four-arg seam at a fixed seed -- is unchanged; only the literals moved.
    expected = Tuple{Float64,Tuple}[
        (0.14995522737136802, (:FireA, 1)),
        (0.35632846898872483, (:FireA, 1)),
        (0.42720982724146955, (:FireB, 1)),
        (0.4598290991688839, (:FireB, 1)),
        (0.7981593795596273, (:FireB, 1)),
        (1.10270455905406, (:FireA, 1)),
    ]
    got = _theta_trace(
        ThetaLegacy.Board(1), [ThetaLegacy.FireA, ThetaLegacy.FireB], ThetaLegacy.init!;
        seed=424242, nsteps=6,
    )
    @test got == expected
end

# =============================================================================
# (b) The four-argument seam end to end: forward run at a primal θ, then
#     trace_likelihood of its OWN trace at the SAME θ reproduces the forward
#     accumulation EXACTLY (reuses M1's effect_check).
# =============================================================================

@testset "theta: a four-argument-enable race replays its own trace at the same θ exactly" begin
    θ = [1.4, 2.2]
    pol = RecordMinimal(; initializer=ThetaSeam.init!)
    sim = SimulationFSM(
        ThetaSeam.Board(1), [ThetaSeam.FireA, ThetaSeam.FireB];
        rng=Xoshiro(20260710), key_type=Tuple, step_likelihood=true, params=θ, policy=pol,
    )
    ChronoSim.run(sim, ThetaSeam.init!, (p, i, e, w) -> i > 40)
    # The fresh sim carries the SAME θ through its own `params=`.
    factory = () -> SimulationFSM(
        ThetaSeam.Board(1), [ThetaSeam.FireA, ThetaSeam.FireB];
        seed=1, key_type=Tuple, step_likelihood=true, params=θ,
    )
    res = effect_check(factory, ThetaSeam.init!, pol)
    @test res.applicable
    @test res.passed
    @test res.forward === res.replay      # exact Float64 identity, not ≈
    @test isfinite(res.forward)
end

# =============================================================================
# (c) ForwardDiff.gradient through the θ seam matches the analytic score of the
#     exponential race on a hand-checkable trace.
# =============================================================================

@testset "theta: the ForwardDiff gradient of the trace log-likelihood matches the analytic exponential-race score" begin
    # For an always-enabled exponential race the log-likelihood telescopes to
    #   loglik(θ) = n_A log θ1 + n_B log θ2 - (θ1 + θ2) t_N,
    # so the score is [n_A/θ1 - t_N, n_B/θ2 - t_N]. Duals reach `enable` through
    # `sim.params`; no module global is involved.
    θ0 = [2.0, 3.0]
    @test _seam_loglik(θ0) ≈
        FIXED_NA * log(θ0[1]) + FIXED_NB * log(θ0[2]) - (θ0[1] + θ0[2]) * FIXED_TN atol = 1e-10
    g = ForwardDiff.gradient(_seam_loglik, θ0)
    @test all(isfinite, g)
    @test g ≈ [FIXED_NA / θ0[1] - FIXED_TN, FIXED_NB / θ0[2] - FIXED_TN] atol = 1e-10
end

# =============================================================================
# (d) The params= kwarg on trace_likelihood yields the SAME gradient as baking θ
#     into the constructor.
# =============================================================================

@testset "theta: the params= kwarg gradient equals the θ-in-constructor gradient exactly" begin
    # WHY both build a fresh sim per evaluation: the framework re-initializes but
    # does not reset the sampler across trace_likelihood calls, so a sim cannot be
    # reused for a second evaluation. The kwarg merely relocates θ from the
    # constructor to the call; this test pins that relocation to be a no-op on the
    # gradient.
    θ0 = [2.0, 3.0]
    g_ctor = ForwardDiff.gradient(θ -> _seam_loglik(θ; via_kwarg=false), θ0)
    g_kwarg = ForwardDiff.gradient(θ -> _seam_loglik(θ; via_kwarg=true), θ0)
    @test g_kwarg == g_ctor
end

@testset "theta: trace_likelihood leaves sim.params set to the passed vector" begin
    # The FSM is mutable and the kwarg sets sim.params in place; document that it
    # STAYS set after the call (an estimator re-evaluating at many θ relies on this).
    sim = SimulationFSM(
        ThetaSeam.Board(1), [ThetaSeam.FireA, ThetaSeam.FireB];
        rng=Xoshiro(7), key_type=Tuple, step_likelihood=true,
    )
    @test sim.params == Float64[]      # default
    θ = [1.3, 2.7]
    trace_likelihood(sim, ThetaSeam.init!, FIXED_TRACE; params=θ)
    @test sim.params === θ             # the exact vector, still set
end

# =============================================================================
# (e) enable_recipe and a hand-written four-argument enable are indistinguishable
#     (the derived-seam-cannot-disagree property).
# =============================================================================

@testset "theta: a recipe-derived event and a hand-written enable produce identical trajectories and log-likelihoods" begin
    θ = [1.1, 1.9]
    seed = 314159
    tr_recipe = _theta_trace(
        ThetaRecipe.Board(1), [ThetaRecipe.FireA, ThetaRecipe.FireB], ThetaRecipe.init!;
        seed=seed, nsteps=60, params=θ,
    )
    tr_hand = _theta_trace(
        ThetaHand.Board(1), [ThetaHand.FireA, ThetaHand.FireB], ThetaHand.init!;
        seed=seed, nsteps=60, params=θ,
    )
    # Bit-identical trajectories: same clock keys and same firing times.
    @test tr_recipe == tr_hand

    # Bit-identical log-likelihoods of the shared trace under each model.
    ll_recipe = trace_likelihood(
        SimulationFSM(
            ThetaRecipe.Board(1), [ThetaRecipe.FireA, ThetaRecipe.FireB];
            rng=Xoshiro(7), key_type=Tuple, step_likelihood=true, params=θ,
        ),
        ThetaRecipe.init!, tr_recipe,
    ).loglikelihood
    ll_hand = trace_likelihood(
        SimulationFSM(
            ThetaHand.Board(1), [ThetaHand.FireA, ThetaHand.FireB];
            rng=Xoshiro(7), key_type=Tuple, step_likelihood=true, params=θ,
        ),
        ThetaHand.init!, tr_hand,
    ).loglikelihood
    @test ll_recipe === ll_hand
end

@testset "theta: build_distribution keeps eltype(θ) as the distribution partype for both families" begin
    # Both branches must promote to dual so ForwardDiff can thread a gradient
    # through a record replay. θ[1] dual, shape fixed Float64.
    θd = [ForwardDiff.Dual{:t}(2.0, 1.0), ForwardDiff.Dual{:t}(0.0, 0.0)]
    D = eltype(θd)
    dexp = build_distribution(DistRecipe(FAM_EXPONENTIAL, 1, 1.0, NaN), θd)
    dwei = build_distribution(DistRecipe(FAM_WEIBULL, 1, 1.0, 1.7), θd)
    @test partype(dexp) === D
    @test partype(dwei) === D
end

# =============================================================================
# (f) DistRecipe equality: the NaN-shape (exponential) decision, and inequality
#     on a changed multiplier.
# =============================================================================

@testset "theta: two DistRecipes with equal fields compare equal including the NaN exponential shape" begin
    # WHY: `NaN != NaN` under ==, so a naive field-wise == would wrongly make two
    # identical exponential recipes unequal. The custom == compares shape with
    # isequal, which the "recipe changed while enabled" trigger of later milestones
    # depends on.
    a = DistRecipe(FAM_EXPONENTIAL, 1, 1.0, NaN)
    b = DistRecipe(FAM_EXPONENTIAL, 1, 1.0, NaN)
    @test a == b
    @test hash(a) == hash(b)
    # A Weibull recipe compares by its real shape too.
    @test DistRecipe(FAM_WEIBULL, 2, 3.0, 1.7) == DistRecipe(FAM_WEIBULL, 2, 3.0, 1.7)
end

@testset "theta: a DistRecipe with a changed multiplier compares unequal" begin
    a = DistRecipe(FAM_EXPONENTIAL, 1, 1.0, NaN)
    @test a != DistRecipe(FAM_EXPONENTIAL, 1, 2.0, NaN)   # changed mult
    @test a != DistRecipe(FAM_EXPONENTIAL, 2, 1.0, NaN)   # changed param
    @test a != DistRecipe(FAM_WEIBULL, 1, 1.0, NaN)       # changed family
end

# =============================================================================
# (g) The calibration MLE regression, ported from the statistical_calibration.jl
#     exponential race. On a fixed synthetic log the ForwardDiff MLE gradient at
#     the recovered rate is near zero and the recovered rate matches the truth.
# =============================================================================

@testset "theta: the exponential-race MLE is recovered and its ForwardDiff gradient is near zero" begin
    # Ground truth rates λ = [1.0, 1.6]; a 200-event log at seed 112. Re-pinned for
    # milestone 4: the log is now drawn from the sampler's keyed streams (seeded
    # from a master seed derived from rng=Xoshiro(112)), so the concrete synthetic
    # log changed from the pre-milestone-4 counts (n_A=77, n_B=123) that the
    # statistical_calibration.jl example committed. The DESIGN invariant this test
    # exists for is unchanged and still checked below: the closed-form MLE
    # λ̂ = n / t_N is a stationary point of the θ-seam log-likelihood, i.e. the
    # ForwardDiff score vanishes there. Only the stream-dependent counts and MLE
    # literals moved.
    EXP_TRUTH = [1.0, 1.6]
    log_ = _theta_trace(
        ThetaSeam.Board(1), [ThetaSeam.FireA, ThetaSeam.FireB], ThetaSeam.init!;
        seed=112, nsteps=200, params=EXP_TRUTH,
    )
    na = count(t -> t[2][1] == :FireA, log_)
    nb = count(t -> t[2][1] == :FireB, log_)
    tN = log_[end][1]
    @test na == 78
    @test nb == 122

    # The closure the optimizer would drive, differentiable through `sim.params`.
    loglik(θ) = trace_likelihood(
        SimulationFSM(
            ThetaSeam.Board(1), [ThetaSeam.FireA, ThetaSeam.FireB];
            rng=Xoshiro(7), key_type=Tuple, step_likelihood=true,
            likelihood_eltype=eltype(θ), params=θ,
        ),
        ThetaSeam.init!, log_,
    ).loglikelihood

    # For the always-enabled exponential race the MLE is closed-form λ̂ = n / t_N.
    mle = [na, nb] ./ tN
    # Re-pinned for milestone 4 (see the count re-pin above); still near truth [1.0, 1.6].
    @test mle ≈ [0.9535427033678308, 1.4914385873189149] atol = 1e-3

    # The score vanishes at the MLE — the regression the optimizer's convergence
    # rests on.
    g_at_mle = ForwardDiff.gradient(loglik, mle)
    @test all(abs.(g_at_mle) .< 1e-8)

    # And the analytic score elsewhere (at the truth) is reproduced exactly.
    g_at_truth = ForwardDiff.gradient(loglik, EXP_TRUTH)
    @test g_at_truth ≈ [na / EXP_TRUTH[1] - tN, nb / EXP_TRUTH[2] - tN] atol = 1e-10

    # The recovered rate matches the truth within four standard errors
    # (SE_k = λ̂_k / sqrt(n_k) for this diagonal-information model).
    se = mle ./ sqrt.([na, nb])
    @test all(abs.(mle .- EXP_TRUTH) .< 4 .* se)
end
