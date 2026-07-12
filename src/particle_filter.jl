"""
    ChronoSim.ParticleFilter

Latent-state inference over a partially observed ChronoSim model: a bootstrap
particle filter (sequential Monte Carlo) whose particles are LIVE simulations
built from a [`GsmpModel`](@ref). This submodule is deliberately separate from
the engine: it is the first CLIENT of the engine's latent-state primitives —
[`advance!`](@ref) (pause a simulation at an observation time and resume it),
`clone` (duplicate a running world), and `rekey_streams!` (give a duplicate
fresh randomness) — and a pointer to where a fuller inference layer
(rejuvenation moves, adaptive resampling, particle MCMC) would live. It uses
ONLY public engine verbs; nothing here reaches into engine internals.

The filter targets the standard state-space form: a latent continuous-time
trajectory observed at times `t₁ < t₂ < …` through a known emission density
`p(yⱼ | x(tⱼ))`. Because the simulator itself proposes the latent transitions
(the "bootstrap" choice), transition densities cancel from the importance
weight and only the emission log-likelihood is ever evaluated — the filter
needs no trajectory-likelihood machinery, no right-censoring bookkeeping, and
works for any clock distributions the engine can simulate.

```julia
using ChronoSim.ParticleFilter

result = bootstrap_filter(model, θ, times, ys;
    emission_loglikelihood = (physical, y) -> logpdf(Binomial(ndown(physical), 0.6), y),
    statistic = physical -> ndown(physical),
    nparticles = 1000, seed = UInt64(42))
result.logZ    # unbiased estimate (in the likelihood domain) of log p(y₁:ₖ; θ)
result.stats   # posterior mean of `statistic` at each observation time
```

Adopted from the WorldTimer ParticleFilter prototype, where the design and
its statistical validation against an exact forward-filter oracle are written
up (`knowledge/proto_particle_filter.md` in that repository).
"""
module ParticleFilter

using Random

using ..ChronoSim: ChronoSim, SimulationFSM, GsmpModel, advance!, model_initial
import CompetingClocks: clone, rekey_streams!

export bootstrap_filter, simulate_observations, systematic_resample!

"""
    particle(model::GsmpModel, θ; seed, sampler=nothing) -> SimulationFSM

One live, initialized particle: a resumable simulation of `model` at `θ`,
ready for [`advance!`](@ref ChronoSim.advance!). Built through the
model-value constructor and the initial-law path, so a particle's entire
lifecycle is `particle` at birth, `advance!` between observations, and
`clone` + `rekey_streams!` at resampling.

Requires a schedule-retaining sampler whose context-level `next` is a
non-mutating reservation (the default `NextReactionMethod`; NOT
`FirstReaction`) — the same requirement as `advance!`.
"""
function particle(model::GsmpModel, θ::AbstractVector; seed, sampler=nothing)
    sim = SimulationFSM(model, θ; seed=seed, sampler=sampler)
    ChronoSim.initialize!(sim, model_initial(model))
    return sim
end

# Max-shifted log-sum-exp; an all-(-Inf) input returns -Inf rather than NaN.
function logsumexp(x::AbstractVector{<:Real})
    m = maximum(x)
    isfinite(m) || return m
    return m + log(sum(xi -> exp(xi - m), x))
end

"""
    systematic_resample!(anc, w, u) -> anc

Systematic resampling: one uniform `u ∈ [0, 1)` places `N` equally spaced
points `(k − 1 + u)/N` against the cumulative weights, and `anc[k]` is the
ancestor index whose cumulative span contains point `k`. Offspring counts are
guaranteed within one of `N·w[i]`.
"""
function systematic_resample!(anc::Vector{Int}, w::AbstractVector{<:Real}, u::Real)
    0.0 <= u < 1.0 || throw(ArgumentError(
        "systematic resampling needs u ∈ [0, 1); got $u"))
    N = length(anc)
    length(w) == N || throw(ArgumentError(
        "weight and ancestor buffers disagree: $(length(w)) vs $N"))
    c = w[1]
    i = 1
    for k in 1:N
        pos = (k - 1 + u) / N
        while pos > c && i < N
            i += 1
            c += w[i]
        end
        anc[k] = i
    end
    return anc
end

