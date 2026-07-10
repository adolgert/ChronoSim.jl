```@meta
CurrentModule = ChronoSim
```

# Records, replay, and the effect check

A derivative estimator that works from recorded trajectories needs to trust the
record: given the initial condition and the firing sequence, replay must
reconstruct the same states, the same enabled sets, and the same likelihood the
forward run saw. This page describes the machinery that makes a record
trustworthy: the pinned [`MinimalRecord`](@ref) schema, the
[`RecordMinimal`](@ref) recording policy, the [`effect_check`](@ref) that
asserts forward and replay agree to the last bit, horizon censoring for
fixed-window functionals, and the detector for randomness inside `fire!`.

This page is about *statistical* records — the least data a likelihood or a
derivative estimator needs. The
[record/replay debugging page](@ref "Recording and replaying a run") covers the
richer [`TrajectorySkeleton`](@ref), which additionally stores per-step
enable/disable history for time-travel debugging; the two compose, and a
skeleton projects down to a `MinimalRecord` (below).

## The minimal record

A [`MinimalRecord`](@ref) is everything a record-derived estimator needs and
nothing more:

* `initializer` — the identity of the initial condition (an init event, an init
  function, or opaque metadata naming it). The framework stores it and hands it
  back; it never interprets it.
* `firings` — the firing sequence as `(clock_key, when)` pairs in firing order.
* `horizon` — the trajectory's end time (defaults to the last firing's time).
* `coupling` — an honest per-run label of which *re-evaluation coupling*
  actually ran: `:redraw`, `:carry`, or `:mixed` when both did. A coupling is
  the rule the sampler applies when a still-enabled clock's distribution is
  replaced mid-flight; the label matters because the formula that recovers a
  firing's underlying uniform draw from the record differs per coupling, so an
  unlabeled trace is underdetermined for pathwise work. See
  [Declarations: coupling and memory](@ref "Declarations: coupling and memory").
* `fire_random` — `true` if any firing drew randomness (see the tiers below).
  Consumers of a fire-random record warn.

Deliberately absent: enabled sets, enabling times, clock ages, segment
boundaries. All of these are *reconstructed* at replay, because enabling is a
pure function of state (guarantee G1) and firing is deterministic given the
record (guarantee G3). The record stays small because the model itself is the
decompressor.

## Recording a run

[`RecordMinimal`](@ref) is an [`ExecutionPolicy`](@ref): pass it to
`SimulationFSM` and it observes the run without perturbing it. When the sim is
built with `step_likelihood=true` it also accumulates the forward
log-likelihood through the very `steploglikelihood` call the trace evaluator
uses:

```julia
pol = RecordMinimal(; initializer=MyInit())
sim = SimulationFSM(phys, EVENTS; seed=1, step_likelihood=true, policy=pol)
ChronoSim.run(sim, MyInit(), stop)

rec = minimal_record(pol; horizon=10.0)   # the pinned schema
fwd = forward_loglikelihood(pol)          # forward-accumulated log-likelihood
```

[`minimal_record`](@ref) also projects a rich [`TrajectorySkeleton`](@ref) down
to the same schema, so a skeleton recorded for debugging doubles as an
estimator input.

## Replaying a record

The `MinimalRecord` methods of [`trace_likelihood`](@ref) evaluate a record
against a freshly built sim:

```julia
ev = trace_likelihood(sim, MyInit(), rec; params=θ, censor=true)
```

* `params=θ` threads the [θ seam](@ref "Parameters and differentiation"): the
  record is scored at an explicit — possibly dual-valued — parameter vector the
  forward run never saw. This is the score-function estimator's whole mechanism.
* `censor=true` opts into horizon-aware scoring (next section).

