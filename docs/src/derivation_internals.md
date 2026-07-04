# Derivation Internals

This page explains precisely how `@precondition` turns an enabling rule into
generators. The [Generators](generators.md) page of the manual tells a
modeler what to write; this page tells a contributor what the machinery does
and why it is sound. The implementation lives in `src/derive.jl`, and the
runtime checks live in `src/coverage.jl`.

## Three binding times

The derivation is staged, and each stage runs with exactly the information
that is available to it.

1. **Macro-expansion time.** The `@precondition` macro sees only syntax. It
   walks the body, resolves local aliases, classifies every state read, and
   embeds the result — a vector of `ReadSpec` values — into the emitted
   code. It emits the precondition method verbatim, a
   `generators(::Type{Evt})` method that defers to the next stage, and a
   `derivation_spec(::Type{Evt})` method that exposes the specs to
   diagnostics and to the coverage oracle.
2. **Setup time.** The first call to `generators(Evt)`, which happens when
   `SimulationFSM` assembles its generator search, runs
   `derived_generators(Evt, specs)`. At this point the event type is a real
   type, so field names, field types, and `@domain` methods are all
   available. This stage deduplicates and merges the specs, resolves a
   domain for every field that some trigger must enumerate, reports missing
   domains as errors, and closes over everything to build ordinary
   `EventGenerator` values. The runtime dispatch (`GeneratorSearch`) does
   not know derived generators from hand-written ones.
3. **Loop time.** The generator closures run when a matching address
   changes. A closure receives the concrete indices from the changed
   address, reconstructs the event's identifying fields from them, checks
   any literal-index guards, enumerates the domains of unbound fields, and
   calls `generate` for each candidate. Domain closures execute against the
   live state, so container-keyed domains track the container's current
   contents.

Readers who know partial evaluation will recognize the staging: the macro
performs a binding-time separation in the sense of Jones, Gomard, and
Sestoft, with the event type and state left dynamic until setup and loop
time respectively.

## What the taint pass records

A `ReadSpec` describes one read site: the masked address pattern (field
names kept, index positions replaced by a placeholder), one index
classification per index position, and the source text for diagnostics.
Index classifications are the heart of the analysis.

- A **field binding** records that this position is exactly `evt.f` (or a
  local provably equal to it), so at loop time the concrete index at this
  position *is* the value of field `f`.
- A **literal** records a constant index, which becomes a runtime guard: the
  trigger matches the pattern but proposes only when the concrete index
  equals the literal.
- A **tainted** position is anything else — an index computed from state, a
  loop variable, an arithmetic expression over event fields, a helper's
  return value. Tainted means the address alone cannot identify the event
  instance.
- A **tuple index** (a dictionary keyed by tuples, or a multi-dimensional
  array) classifies each component separately.

The walker handles straight-line code, `if`/`&&`/`||`/comparisons, `for` and
`while` loops (including iteration over state containers with
destructuring), and the reducers `any`/`all`/`count`/`sum`/`prod`/
`minimum`/`maximum` over generator expressions, which it walks exactly like
loops. Local variables are tracked in scoped environments: a local bound to
a state access acts as an alias whose reads resolve through it, and a local
bound to an expression over event fields and literals is *evt-pure* and may
appear in indices without tainting them. Aliases introduced inside a loop
or branch are scoped to it.

Calls are the fragment boundary. A call whose arguments include the state,
a state alias, or a state access is admissible only if the callee is
registered: `@fragment` registers a helper's parameters and body at
macro-expansion time, keyed by module, name, and arity, and `@precondition`
registers its own body keyed by event type. At a registered call site the
walker substitutes the actual argument expressions for the formals, renames
the callee's locals with fresh symbols so call sites stay independent, and
walks the substituted body under the same judgment, to a bounded depth and
with cycle detection. Substitution is what preserves precision: a caller
passing `evt.f` into a parameter used as an index yields a field binding,
not a widened trigger. For calls to `precondition(EvtType(args...), state)`,
the field-to-argument correspondence comes from `fieldnames` reflection on
the already-defined event type. An unregistered callee that receives state
is an error, never a guess.

## From specs to triggers

Setup time groups the specs by masked pattern and merges each group into one
trigger.

- If every spec in the group is clean, the trigger is **clean**. It carries
  one binding set per distinct way the pattern's indices bind event fields,
  and at loop time it proposes one event per binding set, with literal
  guards applied and any unbound fields enumerated over their domains.
- If any spec in the group is tainted, the whole trigger **widens**: it
  ignores the concrete indices and proposes the event over the full product
  of its field domains. Widening a pattern that also has clean specs is
  deliberate, because the widened proposals are a superset of the bound
  ones.

Domains resolve per field, in a fixed order of precedence: an explicit
`@domain` method wins; otherwise, if some clean spec binds the field at a
container index position, the container's `eachindex`, `keys`, projected key
component, or axis supplies the domain; otherwise a finite field type
(`Enum` or `Bool`) supplies its instances; otherwise setup fails with a
message naming the field and all three attempts. A scalar state field (a
read like `state.floor_cnt`) produces a single-component pattern with an
empty binding set, which behaves like a widened trigger for that one
address.

## Why this is sound

The generator contract is that the proposed events must be a superset of
the events whose enabling could have changed. Two observations carry the
argument. First, within the analyzed fragment, every address a precondition
can dynamically read is an instance of one of its recorded patterns, with
the concrete components at bound positions equal to the event's field
values — the walker collects every syntactic form that can read state and
errs on anything it cannot see through. Second, if an event's enabling
value differs between the states before and after a firing, the
precondition must have read some changed address in one of those states, so
the changed address matches one of the event's patterns, and the trigger at
that pattern proposes the event: exactly when clean bindings recover it, or
by domain enumeration when widened. Over-proposal is filtered by the
precondition; under-proposal cannot occur within the fragment. The
remaining obligations — that recorded writes cover actual changes, and that
declared domains cover the values an enabled event can take — belong to the
[state contract](state_contract.md) and to domain resolution respectively.

Readers familiar with incremental computation will recognize the division
of labor: for events that are already enabled, the framework re-executes
exactly the reads that changed, in the manner of self-adjusting
computation, while the derived triggers handle the case self-adjusting
computation leaves open, namely computations (events) that do not exist
yet. Production-rule systems solved the matching side of this problem with
the Rete algorithm, but with hand-declared patterns; the derivation's
contribution is that the patterns come from the enabling rule itself.

## The runtime checks

Two switchable diagnostics tie the static analysis back to observed
behavior.

The **coverage oracle**, `check_derivation_coverage(true)`, intercepts
every precondition evaluation of an event type that has a
`derivation_spec` method and asserts that each address the evaluation
actually read matches one of the derived patterns after masking. Its error
distinguishes an address whose leading field no spec mentions (possibly a
read of untracked configuration, which suggests a `Param` wrapping) from an
address that matches a spec's container but not its shape (which indicates
a derivation bug). Only precondition reads are checked: `enable` reads are
rate dependencies, which the dynamic dependency network owns for enabled
events, and which birth triggers never need.

The **candidate counters**, `collect_generation_stats(true)`, tally
proposed and admitted events per event type, so the cost of widening and
domain enumeration is measurable rather than guessed at. The differential
tests in ChronoSimExamples.jl run both twins of each model — hand-written
and derived generators — under one seed and assert byte-identical
trajectories, which is made meaningful by the framework's policy of
processing event candidates in sorted clock-key order, so that trajectories
depend on the proposed set and not on the order generators emit proposals.
