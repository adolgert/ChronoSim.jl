```@meta
CurrentModule = ChronoSim
```

# Cloning and branching

Some derivative estimators cannot work from a single trajectory. A *branching*
(weak-derivative) estimator, at selected steps of a base path, splits the world
in two, forces a different event to fire in each copy, runs both copies to the
horizon, and differences the results. That demands one capability from the
framework: the running simulation must be **a value with a clone verb**
(guarantee G2) — an independent copy whose future behavior is bit-for-bit the
original's until you deliberately diverge it. This page describes `clone`,
`verify_clone`, `rekey_streams!`, and `force_fire!`, and sketches how a
branching estimator drives them.

## `clone(sim)`: what is copied, what is shared

`clone(sim::SimulationFSM)` returns an independent copy of the whole running
simulation. Everything a trajectory *writes* is copied; everything a trajectory
only *reads* is shared:

* **Copied** — the physical state (with the address protocol restored, below);
  the sampler context *with its live clock and stream state*; the per-event
  fire streams (state-carrying, so `fire!` draws reproduce); the dependency
  network; the enabled-event, enabling-time, and banked-age tables.
* **Shared** — the model-side generator searches, the parameter vector `θ`
  (read-only by the seam contract), the observer, and the policy. A policy that
  accumulates mutable per-run state should be re-attached by the caller if the
  clone needs independent accounting.

The defining property is the **coupled continuation**: because the clone
carries the original's random-stream state at the clone point, stepping the
clone produces *exactly* the firings, times, and states the original would have
produced — verified over a 60-time-unit Weibull horizon with draw-consuming
`fire!` bodies in `test/test_clone.jl`. Taking a clone perturbs nothing: the
original, continued, matches an uninterrupted same-seed run.

```julia
coupled = clone(sim)      # continues the SAME world as sim
branch  = clone(sim)
rekey_streams!(branch, 0xD1F0)   # now an INDEPENDENT continuation
```

Divergence is an explicit act: [`rekey_streams!`](@ref)`(sim, seed)` re-seeds
every stream family from a new master seed, after which the clone runs its own
future. There is no way to diverge a clone *accidentally* — "pass a different
RNG" is not an operation the API offers — which is precisely the property a
coupled-pair estimator needs. Rekeying two clones to the *same* fresh seed
gives a pair that is decoupled from the base path but coupled to each other:
common random numbers (CRN — the variance-reduction technique of giving two
compared systems identical randomness) across the pair.

## Why not `deepcopy`?

Every element of an observed physical state carries an `Address` whose
`container` field is a back-pointer to the container that holds it — the
mechanism behind change tracking. A naive `deepcopy` follows those
back-pointers and, depending on traversal order, can leave a copied element
notifying the *original's* container: the clone would mutate the original
through a hidden shared edge. `clone(physical)` instead copies the structure
and then **replays the containers' own `update_index` maintenance** over the
copy, rebinding every back-pointer to the copied container. The clone's
tracking buffers start empty — a capture window opens and drains within a
single firing, and clones are only taken between firings, so no pending
capture can span a clone.

[`verify_clone`](@ref ChronoSim.ObservedState.verify_clone)`(original, clone)` is the debug verifier: it checks
structural equality without aliasing (mutating either side leaves the other
untouched) and notify isolation (a tracked write on the clone lands only in
the clone's buffers). Run it in tests when you add container kinds or nested
mutable fields to your physical state.

## `force_fire!(sim, event_key, tstar)`

A branching estimator does not let the race choose: it imposes the branch's
chosen event at the chosen time. [`force_fire!`](@ref) fires an
currently-enabled event at `tstar >= sim.when` through the **same state-update
path** as a natural firing — state update, dependency-network maintenance,
memory bank, policy hooks, and observer are all identical, because the
resulting world depends on which transition ran, not on why it ran. Only the
sampler commit differs: the chosen clock is imposed and the losing clocks are
re-conditioned on survival past `tstar`. Forcing the event the race would have
picked, at the time it would have fired, is indistinguishable from the natural
step (pinned in `test/test_clone.jl`).

`force_fire!` requires a backend whose `CompetingClocks.supports_force` trait
is true; the default `NextReactionMethod` backend qualifies.

## Sketch: a branching estimator

The Pflug weak-derivative estimator with the Hahn–Jordan split, driven entirely
through public verbs. WorldTimer's `src/ChronoBranch/` module is the worked,
oracle-validated example; the shape is:

```julia
while true
    (tstar, natural) = next(sim.sampler)          # peek the race
    tstar <= horizon || break

    ages  = enabled_ages(sim.sampler, tstar)      # the competing set, with ages
    dp    = ForwardDiff.derivative(x -> selection_pmf(ages, θ, x), θ[k])
    c, p⁺, p⁻ = hahn_jordan(dp)                   # c·(p⁺ − p⁻) = dp
    if c > 0
        seed = rand(est_rng, UInt64)              # ONE seed for both branches
        for (p, out) in ((p⁺, :A), (p⁻, :B))
            cl = clone(sim)                       # coupled copy of the world
            rekey_streams!(cl, seed)              # decouple from base, couple A↔B
            force_fire!(cl, pick(p, est_rng), tstar)
            f[out] = run_to_horizon!(cl, horizon) # read the functional from state
        end
        estimate += c * (f[:A] - f[:B])
    end

    ChronoSim.fire!(sim, tstar, natural)          # the base path continues naturally
end
```

Three details carry the statistics:

* the selection probability mass function (pmf) is rebuilt from the enabled set
  and the [θ seam](@ref "Parameters and differentiation") at a dual-valued θ —
  the estimator, not the sampler, owns the derivative;
* both branch clones are rekeyed to *one* shared seed, so their continuations
  are CRN-coupled and the difference `f(A) − f(B)` has low variance — forced to
  the same event with the same seed, they satisfy `f(A) == f(B)` exactly;
* the estimator's own selection randomness (`est_rng`) is a separate generator,
  so it never perturbs the simulation's streams.

The base path itself never branches, and the base path's record is untouched by
forcing — clones are estimator-internal, and their functionals are read from
state, not from records.

The same clone/force/rekey verbs also drive the ClockGradients package's
smoothed-perturbation-analysis estimator (`spa_gradient`), which weights each
possible event-order swap by a hazard and estimates the swap's effect with one
coupled clone pair fired in the two orders at the same instant. Running it over
a ChronoSim simulation needs one extra ingredient the branching estimator does
not: a **pure model twin** — a five-function ClockGradients model
(`initial_state`/`enabled`/`clock_distribution`/`fire`, all pure functions,
clock keys matching `clock_key`) implementing the same law as the ChronoSim
model, on which the estimator replays records and speculatively fires event
pairs. The estimator audits the twin against the live simulation's enabled set
at every step and stops with a named error on the first disagreement, so a
drifted twin cannot silently bias the estimate. See the ClockGradients manual
("Choosing an estimator") for when SPA beats branching and what it requires.

## Related

* [Randomness and reproducibility](@ref "Randomness and reproducibility") — the
  master seed and keyed streams that make the coupled-clone property possible.
* [How the system fits together](@ref "How the system fits together") — where
  the estimator layer lives relative to the framework and the sampler.
* [The framework guarantees, as implemented](@ref "The framework guarantees, as implemented")
  — G2, with the tests that pin the clone protocol.