Replay is not a second loop kept in sync with the forward executor by code
review: both drive the *same* internal step loop, differing only in where the
next event comes from (the sampler's race versus a cursor over the record).
Forward/replay agreement is therefore structural, which is what makes the
following check meaningful.

## The effect check

[`effect_check`](@ref) is the production-grade consistency check: replay the
engine's own record through `trace_likelihood` and demand that the replayed
log-likelihood equal the forward accumulation **exactly** — Float64 `==`, not
`≈`:

```julia
res = effect_check(() -> SimulationFSM(phys, EVENTS; step_likelihood=true),
                   MyInit(), pol)
res.passed   # true, or the two numbers disagree in some bit
```

Exact equality is achievable because forward execution and trace evaluation
share the step loop and the enable path, so both evaluate `steploglikelihood`
on identical inputs. Any drift — however small — is an incrementalization bug:
the dependency network re-evaluated a different set of events than a pure
recomputation would have. This is the check that caught a 34-standard-error
silently biased estimate caused by one under-declared read dependency, on 20 of
20 trajectories, where a tolerance-based comparison would have passed. It is
the third tier of guarantee G1's defense in depth; the
[three verification tiers](@ref "The three G1 verification tiers") section
explains when to run which tier.

## Scoring over a finite horizon

`trace_likelihood` stops at the last recorded event, so its log-likelihood is
that of a trajectory that *ends* at its final firing. A trajectory *observed
over a fixed window* `[0, horizon]` has one more factor: the probability that
no enabled clock fired between the last event and the horizon.
[`censoring_loglikelihood`](@ref)`(sim, horizon)` computes that survival tail —
generic in the likelihood element type, so a dual `θ` differentiates through
it — and `censor=true` on the `MinimalRecord` methods adds it automatically
using the record's own `horizon`.

A score estimator for a finite-horizon functional (for example, the expected
number of failures by time `T`) is *wrong* without this term; for an
always-enabled exponential race it is exactly the difference between
`n/λ − t_N` and `n/λ − T` in the score. Censoring is opt-in, never default,
because the effect check compares against a forward accumulation that has no
censoring term — defaulting it on would break the exact-equality symmetry.

## Fire-randomness: the three tiers

User `fire!` bodies receive a random number generator, and some models
legitimately draw from it — a repair severity, a routing choice. But a firing
that draws breaks guarantee G3: the trajectory is no longer a deterministic
function of the initial condition plus the firing sequence, so a record-derived
likelihood need not correspond to the trajectory that produced it. The
framework's obligation is *detection*, not prohibition: every `fire!` receives
a [`CountingRNG`](@ref), a byte-for-byte stream-preserving proxy that counts
draws, and a run in which any firing drew is flagged in
`MinimalRecord.fire_random`. This sorts models into three tiers:

1. **Draw-free firing** — the full record-derived estimator suite applies:
   `effect_check` (which requires it), record-replayed scores, derivative
   estimators built on the record.
2. **Draws that do not depend on θ** — the run is still *recordable and
   reproducible*: firing draws come from per-event keyed streams derived from
   the master seed (see
   [Randomness and reproducibility](@ref "Randomness and reproducibility")),
   so a same-seed replay reproduces them exactly. But the draws are invisible
   to the path likelihood, so record-derived likelihood work warns
   (`fire_random=true`) and the effect check reports itself not applicable.
3. **Draws that depend on θ** — the honest fix is to *model the choice as
   competing events*, so the randomness returns to the clock race where the
   likelihood can see it. A θ-dependent draw hidden inside `fire!` cannot enter
   any likelihood or derivative this framework computes.

## Related

* [Parameters and differentiation](@ref "Parameters and differentiation") — the
  `params=` seam these record evaluations thread.
* [Evaluating a trace against a model](@ref "Evaluating a trace against a model")
  — the underlying trace evaluator, feasibility verdicts, and the verification
  tiers.
* [Recording and replaying a run](@ref "Recording and replaying a run") — the
  debugging-grade skeleton recorder and time-travel replay.
* [The framework guarantees, as implemented](@ref "The framework guarantees, as implemented")
  — G3 and G5, which this page's machinery carries.
