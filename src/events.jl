using Logging
import CompetingClocks: fire!

export SimEvent, InitializeEvent, isimmediate, clock_key, key_clock
export precondition, enable, reenable, fire!
export reevaluation_coupling, memory_policy

"""
  SimEvent

This abstract type is the parent of all transitions in the system.
"""
abstract type SimEvent end

"""
    precondition(event, physical_state)

This determines whether an event should be in the enabled state given the current
physical state. When this method is called, the framework tracks the specific
addresses of the physical state that were read in order to determine whether
this event should be enabled.
"""
function precondition(it::SimEvent, physical) end


"""
    enable(event, physical, when)
    enable(event, physical, θ, when)

Given that `precondition(event, physical)` is `true`, this determines the
probability distribution for when the event might fire, starting from time `when`.
We consider the returned tuple (probability distribution, offset time) a rate for the event.
When `enable` is called, the framework tracks the specific physical addresses
that were read in order to compute the rate.

# The θ (parameter) seam

The engine calls the **four-argument** form, passing the simulation's parameter
vector `θ` (the `params` field of [`SimulationFSM`](@ref), an `AbstractVector`)
between `physical` and `when`. This is the `clock_distribution` seam in callback
form (design guarantee G4): θ is an explicit argument, so an estimator can
re-evaluate the seam at a θ the forward run never saw — including a dual-valued θ
for `ForwardDiff` — without re-instantiating global state. Enabling stays θ-free
in the sense of guarantee G1: θ carries only the *parameters* of the distribution,
never physical state.

New models should define the four-argument form and read their rate parameters
from `θ`:

```julia
enable(::MyEvent, physical, θ, when) = (Exponential(inv(θ[1])), when)
```

**Backward compatibility.** The default four-argument method forwards to the
three-argument method, so every model written against the old θ-free signature
runs unchanged; `θ` is simply ignored. Only override the four-argument form when
the event actually reads a parameter.
"""
function enable(tn::SimEvent, physical, when) end

# The engine calls this four-argument form (framework.jl `sim_event_enable`),
# always passing `sim.params`. The default drops θ and forwards to the θ-free
# method, which is why every pre-seam model keeps working bit-for-bit: an event
# that never defined the four-argument form gets exactly its old distribution.
enable(event::SimEvent, physical, θ, when) = enable(event, physical, when)

"""
    reenable(event, physical, first_enabled, when)

Called for events that were enabled before a state change and remain enabled after.
The framework has already verified the precondition still passes. This function
determines whether the event's distribution needs to be updated in the sampler.

Three conditions determine whether to call `reenable`:

 * Invariant - A place read by `precondition` was modified by `fire!`.
 * Addresses - The `precondition` now reads different places than before (relative event).
 * Rate - A place read by `enable` was modified by `fire!`.

| Invariant | Addresses | Rate | reenable? | Reason |
|-----------|-----------|------|-----------|--------|
| ✅ | ❌ | ❌ | ❌ | Same places, precondition still holds, rate unaffected |
| ✅ | ❌ | ✅ | ✅ | Same places, precondition still holds, rate unaffected |
| ✅ | ✅ | — | ✅ | Relative event: dependencies shifted to new places |
| ❌ | ❌ | ✅ | ✅ | Rate dependencies changed |
| ❌ | ❌ | ❌ | ❌ | Nothing relevant changed |

Key: ✅ = changed, ❌ = unchanged, — = doesn't matter

The default implementation returns `nothing` (no update needed). To update
the distribution, forward to `enable` for the distribution and return the
ORIGINAL enabling time, so the clock keeps its age:

```julia
reenable(e::MyEvent, phys, firstenabled, t) = (first(enable(e, phys, t)), firstenabled)
```

Returning the current time `t` instead of `firstenabled` re-anchors the clock —
its age restarts at the state change — which also breaks the `:carry`
re-evaluation coupling's no-op property (see [`reevaluation_coupling`](@ref)):
even a carried draw shifts when its origin moves.

# The θ (parameter) seam

Like [`enable`](@ref), the engine calls the **five-argument** form
`reenable(event, physical, θ, firstenabled, when)`, threading the simulation's
parameter vector `θ` between `physical` and `firstenabled`. A model that reads
parameters should forward to the four-argument `enable`, again returning
`firstenabled` to keep the clock's age:

```julia
reenable(e::MyEvent, phys, θ, firstenabled, t) = (first(enable(e, phys, θ, t)), firstenabled)
```

**Backward compatibility.** The default five-argument method forwards to the
four-argument method, so pre-seam models are unaffected.
"""
function reenable(tn::SimEvent, physical, firstenabled, curtime) end

# The engine calls this five-argument form (framework.jl `sim_event_reenable`),
# always passing `sim.params`. The default drops θ and forwards to the θ-free
# method, preserving every pre-seam model exactly.
reenable(event::SimEvent, physical, θ, firstenabled, curtime) =
    reenable(event, physical, firstenabled, curtime)

