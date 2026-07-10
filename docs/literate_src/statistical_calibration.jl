# # Calibrating a model from an event log
#
# The [trace-evaluation page](trace_evaluation.md) showed that once a
# trajectory is fixed, a ChronoSim trace log-likelihood is a smooth,
# differentiable function of the clock distributions' parameters. That is the
# hook the whole Julia statistics ecosystem hangs on: a differentiable
# log-likelihood is all a maximum-likelihood optimizer, a
# Metropolis–Hastings sampler, a Hamiltonian Monte Carlo sampler, or a
# probabilistic-programming language needs. This page *calibrates* a model —
# recovers the clock parameters from an observed event log — through **four
# different stacks in turn**, all driven by the *same one-line closure*:
#
# * **Optim** for the maximum-likelihood estimate (score from ForwardDiff),
# * **LogDensityProblems + AdvancedMH** for a random-walk Metropolis posterior,
# * **AdvancedHMC** for the NUTS posterior — every leapfrog step differentiates
#   `trace_likelihood`, which is the whole point of the SamplingContext
#   migration,
# * **Turing** for the same fit written as a `@model`.
#
# We do it first on a competing **exponential** race, where the MLE and score
# have a closed form we can check by hand, then swap in a **Weibull** clock to
# get a genuinely semi-Markov model — the "empty niche" that memoryless tooling
# cannot reach — and check *that* against an independent clock-age walker.
#
# !!! note "The θ (parameter) seam"
#     This page is written against the **θ seam** (design guarantee G4). Each
#     event's `enable` takes the parameter vector `θ` as an explicit argument —
#     `enable(event, physical, θ, when)` — and the simulation carries `θ` in its
#     `params` field, set with the `params=` keyword. There is **no module
#     global**: `θ` flows from the caller, through `sim.params`, into `enable`,
#     and reaches `ForwardDiff` as a vector of `Dual`s without any mutable state
#     being swapped between evaluations. (The pre-seam version of this page kept
#     the clocks in an `Any`-typed `Ref` that every `enable` closed over and that
#     the closure rewrote before each call; the seam removes that global and the
#     thread-unsafety that came with it.)
#
# !!! note "This page is static"
#     Every code block below is real, runnable code, but the documentation build
#     does **not** execute it — the heavy sampling stacks are not in the docs
#     environment. The script lives at `docs/literate_src/statistical_calibration.jl`
#     and runs top-to-bottom against `docs/calibration/Project.toml`; its inline
#     `@assert`s are its acceptance test. The exponential-race MLE gradient check
#     (§4a) is also mirrored as an executable regression in
#     `test/test_theta_seam.jl` (`theta:` testset "the exponential-race MLE is
#     recovered…"), which runs in the package suite. The chain summaries shown in
#     fenced blocks are the output of the `println` calls beside them, pasted from
#     a real run and reproduced on the same platform with the committed
#     `Manifest.toml` (BLAS/LAPACK can differ across architectures).

using ChronoSim
using ChronoSim.ObservedState
using Distributions
using Random
using LinearAlgebra
using ForwardDiff
using Optim
using ADTypes: AutoForwardDiff
using LogDensityProblems
using LogDensityProblemsAD: ADgradient
import AdvancedMH
import AdvancedHMC
using AbstractMCMC
using MCMCChains
using Turing

# ## Sizes and seeds, all in one place
#
# Every chain length, trace length, and RNG seed is a named constant here, so
# the committed outputs are a deterministic function of this file plus the
# `Manifest.toml`. Shrinking the sampler constants is the one knob for runtime.

