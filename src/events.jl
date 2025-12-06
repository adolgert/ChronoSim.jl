using Logging

export SimEvent, InitializeEvent, isimmediate, clock_key, key_clock
export precondition, enable, reenable, fire!

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

Given that `precondition(event, physical)` is `true`, this determines the
probability distribution for when the event might fire, starting from time `when`.
We consider the returned tuple (probability distribution, offset time) a rate for the event.
When `enable` is called, the framework tracks the specific physical addresses
that were read in order to compute the rate.
"""
function enable(tn::SimEvent, physical, when) end

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
the distribution, forward to `enable`:

```julia
reenable(e::MyEvent, phys, _, t) = enable(e, phys, t)
```
"""
function reenable(tn::SimEvent, physical, firstenabled, curtime) end

"""
    fire!(event, physical, when, rng::AbstractRNG)

When an event fires, it modifies state with this function. If you sample using
the random number generator, that affects the likelihood of the outcome.
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