"""
    fire!(event, physical, when, rng::AbstractRNG)

When an event fires, it modifies state with this function. If you draw random
numbers, use the `rng` argument — never a global generator: the framework hands
each event its own seeded stream (keyed by `clock_key(event)`), so the draws
reproduce from the simulation's master seed. Note that draws made inside `fire!`
are NOT part of the trajectory's path likelihood; the framework detects them
(see [`CountingRNG`](@ref)) and flags the run as fire-random so record-derived
estimators can warn. A choice whose probability depends on model parameters
should be modeled as competing events rather than drawn here.
"""
function fire!(it::SimEvent, physical, when, rng) end

"""
InitializeEvent is a concrete transition type that represents the first event
in the system, initialization.
"""
struct InitializeEvent <: SimEvent end

"""
    isimmediate(EventType)

An immediate event should return true for this function.
"""
isimmediate(::Type{<:SimEvent}) = false

"""
    reevaluation_coupling(EventType)::Symbol

Declare, on the event TYPE, which pathwise coupling the engine must use when this
event is still enabled and its rate dependencies change so that `reenable`
supplies a fresh distribution. Guarantee G6 (per-event coupling declaration).

Two values are defined:

  * `:redraw` (the DEFAULT) — the sampler discards the clock's in-flight draw and
    draws the remaining lifetime fresh at the current age. This is correct for
    likelihood work but is NOT differentiable in a distribution parameter: an
    infinitesimal change of the rate produces a discontinuous jump in the firing
    time, because a brand-new uniform is consumed. (Note the default is NOT the
    old backend behavior: historically `CombinedNextReaction` silently carried a
    re-enabled key's draw. No shipped model observed the difference, but a model
    newly opting into rate re-evaluation gets `:redraw` unless it declares
    otherwise.)

  * `:carry` — the sampler maps the clock's retained draw through the distribution
    change by matching conditional survival, consuming NO fresh randomness. This is
    the ONLY re-evaluation coupling that is IPA-safe: it is the one coupling under
    which a firing time moves *continuously* in a distribution parameter, which is
    exactly what infinitesimal perturbation analysis (pathwise) derivatives need.
    For an unchanged distribution `:carry` leaves the schedule bit-for-bit intact.

Not every sampler can carry a mid-flight draw. `:carry` requires a backend whose
`CompetingClocks.supports_carry` trait is `true` (`CombinedNextReaction`, the
default `NextReactionMethod` backend, and `FirstToFire` qualify); declaring
`:carry` against a sampler that cannot carry raises a descriptive error at the
re-evaluation call site.
"""
reevaluation_coupling(::Type{<:SimEvent}) = :redraw
reevaluation_coupling(event::SimEvent) = reevaluation_coupling(typeof(event))

"""
    memory_policy(EventType)::Symbol

Declare, on the event TYPE, what happens to a clock's accumulated age when the
event is DISABLED and later RE-ENABLED (a preempt/resume cycle). Guarantee G6
(per-event memory declaration).

Two values are defined:

  * `:fresh` (the DEFAULT and the historical behavior) — a re-enabled clock starts
    over from age zero. The work done before the disable is forgotten; the new draw
    measures from the moment of re-enabling. This is renewal-on-disable semantics.

  * `:resume` — the enabled age the clock accumulated before it was disabled is
    BANKED across the disable, and the re-enabling draw is CONDITIONED on survival
    past that banked age. The engine implements this by left-shifting the enabling
    time it hands the sampler (`te_used = te_model − banked_age`), so a
    memory-carrying sampler draws the remaining lifetime conditioned on the age the
    clock already has. Banking accumulates across repeated preempt/resume cycles, so
    the total service requirement is preserved. Firing consumes the draw and clears
    the bank.

`:resume` needs a sampler that carries a lifetime distribution with memory (any
`supports_enabled_ages` backend); the memoryless exponential-only samplers make
`:resume` indistinguishable from `:fresh`, so a non-exponential clock (e.g.
Weibull, Gamma) is what makes the two policies observably different.
"""
memory_policy(::Type{<:SimEvent}) = :fresh
memory_policy(event::SimEvent) = memory_policy(typeof(event))

"""
    clock_key(::SimEvent)::Tuple

All `SimEvent` objects are immutable structs that represent events but
don't carry any mutable state. A clock key is a tuple version of an event.
"""
@generated function clock_key(event::T) where {T<:SimEvent}
    type_symbol = QuoteNode(nameof(T))
    field_exprs = [:(event.$field) for field in fieldnames(T)]
    return :($type_symbol, $(field_exprs...))
end

"""
    key_clock(key::Tuple, event_dict::Dict{Symbol, DataType})::SimEvent

Takes a tuple of the form (:symbol, arg, arg) and a dictionary mapping symbols
to struct types, and returns an instantiation of the struct named by :symbol.
We pass in the list of datatypes because, if we didn't, then instantiation
of a type from a symbol would need to search for the correct constructor
in the correct module, and that would be both wrong and slow.
"""
function key_clock(key::Tuple, event_dict::Dict{Symbol,DataType})
    if !isa(key[1], Symbol)
        error("First element of tuple must be a Symbol")
    end

    type_symbol = key[1]
    if !haskey(event_dict, type_symbol)
        error("Type $type_symbol not found in event dictionary")
    end

    struct_type = event_dict[type_symbol]
    field_args = key[2:end]
    return struct_type(field_args...)
end