const N_EXP_STEPS = 200      # events in the exponential-race log
const N_WEI_STEPS = 500      # events in the Weibull-race log
const N_MH_DRAWS = 20_000    # AdvancedMH random-walk draws (kept)
const N_MH_BURN = 2_000      # AdvancedMH warm-up draws (discarded)
const N_HMC_ADAPT = 500      # AdvancedHMC NUTS adaptation steps
const N_HMC_DRAWS = 500      # AdvancedHMC NUTS kept draws
const N_TUR_ADAPT = 500      # Turing NUTS adaptation steps
const N_TUR_DRAWS = 1_000    # Turing NUTS kept draws
const N_WEI_ADAPT = 400      # Weibull AdvancedHMC adaptation steps
const N_WEI_DRAWS = 400      # Weibull AdvancedHMC kept draws

const SEED_EXP_LOG = 112        # exponential forward run
const SEED_WEI_LOG = 102        # Weibull forward run
const SEED_MH = 20240601        # AdvancedMH
const SEED_HMC = 20240602       # AdvancedHMC (exponential)
const SEED_TUR = 20240603       # Turing
const SEED_WEI_HMC = 20240604   # AdvancedHMC (Weibull)

# ## §1  The model: a two-clock race read from θ
#
# The model is the competing race of the trace-evaluation page, generalized in
# one way: instead of hard-coded rates, each event **builds its distribution
# from `θ`** in the four-argument `enable`. The parameter vector reaches `enable`
# as the simulation's `params`, so `ForwardDiff.Dual` numbers thread straight
# through with no global to rewrite. The distribution *family* is a structural
# choice, not a parameter, so the exponential and the Weibull experiments are two
# small model modules that differ only in what `enable` constructs; both read
# their numbers from `θ`. Both clocks are perpetually enabled (trivially-true
# preconditions) and the fired clock is re-proposed on firing, so every clock
# stays in the enabled set for the whole run. That shape is deliberate: it
# sidesteps a known upstream CombinedNextReaction stale-entry issue that would
# otherwise perturb the likelihood of a clock that leaves the enabled set.

# The **exponential** race. `θ = [λA, λB]` are rates; `Exponential` in
# Distributions.jl takes the *scale*, so rate λ becomes `Exponential(inv(λ))`.

module ExpRace
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

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
enable(::FireA, state, θ, when) = (Exponential(inv(θ[1])), when)
fire!(evt::FireA, state, when, rng) = (state.cell[evt.idx].a += 1; nothing)

struct FireB <: SimEvent
    idx::Int64
end
@precondition precondition(evt::FireB, state) = state.cell[evt.idx].b >= 0
enable(::FireB, state, θ, when) = (Exponential(inv(θ[2])), when)
fire!(evt::FireB, state, when, rng) = (state.cell[evt.idx].b += 1; nothing)

function init!(state, when, rng)
    state.cell[1].a = 0
    state.cell[1].b = 0
    return nothing
end
end # module

# The **Weibull** race (used in §5). Clock A stays memoryless but is now
# parameterized by its *scale* `θ[1]` (not a rate); clock B is a `Weibull` with
# shape `θ[2]` and scale `θ[3]`, so it *ages* while it waits.

module WeiRace
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

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
enable(::FireA, state, θ, when) = (Exponential(θ[1]), when)
fire!(evt::FireA, state, when, rng) = (state.cell[evt.idx].a += 1; nothing)

struct FireB <: SimEvent
    idx::Int64
end
@precondition precondition(evt::FireB, state) = state.cell[evt.idx].b >= 0
enable(::FireB, state, θ, when) = (Weibull(θ[2], θ[3]), when)
fire!(evt::FireB, state, when, rng) = (state.cell[evt.idx].b += 1; nothing)

function init!(state, when, rng)
    state.cell[1].a = 0
    state.cell[1].b = 0
    return nothing
end
end # module

# ## §2  Simulate an event log
#
# `simulate_log` runs the forward executor at a parameter vector `θ` (threaded
# through `params=`) and records `(when, clock_key)` for each firing, skipping
# the synthetic `InitializeEvent`. This is the "observed data" a field study
# would hand us; downstream, only the trace is used. The model is passed as its
# `RaceBoard` constructor, event list, and `init!` so the same function serves
# both the exponential and the Weibull races.

