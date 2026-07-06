# Model checking a simulation

The same registered ASTs that *run* a ChronoSim model — `@precondition` guards,
`@fire` effects, `@fragment` helpers, `@invariant`s — already carry its full
discrete semantics. [`compile_quint`](@ref) prints them as a
[Quint](https://quint-lang.org) module, and [`validate_trace`](@ref) checks a
recorded trajectory against that module. This closes the loop in both directions:
the spec checks your runs exhaustively, and your runs check the compiler.

Compiling needs nothing but Julia. *Checking* the emitted module needs the Quint
toolchain (Node) and, for symbolic proofs, a JVM for Apalache — both discovered by
[`find_quint_toolchain`](@ref) and, when absent, reported as a loud `:skipped`
verdict rather than a silent pass.

## 1. What you get

* An integer/Bool/enum/set model of the **discrete jump skeleton** of your GSMP.
  Continuous quantities — firing times (`when`), rates, ages — are *erased*: they
  decide *when* events fire, never *whether* a guard holds, and bounded model
  checking over reals is out of scope.
* Two directions of trust. `quint verify` (Apalache) proves your `@invariant`s
  hold over every reachable state to a bounded depth. `validate_trace` proves a
  *recorded* run is a legal path of the compiled spec — if the compiler and the
  simulator disagree, one of them has a bug.

## 2. Compile

```julia
using ChronoSim
qm = compile_quint(ElevatorDerivedExample, EVENTS, ElevatorSystem(3, 2, 5);
                   name="elevator", invariants=ElevatorExample)
write_quint("elevator.qnt", qm)
show(stdout, MIME"text/plain"(), qm.report)
```

Read the emitted `.qnt` side by side with the Julia source: each `@precondition`
becomes an `all { … }` of guard conjuncts *before* the primed variable
assignments (guard-before-effect is load-bearing — a disabled action never
evaluates its effect); each `@fire` becomes those primed updates; each
`@fragment` becomes a `pure def`; precondition-recursion becomes a shared
`pure def precond_<Event>(…)`. The compilation report is a bounded, greppable
block:

```
quint compilation: ElevatorDerivedExample (9 events)
  clean   : PickNewDestination CallElevator OpenElevatorDoors EnterElevator ExitElevator CloseElevatorDoors MoveElevator StopElevator DispatchElevator
  widened : (none)
  assumed : (none)
  skipped : (none)
  refused : (none)
constants promoted: floor_cnt
records collapsed : ElevatorCall -> requested
fields erased     : (none)
invariants        : 8 compiled, 0 refused
widenings total   : 0 (v1 refuses where the design allowed widening; `// WIDENED:` markers reserved)
```

Every deviation from a 1:1 transliteration is **loud**. A field a guard never
reads is *promoted* to a `pure val` (shrinking the state space); a single-field
`@keyedby` element *collapses* to its bare value; a `Float64` field is *erased*.
Where the design allowed a widened (over-approximate) emission — a dict-key
argmin with an unspecified tie-break, a non-uniform draw's erased weights — v1
**refuses instead** (`:unordered_fold`, `:unsupported_call`): stricter than
required, and never a silent over-approximation. The `// WIDENED:` marker plus
`report.widenings` is the reserved surface for a future opt-in widening mode;
the reconciliation test pins marker count == report count (both 0 today).

## 3. Check

The compiler emits one `val inv_<name>` per `@invariant` (the declared name,
sanitized, kept in a trailing comment) plus the grouping `val inv` — the
conjunction of every compiled invariant and the usual checker target.

```
# fast falsification (Node only, seconds)
quint run --max-steps=200 --max-samples=2000 --seed=42 --invariant=inv elevator.qnt

# bounded proof (Apalache; needs JAVA_HOME)
quint verify --max-steps=5 --invariant=inv elevator.qnt
# or one invariant at a time, to localize:
quint verify --max-steps=5 --invariant=inv_no_ghost_calls elevator.qnt
```

`quint run` samples random traces and is the right first tool — it falsifies in
seconds. `quint verify` explores *every* trace to the given depth and proves the
invariant (or returns a counterexample). Depth costs time: on the 3-person
instance the compiled `inv` at depth 5 proves in ~25 s; the Phase-0 hand
translation took ~10 min for its type invariant at depth 10 and ~1.5 min for its
safety invariant at depth 8 (the calibration table lives in
`quint_spike/RESULTS.md`). Choose small instances and grow the depth until the
wall-clock hurts.

## 4. Validate a trace

Record a run with [`RecordSkeleton`](@ref), then hand the skeleton and the *same
factory* `replay` uses to [`validate_trace`](@ref):

```julia
rec = RecordSkeleton()
sim, init = factory(rec)                 # factory(policy) -> (sim, initializer)
ChronoSim.run(sim, init, stop)
skel = recorded_skeleton(rec)

qm  = compile_quint(model, EVENTS, physical; invariants=InvModule)
rep = validate_trace(qm, skel, factory)
show(stdout, MIME"text/plain"(), rep)
```

```
trace validation: elevator
  steps        : 4 checked / 4 total
  invariants   : PASSED
  transitions  : PASSED
  log[invariants]  : /tmp/quint_trace_xyz/stage1_run.log
  log[transitions]  : /tmp/quint_trace_xyz/stage2_verify.log
  wall-clock   : 14.0 s
```

Stage 1 (`invariants`, `quint run`, Node) checks that every reconstructed state
satisfies every compiled invariant. Stage 2 (`transitions`, `quint verify`,
Apalache) checks that every recorded transition is *accepted* by the recorded
event's compiled action from the preceding state.

Then the demo with teeth. Recompile with one guard operator mis-emitted and watch
stage 2 fail — and the ascending localization loop name the exact rejected
transition (captured output):

```julia
qmm = compile_quint(model, EVENTS, physical; invariants=InvModule,
    mutate_for_test=(event=:CallElevator, from=:!=, to=:(==), occurrence=2))
validate_trace(qmm, skel, factory)
```

```
trace validation: elevator
  steps        : 4 checked / 4 total
  invariants   : PASSED
  transitions  : FAILED
  first failure: step 3 event CallElevator at when=3.0204157240506944 (transitions stage)
  log[invariants]  : .../stage1_run.log
  log[localize]  : .../stage2_localize_4.log
  log[transitions]  : .../stage2_verify.log
  wall-clock   : 49.17 s
```

## 5. Read each failure

* **Compile refusal (float read).** `QuintCompileError(:float_read)` names the
  event, the chain, and its `file:line`. The float never gated discrete behavior:
  model the gate as an integer/enum field, or `skip_events=[:Event]` and record
  the skip.
* **Invariant violation (Apalache).** A counterexample trace. First decide *which
  side is wrong*: a translation bug (the spec is stricter/looser than the model)
  or a genuine model finding. Re-derive the compiled action by hand against the
  Julia source before blaming the model.
* **Stage-1 trace failure.** A recorded state violates a compiled invariant — the
  simulator and the spec disagree about what states are legal. `first_failure`
  names the violating state's step and event, parsed from the deterministic
  counterexample.
* **Stage-2 trace failure.** A recorded transition is rejected by the compiled
  guard/effect (Apalache reports `Deadlock`) — the thesis case: the guard the
  simulator ran and the guard the spec models disagree. The ascending
  localization loop (`notReach_k` targets, shallow verifies) pins the first
  rejected step into `first_failure`.
* **`:skipped`.** The toolchain is absent; the report quotes the exact install
  commands from `quint_spike/VERSIONS.md`.
* **`:error`.** The checker itself crashed or printed unparseable output — the
  log tail is in `skip_reason`, the full log at the reported path. Never
  conflated with `:failed`.

## 6. Limits

The compiled spec is the **integer fragment** of the model. Floats are erased;
`when`, rates, and ages are out of scope by construction (a `@precondition` takes
only `(evt, state)`, so a firing time cannot appear in a guard). v1 **refuses**
every construct the design allowed to widen (dict-key argmin tie-breaks,
non-uniform draw supports): a compiled module is therefore exact on the integer
fragment, never a silent superset. The `// WIDENED:` marker mechanism and
`report.widenings` remain as the documented surface for a future opt-in widening
mode — a proof over a widened spec would still be sound for safety, just no
longer exact. Future work: ITF-JSON trace export, that widening mode, and lifting
the integer restriction where a bounded real abstraction is tractable.
