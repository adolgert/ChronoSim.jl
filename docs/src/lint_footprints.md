# Linting a model's footprints

`lint` reads the static write masks that `@fire` derives and the static guard-read
masks that `@precondition`/`@guard` derive, intersects them, and reports where one
event can write an address another event's guard reads. Its headline job is to
catch a **missed trigger** — a write that can flip a precondition whose event has
no generator on that address, so the event is never proposed and the trajectory
silently diverges. Two historical ChronoSim bugs, the `doors_open` and
`StopElevator`-`direction` trigger omissions in the elevator, were exactly this
shape; `lint` catches both before any run.

## What interference means here

GSMP events communicate only through physical state. An edge `A → B` says "event
`A` can write an address that event `B`'s precondition reads". At runtime, `B` is
(re)proposed only when a generator of `B` reacts to a change — so if `A` writes an
address that `B` reads but no trigger of `B` covers that address, `A` can enable
`B` without `B` ever being proposed. That is the **missed-proposal risk**, and it
is the one thing `lint` promises to find (in the sound direction).

`lint` reports three edge classes plus a smell:

  * **write→guard** — the interference graph above. An edge that no trigger of the
    reader covers is a `WARNING`; everything else is `info`.
  * **write→write** — two event types whose write masks intersect (info, with the
    shared address). Not a bug per se; a hint about shared state.
  * **write→rate** — NOT analyzed in v1. Every report prints a fixed line saying
    so. Enable-time (`enable`) reads are runtime-only in this version; the
    dependency network tracks them dynamically, and a future version will lower
    them.
  * **dead addresses** — physical fields written by no event and read by no guard
    (info; a rate-only input such as a distance matrix appears here by design).

## Reading the report

Take the SIRVillage reference report (captured verbatim in the runbook):

