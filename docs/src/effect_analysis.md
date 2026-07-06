# Static effect analysis (`@fire`)

`@precondition` derives what an event *reads*. `@fire` closes the loop by deriving
what an event *writes*: a syntactic taint pass over the `fire!` body produces a
static set of [`WriteSpec`](@ref ChronoSim.WriteSpec)s — the event's effect footprint — which a
runtime oracle then checks against what the event actually changed. The write
masks feed footprint-interference lints, model-checkable effect lowering, and the
`whyrunning` "provably cannot stop" verdict.

`@fire` emits the `fire!` method **verbatim**: annotated and unannotated events
run byte-for-byte identically. All the machinery is analysis metadata.

## Why declare effects

The read side already proved the pattern: `@precondition` finds triggers you would
never list by hand (a `doors_open` write that must rebirth an event). Writes give
you the other half:

  * **Conformance.** [`CheckEffects`](@ref) asserts, after every fire, that every
    changed address matches a declared write — catching an undeclared write the
    moment it happens instead of when a trajectory eventually diverges.
  * **Reachability.** [`can_stop_change`](@ref ChronoSim.can_stop_change) answers whether any event can ever
    write what a stop predicate reads; when none can, `whyrunning` reports the run
    *provably* cannot stop by state change.
  * **Downstream analysis.** The kept write masks and rhs ASTs are the input to
    footprint-interference lints and to effect lowering for a model checker.

## Annotating a `fire!`

Prefix `@fire` to the `fire!` definition. The signature contract is the usual
four arguments `(evt::EvtType, state, when, rng)`:

```julia
@fire function fire!(evt::Infect, physical, when, rng)
    physical.actors[evt.sink].strain = physical.actors[evt.source].strain
    physical.actors[evt.sink].state = Infectious
end
```

The walker understands, in fragment:

  * leaf assignment `x.field = rhs` and container assignment `c[k] = rhs`;
  * the op-assign forms (`+=`, `-=`, `*=`, `/=`, `%=`, `^=`, `÷=`, `|=`, `&=`,
    `⊻=`) — both a read and a write of the same address;
  * the ObservedState mutation API (`push!`, `pushfirst!`, `append!`, `pop!`,
    `popfirst!`, `delete!`, `empty!`, `filter!`, `union!`, `intersect!`,
    `setdiff!`, `symdiff!`, `resize!`, `sizehint!`, `setindex!`);
  * `@obswrite`/`@obsread`;
  * registered [`@fragment`](@ref) helpers (their body is inlined, so a helper's
    writes are seen); and
  * nested `fire!(EvtType(args...), state, when, rng)` calls to other `@fire`d
    events (inlined, with the constructor arguments substituted for the callee's
    event fields).

Loops and branches widen indices exactly as the read pass does: a loop-indexed
write becomes a widened (tainted-index) may-write, and a write under a branch is
recorded unconditionally.

What errors at macro time:

  * a call whose name ends in `!` that receives state and is not a recognized
    mutator (register it with `@fragment`, or rewrite with a recognized form);
  * a `.=` broadcast assignment to state;
  * a body that writes no state at all.

A non-`!` helper that receives state (e.g. `get_direction(person.location, …)`)
is *tolerated*: it is treated as opaque, a note is recorded, and any hidden write
it performs is left for the runtime oracle to catch.

## Reading the WRITES report

`derivation_report(EvtType)` prints a `WRITES` section for any `@fire`d event:

```
Derivation report for Infect
  event fields: source, sink
  triggers: none derived (hand-written generators)
  WRITES (2 sites, 0 widened)
    WRITE [actors, ℤ, strain]  CLEAN  binds: sink  op: assign  rhs: state_expr
    WRITE [actors, ℤ, state]  CLEAN  binds: sink  op: assign  rhs: evt_pure
  rhs mix: evt_pure 1, state_expr 1, stochastic 0, opaque 0
```

Each line is one write site: its address mask (`ℤ` is a widened index position;
a trailing `.*` marks a whole-element/subtree write), `CLEAN` vs `WIDENED` (with
the widened-write count in the header — the over-approximation counter), the
bound event fields, the operation, and the rhs classification. The rhs classes,
in precedence order:

  * `:stochastic` — the value depends on the rng (a `rand`-family call);
  * `:opaque` — the value depends on `when` (time is not modeled), or reads a
    scalar written earlier in the same body (alias staleness), or is otherwise
    unanalyzable;
  * `:evt_pure` — the value is built from event fields, literals, and module-level
    constants (enum instances count);
  * `:state_expr` — the value is a pure expression over state reads and literals.

`:opaque` should be rare — in the example corpus it is about 13% of write sites,
and every occurrence has a named cause (`when`-dependence, an alias-staleness
sequencing, or a loop-variable value). A rising opaque rate is a signal that the
walker lost track of something.

## What the oracle catches

[`CheckEffects`](@ref) is an [`ExecutionPolicy`](@ref ChronoSim.ExecutionPolicy) that enforces the
conformance contract `changed ⊆ declared`: after initialization and after every
fire, every captured changed address must match some declared write mask (unioned
with the specs of any `isimmediate` event types you pass in). Because widening and
the may-write branch union only *add* coverage, the oracle never false-positives
on a loop or a branch — the only throw is a genuinely undeclared write.

Wire it into a test the same way you construct any simulation:

```julia
sim = SimulationFSM(physical, events; seed=42, policy=CheckEffects(events))
ChronoSim.run(sim, InitEvent(), stop)
```

It is opt-in, read-only, and consumes no randomness, so turning it on does not
change the trajectory. Compose it with other diagnostics via `PolicyStack`.

## A worked `EffectCoverageError`

Suppose `Infect` grew a helper that also bumps a location counter, but the helper
is an ordinary function the walker cannot see into:

```julia
sneaky(physical, i) = (physical.locations[i].cnt += 1; nothing)

@fire function fire!(evt::Infect, physical, when, rng)
    physical.actors[evt.sink].strain = physical.actors[evt.source].strain
    physical.actors[evt.sink].state = Infectious
    sneaky(physical, evt.sink)          # undeclared write to :locations
end
```

`@fire` records only the two `actors` writes (and a note that `sneaky` receives
state). At runtime the oracle sees the extra change and throws:

```
EffectCoverageError: event Infect wrote an address not
covered by any WriteSpec.
  changed address: (locations, 3, cnt)
  masked to      : (locations, _index, cnt)
  classified     : missing_container — no WriteSpec names this top-level field (an undeclared effect)
  declared writes (masked):
    (actors, _index, strain)
    (actors, _index, state)
This event performed a write its @fire analysis did not declare — either the write hides behind an opaque helper (register it with @fragment or use a recognized mutation form) or the walker misclassified the address shape.
```

The two-line fix is to make the write visible — either mark the helper
`@fragment` (so its body is inlined and its write derived) or write the mutation
directly in the `fire!` body. `:missing_container` means the changed field's
top-level container is named by no spec; `:shape_mismatch` means the container is
declared but at a different leaf or index shape.

## Related

* Runbook: [Check that events only write what they declare](@ref "Check that events only write what they declare (`@fire` + `CheckEffects`)").
* [Linting a model's footprints](@ref "Linting a model's footprints") — consumes
  the write masks `@fire` derives.
* [Debugging & Verification](@ref) — the overview and symptom-to-technique table.
