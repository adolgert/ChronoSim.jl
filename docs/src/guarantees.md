```@meta
CurrentModule = ChronoSim
```

# The framework guarantees, as implemented

The derivative-estimation framework design (the `simulation_design.tex` design
document, kept with the research notes) states eight guarantees, G1–G8, that
the framework layer makes to estimators. This page is the reference for those
guarantees **as they exist in this codebase**: for each, the invariant, the
API that carries it, and the test that pins it. The second half collects the
hard invariants — the rules that are easy to violate from model code and whose
violation is silent or catastrophic.

Acronyms used below: GSMP (generalized semi-Markov process, the formalism
ChronoSim simulates), IPA (infinitesimal perturbation analysis, the pathwise
derivative estimator), CRN (common random numbers), CTMC (continuous-time
Markov chain).

## The eight guarantees

### G1 — Enabling is a pure function of state, and the rules system is a verified incrementalization of it

*Invariant:* which events can fire depends on the state value alone — never on
history, event order, clock values, θ, or any random number generator — and the
reactive dependency network is admissible only as a performance transformation
provably equivalent to pure recomputation.
*API:* `precondition` (θ-free by signature), read capture in
`sim_event_precondition`, `derivation_spec` declarations, the audit tier
[`enable_read_verification!`](@ref) / `with_read_verification`, and the
production tier [`effect_check`](@ref). The
[three verification tiers](@ref "The three G1 verification tiers") section
explains when to run which.
*Pinned by:* `test/test_verify_reads.jl` (an under-declared read throws loudly
under verification and runs silently without it), `test/test_minimal_record.jl`
(exact-equality replay).

### G2 — State is a value with a clone verb

*Invariant:* the running simulation is a *World* owning everything a trajectory
writes; `clone(sim)` yields an independent copy whose continuation is
bit-identical until explicitly rekeyed; θ lives in neither world nor model but
is passed as an argument.
*API:* `clone(sim)`, `clone(physical)`, [`verify_clone`](@ref ChronoSim.ObservedState.verify_clone),
[`rekey_streams!`](@ref), [`force_fire!`](@ref). See
[Cloning and branching](@ref "Cloning and branching").
*Pinned by:* `test/test_clone.jl` (coupled continuation, divergence on rekey,
original unperturbed, forced-equals-natural).

### G3 — Firing is deterministic given the record

*Invariant:* applying a transition to a state is pure arithmetic; given the
initial condition and the firing sequence, the entire state history is
reconstructible exactly. A firing that draws randomness forfeits record-derived
estimators, and the framework *detects* the draw rather than prohibiting it.
*API:* [`CountingRNG`](@ref) wrapped around every user `fire!`,
`sim.fire_random`, `MinimalRecord.fire_random`, consumer warnings. See the
[fire-randomness tiers](@ref "Fire-randomness: the three tiers").
*Pinned by:* `test/test_minimal_record.jl` (a draw-free run is unflagged; a
drawing `fire!` is flagged; consumers warn; the counter never perturbs the
stream).

### G4 — θ enters only through an explicit seam the model publishes

*Invariant:* the parameter vector is an explicit argument to the enable seam,
so any consumer can re-evaluate a distribution at a θ — including a
dual-valued θ — the forward run never saw; the deeper, θ-free recipe form keeps
simulator, likelihood, replay, and oracle reading one description.
*API:* four-argument [`enable`](@ref), five-argument [`reenable`](@ref),
`params=` on `SimulationFSM` and [`trace_likelihood`](@ref),
[`DistRecipe`](@ref) / [`build_distribution`](@ref) / [`enable_recipe`](@ref) /
[`enable_from_recipe`](@ref). See
[Parameters and differentiation](@ref "Parameters and differentiation").
*Pinned by:* `test/test_theta_seam.jl` (pre-seam models bit-identical;
ForwardDiff gradient matches the analytic score; recipe-derived and
hand-written enables indistinguishable).