function simulate_log(mk_board, events, init!, θ; nsteps, seed)
    trace = Tuple{Float64,Tuple}[]
    observer = (physical, when, event, changed) -> begin
        event isa ChronoSim.InitializeEvent && return nothing
        push!(trace, (when, clock_key(event)))
    end
    sim = SimulationFSM(
        mk_board(), events;
        rng=Xoshiro(seed), key_type=Tuple, observer=observer, params=θ,
    )
    ChronoSim.run(sim, init!, (p, i, e, w) -> i > nsteps)
    return trace
end

# Ground truth for the exponential race: rates λ = [1.0, 1.6].

const EXP_TRUTH = [1.0, 1.6]
const EXP_LOG = simulate_log(
    () -> ExpRace.RaceBoard(1), [ExpRace.FireA, ExpRace.FireB], ExpRace.init!, EXP_TRUTH;
    nsteps=N_EXP_STEPS, seed=SEED_EXP_LOG,
)

# Summaries of the log we will reuse: the counts and the final time.

exp_na = count(t -> t[2][1] == :FireA, EXP_LOG)
exp_nb = count(t -> t[2][1] == :FireB, EXP_LOG)
exp_tN = EXP_LOG[end][1]
@assert exp_na + exp_nb == N_EXP_STEPS

# ## §3  One differentiable closure, four consumers
#
# This is the load-bearing function. `make_loglik(mk_board, events, init!, trace)`
# returns a closure `θ -> loglikelihood`: it builds an evaluation sim whose
# `params` is `θ` and whose `likelihood_eltype` matches `eltype(θ)` (so `Float64`
# gives a `Float64` and a `Dual` vector gives a `Dual`), and returns the trace
# log-likelihood. Every stack below consumes this one closure — nothing about the
# optimizer or sampler leaks into the model, and nothing about `θ` is stored
# outside the call.

function make_loglik(mk_board, events, init!, trace)
    return function loglik(θ)
        sim = SimulationFSM(
            mk_board(), events;
            rng=Xoshiro(7), step_likelihood=true, likelihood_eltype=eltype(θ),
            key_type=Tuple, params=θ,
        )
        return trace_likelihood(sim, init!, trace).loglikelihood
    end
end

# For the independent semi-Markov walker in §5 we also want the θ → clock-tuple
# maps as plain functions. They mirror the two models' `enable`s exactly:
# `exp_clocks` reads rates, `wei_clocks` reads clock A's *scale* `θ[1]`, clock B's
# shape `θ[2]` and scale `θ[3]`.

exp_clocks(θ) = (Exponential(inv(θ[1])), Exponential(inv(θ[2])))
wei_clocks(θ) = (Exponential(θ[1]), Weibull(θ[2], θ[3]))

loglik_exp = make_loglik(
    () -> ExpRace.RaceBoard(1), [ExpRace.FireA, ExpRace.FireB], ExpRace.init!, EXP_LOG,
)

# ### Pre-gate: the closure reproduces the closed form
#
# For an always-enabled exponential race the log-likelihood telescopes to
# ``n_A \log\lambda_A + n_B \log\lambda_B - (\lambda_A+\lambda_B)\,t_N``. If the
# closure does not match this at the truth, nothing downstream is trustworthy,
# so we assert it first.

exp_closed_form(λ) = exp_na * log(λ[1]) + exp_nb * log(λ[2]) - (λ[1] + λ[2]) * exp_tN
@assert isapprox(loglik_exp(EXP_TRUTH), exp_closed_form(EXP_TRUTH); atol=1e-9)

# ## §4a  Maximum likelihood with Optim + ForwardDiff
#
# We optimize in the log-parameter space ``\varphi = \log\theta`` so the rates
# stay positive with no box constraints, and let Optim get its gradient from
# ForwardDiff via the ADTypes object `AutoForwardDiff()`. The negative
# log-likelihood is the objective.

