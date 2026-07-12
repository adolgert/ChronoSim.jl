```@meta
CurrentModule = ChronoSim
```

# Randomness and reproducibility

Every random number a simulation consumes is now addressed by a name derived
from *model-level identity* — which clock, which event — rather than by its
position in a global draw order (guarantee G7). One consequence is simple
reproducibility: a single recorded integer reproduces an entire run. The deeper
consequence is *ownership*: an event's randomness belongs to that event, so
changing how much randomness one event consumes cannot perturb any other
event's draws. Ownership is what makes coupled clones, common random numbers,
and seed-based replay compositional instead of fragile.

## The master seed

A `SimulationFSM` is driven by one **master seed**, supplied as `seed=` (an
integer) or drawn from `rng=` at construction (one draw), or from the system's
entropy when neither is given. From that one number the framework derives every
stream family the run uses:

* the **sampler's per-clock streams** — CompetingClocks 0.4 gives every sampler
  a `KeyedStreams` table of per-key `Xoshiro` generators, each seeded once from
  `hash((seed, key))`, so each clock's waiting-time randomness is its own
  stream;
* the **fire streams** — a second `KeyedStreams{Tuple}` family owned by the
  framework, keyed by `clock_key(event)`, from which user `fire!` bodies draw.

When event `evt` fires, the generator handed to your `fire!` is that event's
own stream (wrapped in the draw-counting proxy described in
[Records, replay, and the effect check](@ref "Records, replay, and the effect check")).
An immediate event triggered inside a firing draws from *its own* stream, not
the triggering event's — ownership follows model identity, not call nesting.
Initialization draws come from a reserved `(:__init__,)` stream, so the initial
condition reproduces from the seed and is never confused with firing
randomness.

The retained `sim.rng` field is only the documented carrier of the master
seed; it no longer feeds any draw.

!!! warning "Event fields must hash by content"
    Clock keys are tuples of your event's fields, and stream seeding hashes
    them. Every field type must therefore have a content-based `Base.hash`.
    Symbols, numbers, and strings qualify; an `@enum` does **not** — it hashes
    by `objectid`, which differs across Julia processes, so two same-seed runs
    of a model whose events carry enum fields will silently diverge. If an
    event field is an enum `E`, define
    `Base.hash(x::E, h::UInt) = hash(Symbol(x), h)` beside the enum
    definition. (Found in practice by the elevator example's direction enum.)

Every per-key seed derivation in CompetingClocks routes through one
overloadable function, the **canonical stream-hash seam**
`CompetingClocks.stream_hash(seed, key)` (default `hash((seed, key))`). That
seam is what keeps a clock's stream identity attached to its *content* rather
than its representation: when a simulation keys clocks by event instances
instead of clock-key tuples (see [`event_key_union`](@ref)), ChronoSim
overloads the seam to hash the instance's `clock_key` tuple, so the instance
key draws **exactly** the stream its tuple key would have. The
content-hash obligation above is unchanged — whatever the seam hashes, the
event's fields must hash by content.

## The ownership property

The pinned property (`test/test_streams.jl`): make one event's `fire!` draw
three times instead of once, and — at the same seed — every *other* event's
firing draws and the entire firing-time trajectory are byte-identical. Only the
modified event's own draws move. Under global call-order randomness this is
impossible: one extra draw shifts every subsequent consumer. Ownership is the
property that lets you refactor one event's internals, or attach a
draw-consuming diagnostic to it, without invalidating every seeded test in the
model.

Two same-seed runs produce byte-identical trajectories and byte-identical
[`MinimalRecord`](@ref)s — determinism is the trivial half; ownership is the
half worth a name.

## Seed-based replay

Because every stream family derives from the master seed, a recorded
[`TrajectorySkeleton`](@ref) stores just `seed::UInt64` (it previously stored a
full generator snapshot; see the [migration notes](@ref "Migration notes")).
[`replay`](@ref) rebuilds a fresh sim, re-derives all streams from the recorded
seed, and re-runs — reproducing the identical trajectory with no serialized
generator state. Restoring a single global generator's state could not do
this: once draws belong to keys, only the seed that keyed them can reconstruct
them.

## Clones, divergence, and common random numbers

Stream state is part of the world, so `clone(sim)` copies it: a clone continues
bit-identically until you re-seed it. `rekey_streams!(sim, seed)` re-derives
every stream family from a new master seed — the explicit divergence verb.
Rekeying two clones to one shared seed couples them to each other (common
random numbers, CRN: identical randomness for two systems you intend to
compare) while decoupling both from the original. In a coupled θ-versus-θ+h
machine-repair pair, CRN coupling measured a 54.9× variance reduction over
independent seeds. See [Cloning and branching](@ref "Cloning and branching")
for how a branching estimator exploits this.

## What to rely on, and what not to

Contractual: same seed ⇒ same trajectory; per-event ownership of firing draws;
seed-only replay; `rekey_streams!` as the sole divergence mechanism.

Not contractual: the byte layout of streams across package versions, the
number of primitive ticks a given draw consumes, and any correspondence
between a pre-0.4 seeded run and the same seed today (the derivation changed;
see [Migration notes](@ref "Migration notes")).

## Related

* [Cloning and branching](@ref "Cloning and branching") — the estimator-facing
  consumers of coupled streams.
* [Recording and replaying a run](@ref "Recording and replaying a run") — the
  skeleton recorder whose determinism contract rests on this page.
* [The framework guarantees, as implemented](@ref "The framework guarantees, as implemented")
  — G7 and its pinning tests.