"""
    bootstrap_filter(model::GsmpModel, θ, times, ys;
                     emission_loglikelihood, nparticles, seed,
                     statistic=nothing, sampler=nothing)
        -> (logZ, stats, ess, particles)

The bootstrap particle filter for `model` at parameter vector `θ`, against
observations `ys[j]` made at strictly increasing `times[j]`.

Per observation step, every particle is advanced to the observation time with
[`advance!`](@ref ChronoSim.advance!); weighted by
`emission_loglikelihood(sim.physical, ys[j])` ALONE (the simulator is its own
proposal, so transition densities cancel — no other likelihood term exists in
this filter); the marginal-likelihood recursion accumulates
`logZ += logsumexp(logw) − log(N)`; and the population is resampled
systematically, with EVERY offspring rekeyed:

```julia
newparticles[i] = clone(particles[anc[i]])
rekey_streams!(newparticles[i], rand(rng, UInt64))
```

The rekey is the correctness-critical step: a cloned-but-not-rekeyed
duplicate shares its ancestor's random streams and stays bit-identical to it
forever, silently collapsing particle diversity. Rekeying a singleton costs
one seed draw, so the rekey is unconditional. All filter-owned randomness
(resampling uniforms, offspring seeds) comes from one `Xoshiro(seed)` that
never perturbs any particle's streams.

Resampling runs at EVERY step, which keeps the `logZ` recursion the textbook
one; `exp(logZ)` is then an unbiased estimate of the marginal likelihood
`p(y₁:ₖ; θ)` — the property pseudo-marginal (particle MCMC) methods need.
ESS-triggered resampling is a deliberate non-feature for now and is recorded
per step in `ess` as a diagnostic instead.

Returns a NamedTuple: `logZ`; `stats` — the posterior (weighted) mean of
`statistic(physical)` at each observation time, or `nothing` when no
`statistic` is given; `ess` — effective sample size per step; `particles` —
the final resampled population, each a live simulation at the last
observation time.

Numerical note: exactness at edge cases belongs to the emission closure. If
an uninformative observation must contribute EXACTLY zero log-weight (a
useful oracle hook), the closure must return literal `0.0` there rather than
trusting a library density to hit it.
"""
function bootstrap_filter(
    model::GsmpModel, θ::AbstractVector,
    times::AbstractVector{<:Real}, ys::AbstractVector;
    emission_loglikelihood, nparticles::Int, seed,
    statistic=nothing, sampler=nothing,
)
    K = length(times)
    length(ys) == K || throw(ArgumentError(
        "got $(length(ys)) observations for $K observation times"))
    K > 0 || throw(ArgumentError("bootstrap_filter needs at least one observation"))
    issorted(times; lt=(<=)) || throw(ArgumentError(
        "observation times must be strictly increasing"))
    nparticles > 0 || throw(ArgumentError("nparticles must be positive"))

    rng = Xoshiro(UInt64(seed))
    particles = [particle(model, θ; seed=rand(rng, UInt64), sampler=sampler)
                 for _ in 1:nparticles]
    newparticles = similar(particles)
    logw = Vector{Float64}(undef, nparticles)
    w = Vector{Float64}(undef, nparticles)
    anc = Vector{Int}(undef, nparticles)
    stats = statistic === nothing ? nothing : Vector{Float64}(undef, K)
    ess = Vector{Float64}(undef, K)
    logZ = 0.0
    for j in 1:K
        τ = times[j]
        for i in 1:nparticles
            advance!(particles[i], τ)
            logw[i] = emission_loglikelihood(particles[i].physical, ys[j])
        end
        shift = logsumexp(logw)
        isfinite(shift) || error(
            "every particle has zero likelihood for observation $j (y=$(ys[j])); " *
            "the filter is degenerate at N=$nparticles")
        logZ += shift - log(nparticles)
        @. w = exp(logw - shift)     # sums to one by construction of the shift
        if statistic !== nothing
            stats[j] = sum(w[i] * statistic(particles[i].physical) for i in 1:nparticles)
        end
        ess[j] = 1.0 / sum(abs2, w)
        systematic_resample!(anc, w, rand(rng))
        for i in 1:nparticles
            newparticles[i] = clone(particles[anc[i]])
            rekey_streams!(newparticles[i], rand(rng, UInt64))
        end
        particles, newparticles = newparticles, particles
    end
    return (logZ=logZ, stats=stats, ess=ess, particles=particles)
end

"""
    simulate_observations(rng::AbstractRNG, model::GsmpModel, θ, times; observe)
        -> Vector

One ground-truth trajectory of `model` at `θ`, observed at each time in
`times` by `observe(rng, physical) -> y` — the data-generating counterpart of
[`bootstrap_filter`](@ref). The trajectory's master seed is the one draw
taken from `rng` before observation noise, so latent dynamics and observation
noise come from disjoint generators (the truth simulation's streams derive
from the master seed alone).
"""
function simulate_observations(
    rng::AbstractRNG, model::GsmpModel, θ::AbstractVector,
    times::AbstractVector{<:Real}; observe,
)
    sim = particle(model, θ; seed=rand(rng, UInt64))
    return [(advance!(sim, τ); observe(rng, sim.physical)) for τ in times]
end

end # module ParticleFilter