nll_exp(φ) = -loglik_exp(exp.(φ))
mle_res = optimize(nll_exp, log.(EXP_TRUTH), LBFGS(); autodiff=AutoForwardDiff())
exp_mle = exp.(Optim.minimizer(mle_res))

# For the always-enabled exponential race the MLE is closed-form,
# ``\hat\lambda_k = n_k / t_N``, so we can check the optimizer exactly.

@assert isapprox(exp_mle, [exp_na, exp_nb] ./ exp_tN; rtol=1e-6)

# Standard errors come from the observed information, the negative Hessian of
# the log-likelihood at the MLE. For this model it is diagonal with entries
# ``n_k / \hat\lambda_k^2``, so the standard error of ``\hat\lambda_k`` is
# ``\hat\lambda_k / \sqrt{n_k}`` — again checkable by hand.

exp_info = -ForwardDiff.hessian(loglik_exp, exp_mle)
exp_se = sqrt.(diag(inv(exp_info)))
@assert isapprox(exp_se, exp_mle ./ sqrt.([exp_na, exp_nb]); rtol=1e-6)

# The committed text block below is exactly the output of these `println`s;
# re-run the script and diff to refresh it.

println("n_A = ", exp_na, "   n_B = ", exp_nb, "   t_N = ", round(exp_tN; digits=3))
println("MLE  λ̂ = ", round.(exp_mle; digits=3), "   (truth ", EXP_TRUTH, ")")
println("SE       ", round.(exp_se; digits=3))

# ```text
# n_A = 77   n_B = 123   t_N = 76.688
# MLE  λ̂ = [1.004, 1.604]   (truth [1.0, 1.6])
# SE       [0.114, 0.145]
# ```

# ## §4b  Posterior via LogDensityProblems + AdvancedMH
#
# To go Bayesian we wrap the closure in a `LogDensityProblems` target. The
# prior is ``\varphi = \log\theta \sim \mathrm{Normal}(0,1)`` on each component,
# which is exactly a `LogNormal(0,1)` prior on the rates themselves — putting the
# prior on the log scale means the sampler explores an unconstrained space and we
# avoid any change-of-variables Jacobian bookkeeping.

struct TracePosterior{L}
    loglik::L
    dim::Int
end

LogDensityProblems.dimension(p::TracePosterior) = p.dim
function LogDensityProblems.capabilities(::Type{<:TracePosterior})
    return LogDensityProblems.LogDensityOrder{0}()
end
function LogDensityProblems.logdensity(p::TracePosterior, φ)
    logprior = sum(logpdf(Normal(0.0, 1.0), φi) for φi in φ)
    return logprior + p.loglik(exp.(φ))
end

exp_post = TracePosterior(loglik_exp, 2)

# AdvancedMH's `RWMH` takes a symmetric random-walk proposal; a small isotropic
# Gaussian in log space mixes well here. We `sample` directly on the
# LogDensityProblems object, start at the MLE, and discard a short warm-up. The
# explicit `Xoshiro` seed makes the chain reproducible.

mh_proposal = AdvancedMH.RWMH(MvNormal(zeros(2), (0.08^2) * I))
mh_chain = AbstractMCMC.sample(
    Xoshiro(SEED_MH), exp_post, mh_proposal, N_MH_DRAWS;
    initial_params=log.(exp_mle), discard_initial=N_MH_BURN,
    param_names=["logλA", "logλB"], chain_type=Chains,
)

# The chain samples ``\varphi``; transform back to rates for the posterior mean
# and check recovery plus a healthy effective sample size.

mh_rates = exp.(Array(mh_chain))
mh_mean = vec(mean(mh_rates; dims=1))
mh_ess = minimum(ess(mh_chain).nt.ess)
@assert isapprox(mh_mean, EXP_TRUTH; rtol=0.15)
@assert mh_ess > 200

println("AdvancedMH RWMH, ", N_MH_DRAWS, " draws (", N_MH_BURN, " warm-up discarded)")
println("  posterior mean rates = ", round.(mh_mean; digits=3), "   (truth ", EXP_TRUTH, ")")
println("  ESS = ", round.(Int, ess(mh_chain).nt.ess))

