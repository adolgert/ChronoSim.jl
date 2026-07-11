```@meta
CurrentModule = ChronoSim
```

# Migration notes

The derivative-estimation adoption changed four things a pre-existing model or
script can observe: the parameter seam, the CompetingClocks 0.4 sampler
interface, the skeleton schema, and the reproducibility model. This page lists
each change, who is affected, and what to do. The short version: **model code
compiles and runs unchanged**; scripts that constructed samplers directly,
archived skeletons, or pinned seeded trajectories need attention.

## The θ seam: three-argument `enable` still works

The engine now calls `enable(event, physical, θ, when)` and
`reenable(event, physical, θ, firstenabled, when)`. The default four-argument
`enable` drops θ and forwards to your three-argument method (same for
`reenable`), so **every pre-seam model runs bit-for-bit unchanged** — this is
plain Julia dispatch, not a deprecation layer, and it is pinned by a same-seed
trajectory test.

Migrate an event only when it actually reads a parameter: change its signature
to the four-argument form, read rates from `θ`, and pass `params=` to
`SimulationFSM` (or to `trace_likelihood`). If your model routed parameters
through a module-global `Ref` for ForwardDiff (the old documented idiom),
replace that with the seam — it removes the shared mutable state and its
thread-unsafety. See
[Parameters and differentiation](@ref "Parameters and differentiation").

## CompetingClocks 0.4

ChronoSim requires CompetingClocks 0.4, whose breaking change is that samplers
own their randomness (keyed streams) and the verbs lost their RNG arguments.
The break is contained below `SamplingContext`, so code driving simulations
through `SimulationFSM` is unaffected. What you may notice:

* **Passing a sampler *instance* is no longer supported.**
  `SimulationFSM(...; sampler=CombinedNextReaction{K,Float64}())` throws an
  `ArgumentError` with guidance; write
  `sampler=NextReactionMethod(), key_type=K` instead. The framework owns the
  generator and builds the context itself.
* **`CommonRandom` and its record/replay machinery were deleted.** Per-key
  streams *are* the CRN mechanism now: two samplers built from one seed consume
  identical per-(key, occurrence) draws regardless of event order. For coupled
  pairs of whole simulations, use `clone` + `rekey_streams!` to a shared seed
  (see [Cloning and branching](@ref "Cloning and branching")).
* **`clone` on a sampler is now the full-state copy**; the old empty-shell
  semantics moved to `similar_sampler`. Code that used `clone` to get a blank
  sampler should call `similar_sampler`.

## The skeleton schema: `rng_state` became `seed`

`TrajectorySkeleton` no longer stores a `rng_state::Xoshiro` snapshot; it
stores `seed::UInt64`, the master seed, and [`replay`](@ref) reconstructs every
stream family from that one number. Restoring a global generator's state
cannot reproduce draws once draws belong to keys, so the snapshot had to go.
Code reading `skel.rng_state` must read `skel.seed`. Archived `.skel` files do
not load across this change — which was already the documented policy, since
the serialization format is version-bound. Re-record.

## The master-seed reproducibility model

Randomness is now derived as: master seed → per-family seeds → per-key
streams (see [Randomness and reproducibility](@ref "Randomness and reproducibility")).
Consequences:

* **Old seeded trajectories differ.** A run at `seed=k` today produces a
  different (equally valid) trajectory than the same seed produced before the
  adoption, because draws are laid out per key rather than in global call
  order. Tests that pin exact trajectories, per-step times, or drawn values at
  a fixed seed must re-pin their literals once. Statistical assertions and
  hand-derived oracles are stream-layout independent and need no change —
  across the adoption itself, no numeric re-pin weakened an invariant.
* **`rng=Xoshiro(k)` and `seed=k` are both still accepted**; `rng=` is
  consumed for one draw that becomes the master seed. `sim.rng` no longer feeds
  any draw.

## The re-evaluation coupling is a sampler construction choice, defaulting to carry

How a still-enabled clock's in-flight draw is reconciled with a mid-flight
distribution change — the re-evaluation *coupling* — is chosen once, when the
sampler is constructed, not per event and not per call:

```julia
sim = SimulationFSM(physical, events;
    sampler=NextReactionMethod(coupling=:redraw), key_type=Tuple)
```

The default is `:carry`, which maps the retained draw through the change by
matching conditional survival — deterministic, consuming no randomness, the
only IPA-safe coupling, and exactly the historical silent behavior of the
default backend (`CombinedNextReaction`) when a still-enabled key was
re-enabled. A default-built simulation therefore preserves the old behavior. A
run that wants fresh redraws on re-evaluation (`:redraw`, a fresh draw of the
remaining lifetime conditioned on age) must ask for them at construction.
There was briefly a per-event-type coupling declaration, which defaulted to
`:redraw`; it is gone, and its default with it. For carry to be a no-op on an
unchanged distribution, `reenable` must return `firstenabled`, not `when` (see
[Declarations: coupling and memory](@ref "Declarations: coupling and memory")).
Requesting `coupling=:carry` from a sampler that cannot carry
(`CompetingClocks.supports_carry` false) errors at construction.

## Checklist

1. Model event definitions: no change required. Move events to the
   four-argument `enable` only when they read parameters.
2. `SimulationFSM(...; sampler=<instance>)`: replace with a method spec plus
   `key_type`.
3. Uses of `skel.rng_state`: replace with `skel.seed`; re-record archived
   skeletons.
4. Tests pinning exact seeded trajectories: re-pin literals once.
5. Models adding state-dependent rates: choose the sampler's re-evaluation
   coupling at construction (`NextReactionMethod(coupling=...)`), and declare
   `memory_policy` if clocks are preempted and resumed.
