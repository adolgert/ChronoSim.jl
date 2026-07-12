```@meta
CurrentModule = ChronoSim
```

# Parameters and differentiation

Every clock in a ChronoSim model has a waiting-time distribution, and those
distributions have parameters: failure rates, repair rates, Weibull shapes. This
page describes the **θ (parameter) seam** — the single, explicit path by which a
parameter vector `θ` travels from the caller, through the simulation, into each
event's `enable` function. The seam is what lets an estimator re-evaluate a
recorded trajectory's likelihood at a `θ` the forward run never saw — including a
dual-valued `θ` from
[ForwardDiff.jl](https://github.com/JuliaDiff/ForwardDiff.jl), which is how the
gradient of a trajectory's log-likelihood (the *score function*) is computed. It
implements guarantee G4 of the framework design; the
[guarantees reference](@ref "The framework guarantees, as implemented") lists all
eight.

## The four-argument `enable`

The engine calls a four-argument form of [`enable`](@ref), threading the
simulation's parameter vector between the physical state and the time:

```julia
enable(event, physical, θ, when) -> (distribution, te)
```

A model whose rates are parameters reads them from `θ` instead of from a
constant or a module global:

```julia
enable(::Fail, physical, θ, when) = (Exponential(inv(θ[1])), when)
```

`θ` is `sim.params`, an `AbstractVector` you supply at construction with the
`params=` keyword (default `Float64[]`):

```julia
sim = SimulationFSM(physical, events; seed=1, params=[0.5, 1.5])
```

The same seam exists for [`reenable`](@ref) as a five-argument form,
`reenable(event, physical, θ, firstenabled, when)`. A model that recomputes its
distribution on a state change forwards to the four-argument `enable`:

```julia
reenable(e::MyEvent, phys, θ, firstenabled, when) =
    (first(enable(e, phys, θ, when)), firstenabled)
```

Note the return of `firstenabled`, not `when` — that keeps the clock anchored at
its original enabling time, which matters for the re-evaluation couplings
described in [Coupling and memory declarations](@ref "Declarations: coupling and memory").

**Backward compatibility is pure dispatch.** The default four-argument `enable`
drops `θ` and forwards to the three-argument method (and the five-argument
`reenable` likewise forwards to the four-argument one), so every model written
against the old θ-free signature runs bit-for-bit unchanged. There is no
deprecation machinery; you change an event's signature only when that event
actually reads a parameter. See the [migration notes](@ref "Migration notes")
for the full compatibility story.

Two rules keep the seam honest:

* **θ carries only distribution parameters, never state.** Whether an event is
  enabled is a pure function of the physical state alone (guarantee G1);
  `precondition` never sees `θ`.
* **The sampler never sees θ.** The seam returns a realized distribution object;
  CompetingClocks samples from it at concrete `Float64` values. Parameters and
  their derivatives live entirely on the model/likelihood side.

## The named parameter view

Indexing `θ` positionally works, but it buries the meaning of `θ[1]` in an
`enable` body. An event family can instead read its parameters **by name**,
through a binding declared in the model's event list.

Two vocabularies meet here, and the design keeps them separate — the same
distinction as a function's formal parameters versus the actual arguments at a
call site:

* **Formal names** belong to the event's *code*. The event author declares
  them once, as a trait (the same defaults-by-dispatch layering as
  [`memory_policy`](@ref)):

  ```julia
  ChronoSim.param_names(::Type{Break}) = (:shape, :scale)
  ```

* **Actual names** belong to the *model*: the components of this simulation's
  global θ, named by the `param_names=` keyword of [`SimulationFSM`](@ref).

The [`entry`](@ref) in the event list binds formals to actuals:

```julia
sim = SimulationFSM(shop,
    (entry(Break; params=(shape=:fail_shape, scale=:fail_scale)),
     entry(Repair; params=(rate=:repair_rate,)));
    params=[1.6, 1.5, 0.5],
    param_names=(:fail_shape, :fail_scale, :repair_rate), seed=1)
```

At construction the binding resolves to integer indices; at enabling time the
engine gathers exactly the bound components and passes the event a `NamedTuple`
view through the **same** θ seam argument:

```julia
enable(evt::Break, physical, p, when) = (Weibull(p.shape, p.scale), when)
```

`p.shape` is a compile-time field load — the symbols are wiring that exists
only at model construction — and building the view allocates nothing. The
view's element type follows `eltype(θ)`, so a dual-valued θ flows through a
bound family exactly as it does through a positional one. When formal and
actual names coincide, the binding is the identity and `entry(Break)` (or the
bare type `Break` in the list) suffices; the formals still resolve **by name**
against the global list, wherever those names sit in it.

**The declaration enforces itself.** The event receives *only* the components
its binding names. Reading `p.repair_rate` when the binding does not include it
is an immediate field error at the call — not a silently wrong gradient
sparsity discovered by a z-test later. Under-declaration is impossible rather
than merely detectable; over-declaring an unused name costs one gathered number
per call and is visible.

**Migration is pure dispatch, again.** A family with no declared binding (an
empty `param_names` trait and no entry `params`) receives the whole global
vector unchanged — the very same object — so every positional model runs
bit-for-bit as before. Declaring formals is what opts a family into the named
view.

One footnote: a `NamedTuple` also supports integer indexing, so `p[1]` works
under a binding — but it means "my *first formal*", not "the model's first θ
component", which is the reading one would want anyway.

## Evaluating a trace at an explicit θ

[`trace_likelihood`](@ref) accepts a `params=` keyword, so a recorded trajectory
can be scored at any parameter vector — one the forward run never used:

```julia
ev = trace_likelihood(sim, init!, trace; params=[0.6, 1.4])
```

Before initialization, `sim.params` is set to the passed vector, so every
`enable` the replay performs reads the new `θ`. Because the field is set in
place, `sim.params` stays at the passed vector after the call.

One limitation to plan around: **a `SimulationFSM` evaluates one trace per
instance.** `trace_likelihood` re-initializes the physical state but does not
reset the sampler context, so a second evaluation on the same `sim` goes
infeasible. Build a fresh sim per evaluation — cheap in practice, and the
pattern the closure below shows.

## Differentiating through the seam

The trace log-likelihood at fixed event order is a smooth function of `θ`, and
ForwardDiff differentiates it by pushing `Dual` numbers through the seam. The
mechanics are two keywords:

* `params=θ` routes the (possibly dual-valued) vector into `enable`;
* `likelihood_eltype=eltype(θ)` sizes the likelihood accumulator so a `Dual`
  fits where a `Float64` did (it also auto-enables `step_likelihood`).

The whole closure, mirroring `test/test_theta_seam.jl`:

```julia
using ForwardDiff

function loglik(θ)
    sim = SimulationFSM(Board(), events;
        seed=1, key_type=Tuple,
        step_likelihood=true, likelihood_eltype=eltype(θ))
    return trace_likelihood(sim, init!, trace; params=θ).loglikelihood
end

score = ForwardDiff.gradient(loglik, [2.0, 3.0])   # ∇_θ log L
info  = -ForwardDiff.hessian(loglik, [2.0, 3.0])   # observed information
```

Evaluated at a plain `Float64` vector the same closure returns a `Float64`;
`eltype(θ)` does the switching. Because no module global is involved, the
closure holds no shared mutable state — evaluating it from several threads (as
`MCMCThreads()` does) is safe, which the pre-seam `Ref`-based idiom was not.

Passing `θ` through the constructor (`params=θ` on `SimulationFSM`) and through
the `trace_likelihood` keyword produce exactly equal gradients; the keyword is
the convenient form for an estimator that evaluates many `θ` against fresh sims.

The [Calibrating from an Event Log](@ref "Calibrating a model from an event log")
example drives this closure through four inference stacks — Optim for maximum
likelihood, AdvancedMH, AdvancedHMC's NUTS, and Turing — and is written entirely
against the seam.

## The recipe layer: `DistRecipe`

The seam hands an estimator a way to *call* the model at a new `θ`. Some
consumers need more: a **record-derived** estimator must rebuild each clock's
distribution at an arbitrary `θ` *without re-running model code*, an exact
oracle (for example a continuous-time Markov chain, CTMC, computed by
quadrature) must know *how* `θ` enters each rate, and the engine's
"distribution changed while the event stayed enabled" trigger needs a value it
can compare. All three need a θ-free, storable *description* of the
distribution rather than the distribution itself. That description is
[`DistRecipe`](@ref):

```julia
DistRecipe(fam, param, mult, shape)
```

an `isbits` struct naming the family (`FAM_EXPONENTIAL` or
`FAM_WEIBULL`), which component of `θ` governs the rate, a
state-dependent rate multiplier, and a fixed shape (`NaN` for the exponential,
which has none). [`build_distribution`](@ref)`(recipe, θ)` realizes it at any
`θ` — with rate `mult * θ[param]` — and keeps `eltype(θ)` as the distribution's
parameter type, so a dual `θ` flows through.

An event opts in by defining [`enable_recipe`](@ref) and *deriving* its
four-argument `enable` from it with [`enable_from_recipe`](@ref):

```julia
enable_recipe(::Fail, phys, when) = (DistRecipe(FAM_EXPONENTIAL, 1, 1.0, NaN), when)
enable(e::Fail, phys, θ, when)    = enable_from_recipe(e, phys, θ, when)
```

The derivation is the point: the simulator, the likelihood replay, the record
builder, and any oracle all read *one* source of truth, so the parameterization
cannot fork between them. A recipe-derived event and a hand-written
four-argument `enable` produce identical trajectories and log-likelihoods
(pinned in `test/test_theta_seam.jl`); use the recipe form when anything besides
the forward run will consume the distribution's structure.

Recipes compare **by value**, with the exponential's `NaN` shape compared via
`isequal` so two identical exponential recipes are equal — the property the
changed-while-enabled trigger relies on.

## Related

* [Evaluating a trace against a model](@ref "Evaluating a trace against a model")
  — the trace evaluator this page's closure wraps, including horizon censoring.
* [Records, replay, and the effect check](@ref "Records, replay, and the effect check")
  — the `MinimalRecord` methods that accept the same `params=` keyword.
* [Migration notes](@ref "Migration notes") — moving a pre-seam model onto the
  four-argument form.
