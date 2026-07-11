# Debugging & Verification

ChronoSim ships a layer of tools for understanding a run that finished wrong,
proving a model right, and catching the bugs that a stochastic simulation hides
best — the missed trigger that silently drops an event, the invariant that goes
false a thousand steps before anything crashes. Every technique here shares three
commitments. It is **opt-in**: nothing runs unless you ask for it. It is
**zero-cost when off**: a production `SimulationFSM` built without a debugging
policy compiles those hooks to `return nothing`, draws no extra randomness, and
produces a byte-identical trajectory. And it produces **plain-text, bounded
readouts** — a diagnostic is something you read, greppable and length-capped, not
a debugger you drive. Turn a tool on to investigate; leave it off to ship.

## Which technique for which symptom

| Reach for this when… | Technique | Guide |
|---|---|---|
| You have an observed trajectory and want its likelihood, or to check it is even a legal path of your model | **Trace evaluation** | [Evaluating a trace against a model](@ref "Evaluating a trace against a model") |
| You want to stop a recorded run just before any step and inspect the exact state it had there — time-travel debugging | **Record & replay** | [Recording and replaying a run](@ref "Recording and replaying a run") |
| You feed recorded trajectories to a likelihood or derivative estimator and want proof the record replays to the identical log-likelihood | **Minimal records & the effect check** | [Records, replay, and the effect check](@ref "Records, replay, and the effect check") |
| You changed a precondition or generator and want a loud error if the declared read-set no longer covers what the code reads | **Read verification** | [The three G1 verification tiers](@ref "The three G1 verification tiers") |
| You suspect the *state* went bad long before anything crashed, and want a throw at the exact breaking event | **Invariants** | [Declaring and checking invariants](@ref "Declaring and checking invariants") |
| A run finished but looks wrong: an event never fired, the run won't stop, or an invariant broke | **Why-verbs** | [Debugging a simulation](@ref "Debugging a simulation") |
| You want each event to declare what it writes, and a runtime check that it wrote nothing else | **Effect analysis** | [Static effect analysis (`@fire`)](@ref "Static effect analysis (`@fire`)") |
| You want to catch a missed-trigger or interference bug statically, before any run | **Footprint lints** | [Linting a model's footprints](@ref "Linting a model's footprints") |
| You want to prove an invariant holds over *every* reachable state, or check a run against a formal spec | **Model checking** | [Model checking a simulation](@ref "Model checking a simulation") |

The [Runbook](@ref) is the mechanical companion to these guides: one terse entry
per feature — exact invocation, captured output, every failure form, and how to
turn it off — written to be followed with no context beyond this repository.

## How they fit together

The techniques share artifacts, so investigating with one hands the next its
input. A [`RecordSkeleton`](@ref) run produces the skeleton that the why-verbs,
[`replay`](@ref), and trace validation all read; composing that recorder under
[`CheckInvariants`](@ref) makes a violation carry a `replay` command; the same
`@precondition` and `@fire` annotations that drive [effect
analysis](@ref "Static effect analysis (`@fire`)") and the
[lints](@ref "Linting a model's footprints") are what
[compile to a model-checkable spec](@ref "Model checking a simulation"). Record
once, and every offline diagnostic runs on the same replayable artifact.