# ```text
# AdvancedMH RWMH, 20000 draws (2000 warm-up discarded)
#   posterior mean rates = [0.998, 1.602]   (truth [1.0, 1.6])
#   ESS = [1219, 2023]
# ```

# ## §4c  NUTS via AdvancedHMC — the migration's payoff
#
# AdvancedHMC needs gradients, so we wrap the same posterior in an
# `ADgradient(AutoForwardDiff(), …)` and hand it to `LogDensityModel`. Every
# leapfrog step now differentiates `trace_likelihood` through the whole event
# log — the concrete payoff of driving CompetingClocks through the number-generic
# `SamplingContext`. Before the migration this path did not exist.

exp_hmc_model = AdvancedHMC.LogDensityModel(ADgradient(AutoForwardDiff(), exp_post))
hmc_chain = AbstractMCMC.sample(
    Xoshiro(SEED_HMC), exp_hmc_model, AdvancedHMC.NUTS(0.8), N_HMC_ADAPT + N_HMC_DRAWS;
    n_adapts=N_HMC_ADAPT, discard_initial=N_HMC_ADAPT,
    initial_params=log.(exp_mle), chain_type=Chains,
)

hmc_rates = exp.(Array(hmc_chain))
hmc_mean = vec(mean(hmc_rates; dims=1))
hmc_rhat = maximum(skipmissing(rhat(hmc_chain).nt.rhat))
hmc_ess = minimum(ess(hmc_chain).nt.ess)
@assert isapprox(hmc_mean, EXP_TRUTH; rtol=0.15)
@assert hmc_rhat < 1.05
@assert hmc_ess > 200

println("AdvancedHMC NUTS, ", N_HMC_ADAPT, " adapt + ", N_HMC_DRAWS, " draws")
println("  posterior mean rates = ", round.(hmc_mean; digits=3), "   (truth ", EXP_TRUTH, ")")
println("  r̂ = ", round(hmc_rhat; digits=3), ", ESS = ", round.(Int, ess(hmc_chain).nt.ess))

# ```text
# AdvancedHMC NUTS, 500 adapt + 500 draws
#   posterior mean rates = [0.994, 1.599]   (truth [1.0, 1.6])
#   r̂ = 1.003, ESS = [887, 930]
# ```

# ## §4d  The same fit as a Turing `@model`
#
# Turing expresses the same posterior declaratively. `LogNormal(0,1)` priors on
# the rates match §4b's Normal-on-log-θ prior, and `@addlogprob!` folds in the
# ChronoSim trace log-likelihood as the "data" term. Turing's default AD backend
# is ForwardDiff, which is exactly what threads Duals through `enable`: only
# ForwardDiff `Dual`s are stripped at the primal sampling boundary by
# CompetingClocks' `CompetingClocksForwardDiffExt`. Reverse-mode tracked/taped
# values have no analogous extension and the state mutates underneath them, so
# NUTS-with-ForwardDiff (or the gradient-free `MH()`) is the supported route.

@model function race_model(loglik)
    λA ~ LogNormal(0.0, 1.0)
    λB ~ LogNormal(0.0, 1.0)
    Turing.@addlogprob! loglik([λA, λB])
end

tur_chain = sample(
    Xoshiro(SEED_TUR), race_model(loglik_exp), Turing.NUTS(N_TUR_ADAPT, 0.8), N_TUR_DRAWS,
)
tur_mean = [mean(tur_chain[:λA]), mean(tur_chain[:λB])]

# Turing samples the rates directly (it handles the constraint transform
# internally), so its posterior mean should agree with the AdvancedHMC mean of
# §4c up to Monte-Carlo error.

@assert isapprox(tur_mean, hmc_mean; rtol=0.1)

