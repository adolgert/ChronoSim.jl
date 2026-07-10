```@meta
CurrentModule = ChronoSim
```

# Declarations: coupling and memory

Two behaviors of a clock used to be silent properties of whichever sampler
backend you happened to run: what happens to a clock's in-flight draw when its
distribution is re-evaluated while it stays enabled, and what happens to a
clock's accumulated age when its event is disabled and later re-enabled. Both
are now explicit, per-event-type declarations (guarantee G6):
[`reevaluation_coupling`](@ref) and [`memory_policy`](@ref). The declarations
matter statistically — the choices are identical *in law* but inequivalent for
*derivatives* — and they matter for model semantics: a preempted job that
resumes is a different model than one that restarts.

Both are declared on the event **type**, not the instance:

```julia
reevaluation_coupling(::Type{Worker}) = :carry    # default :redraw
memory_policy(::Type{Complete})       = :resume   # default :fresh
```

## Re-evaluation coupling: `:redraw` versus `:carry`

When a firing changes state that an enabled event's rate depends on, the
framework calls [`reenable`](@ref); if it returns a fresh distribution, the
sampler must reconcile the clock's existing draw with the new distribution.
The *law* — a piecewise hazard, with the clock keeping its age — is one
formula, but two implementations (couplings) realize it:

* **`:redraw`** (the default) — the sampler discards the in-flight draw and
  draws the remaining lifetime fresh at the current age. Correct for
  likelihood work, but **not differentiable** in a distribution parameter: an
  infinitesimal rate change consumes a brand-new uniform, so the firing time
  jumps discontinuously.
* **`:carry`** — the sampler maps the retained draw through the distribution
  change by matching conditional survival, consuming no fresh randomness. This
  is the only coupling under which a firing time moves *continuously* in a
  distribution parameter, which is exactly what infinitesimal perturbation
  analysis (IPA, the pathwise derivative estimator) needs. **Declare `:carry`
  on any event whose derivative you intend to take pathwise.**

Not every backend can carry a mid-flight draw. `:carry` requires a sampler
whose `CompetingClocks.supports_carry` trait is `true` — `CombinedNextReaction`
(the default `NextReactionMethod` backend) and `FirstToFire` qualify — and
declaring `:carry` against a sampler that cannot carry raises a descriptive
error at the re-evaluation site rather than silently redrawing.

The couplings that actually ran during a run are tracked and stamped into the
record: `MinimalRecord.coupling` reports `:redraw`, `:carry`, or `:mixed`, so a
record-derived estimator knows which inversion formula describes the trace it
holds (see [Records, replay, and the effect check](@ref "Records, replay, and the effect check")).

### The carry no-op contract: return `firstenabled`, not `when`

`:carry` with an *unchanged* distribution must leave the schedule bit-for-bit
intact — that is the property that makes it safe to declare broadly. But the
no-op is a **model** contract as much as a sampler one: `reenable` must return
the clock's *original* enabling time (`firstenabled`), not the current time.
Returning `when` re-anchors the clock at the moment of re-evaluation and shifts
the schedule even under carry. The safe idiom, from `test/test_declarations.jl`:

```julia
# Re-evaluate the rate from state; keep the clock anchored at its first enabling.
reenable(e::Worker, s, θ, firstenabled, when) =
    (first(enable(e, s, θ, when)), firstenabled)
reevaluation_coupling(::Type{Worker}) = :carry
```

### A migration hazard worth knowing

Historically, the `CombinedNextReaction` backend's behavior when an enabled
key was re-enabled *was* deterministic carry — silently. The declaration
default is `:redraw`. Existing models are unaffected (no shipped model returns
a schedule-changing `reenable`), but a model that newly opts into rate
re-evaluation without declaring a coupling gets `:redraw`, not the old silent
carry. Declare what you mean. The
[migration notes](@ref "Migration notes") restate this.

## Memory policy: `:fresh` versus `:resume`

A different lifecycle: the event is **disabled** (its precondition went false)
and later **re-enabled** — a preempt/resume cycle, not a mid-flight
re-evaluation.

* **`:fresh`** (the default) — the re-enabled clock starts over from age zero.
  Work done before the disable is forgotten. This is renewal-on-disable
  semantics and the historical behavior.
* **`:resume`** — the enabled age the clock accumulated before its disable is
  **banked**, and the re-enabling draw is conditioned on survival past the
  banked age, so the total service requirement is preserved across preemptions.
  This is the semantics of a pausable job.

The engine implements `:resume` with a three-point banked-age lifecycle, all
internal to the framework:

1. **On an unfired disable**, the clock's accumulated active age
   (`when − te_given`, where `te_given` is the enabling time the sampler was
   told) is banked. Because `enabling_times` stores the already-shifted value,
   the bank self-accumulates across repeated preempt/resume cycles.
2. **On re-enable**, the enabling time handed to the sampler is left-shifted by
   the bank (`te_used = te_model − banked_age`), so any age-carrying backend
   draws the remaining lifetime conditioned on the age the clock already has.
   No new sampler mechanism is involved — the left-shifted-`te` idiom is the
   same one `enable` has always supported for hazards that began accumulating
   in the past.
3. **On fire**, the draw is consumed and the bank entry deleted; a later
   re-enable starts fresh.

A `:fresh` event never touches the bank, so a model with no declarations runs
bit-for-bit as before (pinned by a golden-trajectory test).

`:resume` is observably different from `:fresh` only for clocks with memory:
the memoryless exponential makes the two policies coincide, so use a Weibull or
Gamma clock when testing that a declaration took effect. The discriminating
oracle test lives in `test/test_declarations.jl` ("the resume and fresh memory
policies each match their own quadrature oracle and differ").

One documented untested corner: `:resume` combined with a *while-enabled*
re-evaluation of the same clock is out of scope — the two declarations are
exercised on separate events.

## Related

* [Parameters and differentiation](@ref "Parameters and differentiation") — the
  θ-seam `reenable` signature the carry idiom above uses.
* [Records, replay, and the effect check](@ref "Records, replay, and the effect check")
  — the record's coupling label, and the effect check that stays exact across
  carry, redraw, and resume.
* [The framework guarantees, as implemented](@ref "The framework guarantees, as implemented")
  — G6, with the tests that pin each declaration.
