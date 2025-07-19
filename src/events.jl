using Logging

export SimEvent, InitializeEvent, isimmediate, clock_key, key_clock
export precondition, enable, reenable, fire!

"""
  SimEvent

This abstract type is the parent of all transitions in the system.
"""
abstract type SimEvent end

function precondition(it::SimEvent, physical) end
function enable(tn::SimEvent, physical, when) end
function reenable(tn::SimEvent, physical, firstenabled, curtime) end
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
@generated function clock_key(event::T) where T <: SimEvent
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
function key_clock(key::Tuple, event_dict::Dict{Symbol, DataType})
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