println("Turing NUTS(", N_TUR_ADAPT, ", 0.8), ", N_TUR_DRAWS, " draws")
println("  posterior mean rates = ", round.(tur_mean; digits=3),
    "   (AdvancedHMC gave ", round.(hmc_mean; digits=3), ")")

# ```text
# Turing NUTS(500, 0.8), 1000 draws
#   posterior mean rates = [1.008, 1.595]   (AdvancedHMC gave [0.994, 1.599])
# ```

# ## §5  A Weibull clock: the semi-Markov niche
#
# Now the point of it all. Swap clock B from an `Exponential` to a `Weibull`
# whose shape exceeds one, and the race is no longer memoryless: clock B *ages*
# while it waits, and — because it keeps running across firings of clock A — that
# age is carried across events. This is the semi-Markov behaviour that
# memoryless (CTMC) tooling structurally cannot represent, and it is where a
# GSMP framework earns its keep. The swap is just a different model module
# (`WeiRace`), still reading its numbers from `θ`. Ground truth is
# `θ = [scaleA, shapeB, scaleB] = [1.0, 1.7, 1.2]`; a shape of 1.7 > 1 means
# wearout.

const WEI_TRUTH = [1.0, 1.7, 1.2]
const WEI_LOG = simulate_log(
    () -> WeiRace.RaceBoard(1), [WeiRace.FireA, WeiRace.FireB], WeiRace.init!, WEI_TRUTH;
    nsteps=N_WEI_STEPS, seed=SEED_WEI_LOG,
)
loglik_wei = make_loglik(
    () -> WeiRace.RaceBoard(1), [WeiRace.FireA, WeiRace.FireB], WeiRace.init!, WEI_LOG,
)

# ### §5(i)  An independent clock-age walker
#
# The strongest correctness statement on this page does not trust the framework
# at all. This ~15-line walker recomputes the log-likelihood directly from the
# semi-Markov definition: each clock has an *age* (time since it was last
# enabled), both start at zero, and only the winner's age resets when it fires —
# the loser keeps aging. A clock that survives an interval ``[t_0, t_1]``
# contributes conditional survival ``\log S(\mathrm{age}_1) - \log S(\mathrm{age}_0)``
# (`logccdf` differences); the winner contributes the conditional density
# ``\log f(\mathrm{age}_1) - \log S(\mathrm{age}_0)``. For an exponential the age
# terms cancel and this reduces to the memoryless form; for the Weibull they do
# not, and *that difference is the memory*.

function analytic_semimarkov_loglik(trace, clocks)
    te = [0.0, 0.0]          # time each clock was last enabled (both at t=0)
    tprev = 0.0
    ll = 0.0
    for (tnow, key) in trace
        w = key[1] === :FireA ? 1 : 2
        for k in 1:2
            d = clocks[k]
            age0 = tprev - te[k]
            age1 = tnow - te[k]
            if k == w
                ll += logpdf(d, age1) - logccdf(d, age0)   # winner: conditional density
            else
                ll += logccdf(d, age1) - logccdf(d, age0)   # loser: conditional survival
            end
        end
        te[w] = tnow          # only the winner is re-enabled; its age resets
        tprev = tnow
    end
    return ll
end

# The walker and the framework agree to floating-point tolerance — an
# independent confirmation that ChronoSim scores semi-Markov memory correctly.

@assert isapprox(analytic_semimarkov_loglik(WEI_LOG, wei_clocks(WEI_TRUTH)), loglik_wei(WEI_TRUTH); atol=1e-8)

# ### §5(ii)  Maximum likelihood in three dimensions
#
# There is no closed form now, but the same Optim + ForwardDiff recipe works
# verbatim in three log-parameters. We validate by recovery within four
# standard errors, and — the commercially interesting claim — assert that the
# fitted shape is *significantly* greater than one: the data reveal wearout, not
# memorylessness.