### G5 — The minimal record is the first-class product, and replay is the forward loop with a different next-event source

*Invariant:* the record is the initial condition's identity, the
`(clock_key, when)` firing sequence, and the horizon — nothing else; enabled
sets, enabling times, and ages are reconstructed at replay because of G1 and
G3. Replay drives the *same* step loop as forward execution, so agreement is
structural, and per-firing uniforms are *derivable* from the record (given the
coupling label), not stored.
*API:* [`MinimalRecord`](@ref), [`RecordMinimal`](@ref),
[`minimal_record`](@ref), [`forward_loglikelihood`](@ref),
[`effect_check`](@ref), the `MinimalRecord` methods of
[`trace_likelihood`](@ref). See
[Records, replay, and the effect check](@ref "Records, replay, and the effect check").
*Pinned by:* `test/test_minimal_record.jl` (forward log-likelihood equals
replay exactly; skeleton projection equals the policy's record).

### G6 — Memory policy and re-evaluation coupling are explicit choices, each in its proper place

*Invariant:* what happens to accumulated age across a disable/re-enable
(`:fresh` / `:resume`) is declared on the event type, because it is a
distributional statement about the model; what happens to an in-flight draw on
re-evaluation (`:carry`, the default, or `:redraw`) is a construction-time
property of the sampler, chosen via `NextReactionMethod(coupling=...)` /
`FirstToFireMethod(coupling=...)`, because both couplings produce the same law
and only *how the sampler generates its numbers* differs; only `:carry` is
IPA-safe; records are labeled with the sampler's coupling.
*API:* [`memory_policy`](@ref), the banked-age lifecycle inside the framework,
the `coupling` keyword of the scheduling sampler specs,
`CompetingClocks.coupling`, `MinimalRecord.coupling`, the construction-time
error for `coupling=:carry` on a carry-less sampler. See
[Declarations: coupling and memory](@ref "Declarations: coupling and memory").
*Pinned by:* `test/test_declarations.jl` (defaults reproduce the pre-change
trajectory exactly, and a default-constructed FSM is bit-identical to an
explicit coupling=:carry one; carry with an unchanged distribution moves
nothing; resume/fresh each match their own quadrature oracle and differ; the
record labels the sampler's coupling).

### G7 — Random streams have canonical names

*Invariant:* every uniform is addressed by a (stream name, occurrence) key that
is θ-independent and path-independent, derived from model identity — so one
event drawing more leaves every other event's draws and the whole trajectory
unchanged, and one recorded seed reconstructs all streams.
*API:* the master `seed=`, per-clock `KeyedStreams` in CompetingClocks 0.4, the
framework's `fire_streams` keyed by `clock_key`, the reserved `(:__init__,)`
stream, [`rekey_streams!`](@ref), `TrajectorySkeleton.seed`. See
[Randomness and reproducibility](@ref "Randomness and reproducibility").
*Pinned by:* `test/test_streams.jl` (ownership and determinism),
`test/test_skeleton.jl` / `test/test_replay.jl` (seed-only replay), plus the
CompetingClocks 0.4 suite (per-(key, occurrence) CRN across adversarial event
orders).
*Not implemented:* the design's *majorant broker* clause — the three-way
contract for thinning-based channel samplers, where an estimator declares a
θ-neighborhood and the model answers a dominating-rate bound — exists in the
design document and prototypes only. No thinning channel backend ships in
these packages today.

### G8 — Functionals lower to data over the record, and score/IPA pairing is the default validation mode

*Invariant (design):* a trajectory functional is declared once against state
with a smoothness-class type, lowered per trajectory to a θ-free object, and
validated by running the score and IPA estimators on the same lowered
functional.
*As implemented:* the pieces the *evaluator* needs are in place — the
horizon-censoring term [`censoring_loglikelihood`](@ref) (with dual θ flowing
through) and the pairing methodology documented at
[Score/IPA pairing](@ref "The three G1 verification tiers"). The functional
declaration/lowering types (`IntegratedOccupancy`, `TerminalObservable`,
`FirstPassageTime`) remain prototype-level and live with the estimator layer
outside this package, as does the pairing harness itself. See
[How the system fits together](@ref "How the system fits together").
*Pinned by:* `test/test_minimal_record.jl` (censored likelihood matches the
hand-computed value; ForwardDiff through the censored likelihood matches the
analytic score).

## Hard invariants

These are the contracts model and estimator code must uphold. Most are
mechanically checked somewhere; all of them bite silently when broken.

* **Enabling is a pure function of state.** `precondition` reads state and
  returns a Bool — no θ, no RNG, no clocks, no history. Everything from the
  dependency network to record replay assumes it.
* **Firing determinism has tiers.** Draw-free `fire!` keeps the full
  record-derived estimator suite; θ-free draws keep seed-reproducibility but
  forfeit record-derived likelihoods (flagged, warned); θ-dependent draws must
  be remodeled as competing events. See
  [the tiers](@ref "Fire-randomness: the three tiers").
* **Capture windows never span a clone.** Read/write capture opens and drains
  within a single firing; `clone` is only taken between firings and starts the
  clone's tracking buffers empty. Do not clone from inside a `fire!`.
* **`Address` back-pointers are maintained only by `update_index` — `deepcopy`
  of an observed physical state is forbidden.** A naive deep copy can leave
  copied elements notifying the *original's* containers. Use `clone(physical)`
  (which replays the containers' own `update_index` maintenance over the copy)
  and check with [`verify_clone`](@ref ChronoSim.ObservedState.verify_clone). Keeping address maintenance a
  standalone, re-runnable, side-effect-free primitive is a stated architectural
  requirement, not an implementation accident.
* **`enabling_times` records what the sampler was told.** Under `:resume`, the
  stored enabling time is the *left-shifted* value handed to the sampler, which
  is what makes the banked age an assignment rather than a running sum. Code
  that reads `sim.enabling_times` gets the sampler's view, not the model's.
* **The carry no-op is a model contract.** Under `:carry`, `reenable` must
  return the original `firstenabled`, not `when`; returning `when` re-anchors
  the clock and shifts the schedule even though the sampler carried the draw.
* **One evaluation per sim.** `trace_likelihood` re-initializes the physical
  state but not the sampler context, so a second evaluation on the same
  `SimulationFSM` goes infeasible. Build a fresh sim per evaluation.
* **Declarations may over-approximate reads, never under-approximate.** An
  over-declared trigger costs a wasted re-evaluation; an under-declared read
  produces no error, no `NaN`, and no invariant violation — only a
  statistically silent bias, measured at 34 standard errors in the incident
  that motivated the three-tier defense. Over-proposing generators can *mask*
  under-declaration (the model stays correct in law while the declaration is
  wrong), which is exactly why the audit tier exists.
* **The coupling default is `:carry`, the old silent behavior made explicit.**
  The historical `CombinedNextReaction` behavior on re-enabling an enabled key
  was deterministic carry, and the sampler's construction-time `coupling`
  keyword defaults to exactly that, so a default-built simulation preserves
  it. A run that wants fresh redraws on re-evaluation must ask for them at
  construction: `NextReactionMethod(coupling=:redraw)`. See the
  [migration notes](@ref "Migration notes").

## Related

* [How the system fits together](@ref "How the system fits together") — which
  component owns which guarantee.
* The manual pages:
  [Parameters and differentiation](@ref "Parameters and differentiation"),
  [Records, replay, and the effect check](@ref "Records, replay, and the effect check"),
  [Declarations: coupling and memory](@ref "Declarations: coupling and memory"),
  [Cloning and branching](@ref "Cloning and branching"),
  [Randomness and reproducibility](@ref "Randomness and reproducibility").