```
LintReport: 6 events
  write→guard: 18 edges over 2 addresses (0 warnings in 0 groups, 18 info)
  write→write: 17 shared-address pairs (info)
  write→rate edges: not analyzed (enable-time reads are runtime-only in v1; the depnet tracks them dynamically)
  dead addresses: none
  unanalyzed guards: InitEvent    unanalyzed effects: none
  caps: none
```

  * **write→guard line** — 18 interference edges over 2 addresses: 16 on
    `[actors, ℤ, state]` (Infect/Recover/Reset/InitEvent writing the state field
    the four guards read) and 2 on `[actors, ℤ, haunt]` (InitEvent/Travel writing
    the haunt field Infect's guard reads). All info: every reader has a
    `changed(actors[who].state)` (or `.haunt`) trigger that covers the write, so
    no proposal is missed. When there are warnings, they are grouped by
    `(reader, address)` with the writer list inline, so the elevator's 28 warning
    edges read as 15 groups.
  * **write→write line** — 17 co-writer pairs, spread over `actors`
    (state/strain/haunt), `locations`, `strains`, and `next_strain_id` —
    `actors.strain` appears here, not in write→guard (no guard reads it).
    Informational.
  * **rate line** — the honest gap. SIRVillage's `Mutate → Infect` rate dependence
    (Mutate writes `strains[*].infectivity`, Infect's `enable` reads it) appears in
    NO edge; this line is the disclosure.
  * **dead addresses** — none here; landspread's `distance` matrix (read only in
    `enable`) is the canonical hit.
  * **unanalyzed guards / effects** — events the lint could not read: no
    `@guard`/`@precondition` (guards) or no `@fire` (effects). `InitEvent` has no
    precondition, so it is listed — nothing is silently assumed harmless.
  * **caps** — every skipped or capped analysis prints a line. `none` means the
    live `physical` instance let every finite index domain be enumerated.

`show` prints this bounded summary (≤ ~30 lines). `print_lint(io, report)` prints
every edge, one greppable line each, for CI logs.

## Opting a hand-written model in

Derived events (`@precondition`) already expose their reads through
`derivation_spec`, and their generators react to exactly those reads, so a derived
reader can never miss a trigger — it needs nothing.

A hand-written model, whose generators are `@conditionsfor`/`@reactto` blocks, opts
in by:

  * prefixing each `precondition` with **`@guard`** — this emits the precondition
    verbatim (runtime behavior is byte-identical, proven by the differential test
    suite) and bakes its static read specification for the lint, WITHOUT deriving
    generators (the hand-written triggers stay in charge);
  * marking each state-receiving helper with **`@fragment`** so `@guard` can see
    the reads the helper performs.

Unlike `@precondition`, `@guard` tolerates a zero-read body (`precondition(evt,
state) = true` yields an empty spec) and records a whole-container read
(`length`/`keys`) as a container-level pattern instead of demanding a covering
trigger — because catching an uncovered whole-container read is precisely what the
lint is for.

## The allowlist

A warning is not always a bug. A hand-written model often narrows its triggers
deliberately: the reader is re-proposed through a *correlated* trigger in every
reachable state, so a narrower trigger set is sound even though the mask analysis
cannot see the reachability argument. Those intended narrowings go in a
`LintAllow` vector passed to `assert_lint_clean`:

```julia
ChronoSim.assert_lint_clean(report; allow=[
    ChronoSim.LintAllow(reader=:PickNewDestination, mask="[person, ℤ, waiting]",
                        reason="waiting is cleared with location; re-triggers on location"),
])
```

Each `LintAllow` matches by `reader`/`writer`/`mask` (any field `nothing` is a
wildcard) and carries a **mandatory `reason`**. The `mask` string is exactly what
the report prints, so entries are grep-copyable from a failing report. An `allow`
entry that matches no warning prints a staleness notice (it does not fail) — so the
allowlist decays loudly when a narrowing is fixed. The hand-written elevator's
15-entry allowlist (one per warning group) is the worked example, reviewed once and
kept in its test file.

## What static analysis can and cannot see

The honest-scope commitments (binding):

  * **Masks only.** `lint` sees address masks — container, index kind, leaf field —
    not guard truth values, not arithmetic on indices, not relational constraints
    *between* index positions. It cannot tell that two events touch disjoint
    elements unless the index constraints are literal or finitely enumerable.
  * **No expression semantics, no SMT.** The optional Satisfiability stretch is
    dropped; the [model checker](@ref "Model checking a simulation") subsumes it.
  * **No rate (`enable`) reads.** Write→rate edges are not analyzed in v1, stated in
    every report.
  * **Enumeration is finite and capped.** With a live `physical` instance, a
    `:possible` index intersection is refined by enumerating the inferred finite
    domain (`@domain`, container keys, finite field types) with a hard `enum_cap`;
    a provably empty overlap demotes the edge to info (the edge stays in the
    report). Every skipped or capped domain prints a `caps:` line — never silent.
  * **Warnings are over-approximate** (hence the allowlist); **info edges are not
    proofs of interaction**. The one guarantee is the soundness direction: a
    genuinely interfering pair always appears as an edge; only provably disjoint
    pairs are dropped. (The converse does NOT hold — an edge is not proof of real
    interference; mask analysis cannot deliver no-false-edges.) That direction is
    tested in CI as *static ⊇ dynamic* — a `LintHarvest` policy records every
    runtime enable-dependency edge on a smoke run and `static_covers_dynamic`
    asserts the static report covers all of them.

## Related

* Runbook: [Lint a model's footprints](@ref "Lint a model's footprints (interference, races, missed triggers)").
* [Static effect analysis (`@fire`)](@ref "Static effect analysis (`@fire`)") —
  where the write masks `lint` reads come from.
* [Debugging a simulation](@ref "Debugging a simulation") — the runtime why-verbs
  that catch a missed trigger `lint` would flag statically.
* [Debugging & Verification](@ref) — the overview and symptom-to-technique table.