nll_wei(φ) = -loglik_wei(exp.(φ))
wei_res = optimize(nll_wei, log.(WEI_TRUTH), LBFGS(); autodiff=AutoForwardDiff())
wei_mle = exp.(Optim.minimizer(wei_res))
wei_info = -ForwardDiff.hessian(loglik_wei, wei_mle)
wei_se = sqrt.(diag(inv(wei_info)))

@assert all(abs.(wei_mle .- WEI_TRUTH) .< 4 .* wei_se)
@assert wei_mle[2] - 4 * wei_se[2] > 1     # shape is significantly > 1: the clock ages

println("Weibull MLE  θ̂ = [scaleA, shapeB, scaleB] = ", round.(wei_mle; digits=3),
    "   (truth ", WEI_TRUTH, ")")
println("SE                                           ", round.(wei_se; digits=3))
println("shape − 4·SE = ", round(wei_mle[2] - 4 * wei_se[2]; digits=3), " > 1")

# ```text
# Weibull MLE  θ̂ = [scaleA, shapeB, scaleB] = [0.996, 1.808, 1.19]   (truth [1.0, 1.7, 1.2])
# SE                                           [0.062, 0.092, 0.044]
# shape − 4·SE = 1.44 > 1
# ```

# ### §5(iii)  A Bayesian Weibull fit with AdvancedHMC
#
# One posterior for the three-parameter Weibull race, again through NUTS, to show
# the whole pipeline carries over unchanged. We check that the marginal 90%
# credible interval covers the truth for every parameter.

wei_post = TracePosterior(loglik_wei, 3)
wei_hmc_model = AdvancedHMC.LogDensityModel(ADgradient(AutoForwardDiff(), wei_post))
wei_chain = AbstractMCMC.sample(
    Xoshiro(SEED_WEI_HMC), wei_hmc_model, AdvancedHMC.NUTS(0.8), N_WEI_ADAPT + N_WEI_DRAWS;
    n_adapts=N_WEI_ADAPT, discard_initial=N_WEI_ADAPT,
    initial_params=log.(wei_mle), chain_type=Chains,
)

wei_draws = exp.(Array(wei_chain))
wei_lo = [quantile(wei_draws[:, k], 0.05) for k in 1:3]
wei_hi = [quantile(wei_draws[:, k], 0.95) for k in 1:3]
@assert all(wei_lo .<= WEI_TRUTH .<= wei_hi)

println("Weibull AdvancedHMC NUTS, ", N_WEI_ADAPT, " adapt + ", N_WEI_DRAWS, " draws")
for (k, nm) in enumerate(("scaleA", "shapeB", "scaleB"))
    println("  90% CI ", nm, " : [", round(wei_lo[k]; digits=3), ", ",
        round(wei_hi[k]; digits=3), "]  ∋ ", WEI_TRUTH[k])
end

# ```text
# Weibull AdvancedHMC NUTS, 400 adapt + 400 draws
#   90% CI scaleA : [0.899, 1.112]  ∋ 1.0
#   90% CI shapeB : [1.65, 1.947]  ∋ 1.7
#   90% CI scaleB : [1.117, 1.265]  ∋ 1.2
# ```

# ## §6  Notes
#
# **Runtime.** On the reference machine (Apple Silicon, Julia 1.12) this script
# runs in about **1 minute 45 seconds** end-to-end after precompilation; the
# AdvancedMH and HMC chains dominate. Every sampler length is a named constant at
# the top of the file — shrink them if you need it faster.
#
# **Thread-safety.** With the θ seam the likelihood closure carries its
# parameters in `sim.params` — a per-call value, not a module global — so it holds
# no shared mutable state and is safe to run under `MCMCThreads()`. (The pre-seam
# version read its clocks from an `Any`-typed `Ref` and was *not* thread-safe: two
# chains sharing the process raced on that global. Threading it away is one of the
# concrete wins of making θ an explicit argument.)
#
# **Where to go next.** The [trace-evaluation page](trace_evaluation.md) is the
# narrative for `trace_likelihood` itself — feasibility verdicts, the closed-form
# check, and the ForwardDiff mechanics this page builds on.
