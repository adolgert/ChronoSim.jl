# Phase OB-3b (design doc Section 6): the event ENTRY. Three levels share the
# word "event": the event TYPE is code (the struct and its precondition/enable/
# fire! methods); an event FAMILY is one inclusion of that code in one model,
# together with its per-model declarations (memory policy, parameter binding);
# an event INSTANCE is one clock. ChronoSim historically identified the first
# two levels -- the model's event list held types and every declaration was a
# trait method on the type. The entry is the family value: the model's event
# list carries entries, and a bare type normalizes to the all-defaults entry.
#
# The design doc writes the entry constructor as `include(Break; ...)`, but
# `include` is Base's file-include and shadowing it inside every user module is
# unacceptable, so the exported constructor is [`entry`](@ref).
#
# NOT in this phase, by design: the `config` slot (per-family configuration
# constants; plan gate G-D -- no argument reaches `enable` for it yet, so
# configuration stays in untracked state fields) and majorant declarations.

export EventEntry, entry, param_names, event_type

"""
    param_names(::Type{<:SimEvent}) -> NTuple{K,Symbol}

The event type's FORMAL parameter names, declared as a trait by the event's
author -- the vocabulary the event's own `enable` code reads its parameters in:

```julia
param_names(::Type{Break}) = (:shape, :scale)
enable(evt::Break, physical, p, when) = (Weibull(p.shape, p.scale), when)
```

The default is `()`: the event declares no formals, opts into no binding, and
its four-argument `enable` receives the simulation's WHOLE parameter vector
unchanged, exactly as before entries existed.

Formals are the event code's own names; the model's global θ has ACTUAL names
(the `param_names=` keyword of [`SimulationFSM`](@ref)). An [`entry`](@ref)
binds formals to actuals; when the names coincide the binding is the identity
and a bare `entry(Break)` (or the bare type in the event list) suffices. This
is the same layering as [`memory_policy`](@ref): a library-level default
declared by dispatch on the type, overridable per model by data in the entry.
"""
param_names(::Type{<:SimEvent}) = ()
param_names(event::SimEvent) = param_names(typeof(event))

"""
    EventEntry{E<:SimEvent,P}

One event FAMILY: the inclusion of event type `E` in one model, with that
model's declarations. Built by [`entry`](@ref); a bare type in a
[`SimulationFSM`](@ref) event list normalizes to `entry(E)`, the all-defaults
family. Fields:

  * `memory::Union{Nothing,Symbol}` -- per-model override of the
    [`memory_policy`](@ref) trait (`:fresh`/`:resume`); `nothing` (the default)
    defers to the trait.
  * `params::P` -- the parameter binding, a `NamedTuple` mapping the type's
    FORMAL names (the [`param_names`](@ref) trait) to the model's global ACTUAL
    names, or `nothing` for the identity binding (each formal binds the global
    name that equals it).
"""
struct EventEntry{E<:SimEvent,P<:Union{Nothing,NamedTuple}}
    memory::Union{Nothing,Symbol}
    params::P
end

"""
    entry(E::Type{<:SimEvent}; memory=nothing, params=nothing) -> EventEntry

Declare one event FAMILY: the inclusion of event type `E` in one model,
together with this model's per-family choices. Pass entries (mixed freely with
bare types) as the event list of [`SimulationFSM`](@ref):

```julia
sim = SimulationFSM(shop,
    (entry(Break; params=(shape=:fail_shape, scale=:fail_scale)),
     entry(Repair; memory=:resume),
     Inspect);                      # a bare type is the all-defaults entry
    param_names=(:fail_shape, :fail_scale, :repair_rate), ...)
```

  * `memory` overrides the type's [`memory_policy`](@ref) trait for this model
    (`:fresh` or `:resume`); when omitted the trait applies. Defaults by
    dispatch, overrides by data.
  * `params` binds the type's FORMAL parameter names (the [`param_names`](@ref)
    trait) to the model's global ACTUAL θ-component names, as
    `(formal=:actual, ...)`. Formals omitted from `params` bind the global name
    equal to the formal; `params=nothing` is the all-identity binding. A family
    whose type declares no formals takes no binding and receives the whole θ
    vector unchanged (see [`param_names`](@ref)).

At model construction the binding resolves against the global name list into
integer indices, and at enabling time the event's `enable`/`reenable` receives
a `NamedTuple` view of exactly the bound components through the θ seam argument
-- see the manual page "Parameters and differentiation".

(This is the constructor the design document calls `include(Break; ...)`;
`include` is taken by `Base`.)
"""
function entry(::Type{E}; memory=nothing, params=nothing) where {E<:SimEvent}
    if !(memory === nothing || memory === :fresh || memory === :resume)
        throw(ArgumentError(
            "entry($E; memory=$(repr(memory))): memory must be :fresh, :resume, " *
            "or nothing (defer to the memory_policy trait)"))
    end
    if params !== nothing
        params isa NamedTuple || throw(ArgumentError(
            "entry($E; params=...): params must be a NamedTuple mapping formal " *
            "names to global actual names, e.g. (shape=:fail_shape,)"))
        all(v -> v isa Symbol, values(params)) || throw(ArgumentError(
            "entry($E; params=$params): every value must be a Symbol naming a " *
            "global θ component"))
        formals = param_names(E)
        isempty(formals) && throw(ArgumentError(
            "entry($E; params=$params): $E declares no formal parameter names, " *
            "so there is nothing to bind. Declare them with " *
            "`ChronoSim.param_names(::Type{$E}) = (:name1, ...)`."))
        for k in keys(params)
            k in formals || throw(ArgumentError(
                "entry($E; params=$params): $(repr(k)) is not a formal parameter " *
                "name of $E; its formals are $(formals)"))
        end
    end
    return EventEntry{E,typeof(params)}(memory, params)
end

"""
    event_type(x) -> Type{<:SimEvent}

The event TYPE of an [`EventEntry`](@ref) (its family's code), or the type
itself when given a bare `Type{<:SimEvent}` -- the identity that lets event
lists mix entries and bare types.
"""
event_type(::EventEntry{E}) where {E} = E
event_type(::Type{E}) where {E<:SimEvent} = E

# A bare type in the event list is the degenerate all-defaults family.
_normalize_entry(::Type{E}) where {E<:SimEvent} = entry(E)
_normalize_entry(e::EventEntry) = e
_normalize_entry(x) = throw(ArgumentError(
    "event list elements must be SimEvent subtypes or EventEntry values " *
    "(from `entry`); got $(repr(x)) of type $(typeof(x))"))

"""
    resolve_binding(formals, binding, global_names) -> NTuple{K,Int}

Resolve one family's parameter binding against the model's global parameter
names, once, at model construction: for each FORMAL name (in the order the
[`param_names`](@ref) trait declares), the integer position in `global_names`
of the ACTUAL name it binds. `binding` is the entry's `params` NamedTuple
(formal => actual) or `nothing`; a formal absent from the binding is the
identity -- it binds the global name equal to itself. Throws an
`ArgumentError` naming the offending formal when an actual name is not among
`global_names`.

The result is plain bits (`NTuple{K,Int}`); the symbols are wiring that exists
only here. [`ResolvedBinding`](@ref) carries it, and `param_view` gathers
those components of θ into the named view at enabling time.

Block bindings -- one formal binding a CONTIGUOUS RANGE of θ components, its
view field a small vector view (the design doc's "fifteen per-machine failure
rates" case) -- are DELIBERATELY DEFERRED from this phase; every formal binds
exactly one scalar component.
"""
function resolve_binding(
    formals::NTuple{K,Symbol},
    binding::Union{Nothing,NamedTuple},
    global_names::NTuple{N,Symbol},
) where {K,N}
    return ntuple(Val(K)) do i
        formal = formals[i]
        actual = binding === nothing ? formal : get(binding, formal, formal)
        j = findfirst(==(actual), global_names)
        j === nothing && throw(ArgumentError(
            "parameter binding: actual name $(repr(actual)) (bound to formal " *
            "$(repr(formal))) is not among the simulation's global parameter " *
            "names $(global_names)"))
        j
    end
end

"""
    ResolvedBinding{names,K}

A family's parameter binding after resolution: the formal names as a type
parameter (so view construction is compile-time) and the bound θ positions as
plain bits. `param_view(b, θ)` gathers `θ[b.idx[i]]` into
`NamedTuple{names}`, which is concrete PER ELTYPE OF θ -- a dual-valued θ
yields a dual-valued view, which is what keeps ForwardDiff flowing through the
seam.
"""
struct ResolvedBinding{names,K}
    idx::NTuple{K,Int}
end
ResolvedBinding(names::NTuple{K,Symbol}, idx::NTuple{K,Int}) where {K} =
    ResolvedBinding{names,K}(idx)

"""
    param_view(binding, θ)

What flows through the θ seam's third argument for one family. With a
[`ResolvedBinding`](@ref), a `NamedTuple` view of EXACTLY the components the
family's binding names: `p.shape` is a compile-time field load, constructing
the view allocates nothing, and the eltype follows `eltype(θ)` (dual θ, dual
view). The event receives ONLY what it declared, so reading an unbound name is
an immediate field error at the call -- the declaration enforces itself,
structurally, rather than producing a silently biased gradient sparsity.
Integer indexing works too, but under a binding `p[1]` means "my FIRST
FORMAL", not "the model's first θ component".

With `binding === nothing` (a family with no declared formals), the whole θ
vector passes through unchanged -- the very same object -- which is how every
pre-entry model keeps running bit-for-bit.
"""
param_view(b::ResolvedBinding{names,K}, θ) where {names,K} =
    NamedTuple{names}(ntuple(i -> @inbounds(θ[b.idx[i]]), Val(K)))
param_view(::Nothing, θ) = θ

"""
    ResolvedEntry

One family's entry after model-construction resolution, as the engine consults
it: the EFFECTIVE memory policy (the entry's override when present, else the
type's [`memory_policy`](@ref) trait) and the resolved parameter binding
(`nothing` for whole-θ passthrough, else a [`ResolvedBinding`](@ref)). The
`binding` field's type varies per family (the formal names are type
parameters), so it is deliberately loosely typed here; the enabling call site
is already dynamic over the abstract event, so this adds no new instability.
"""
struct ResolvedEntry
    memory::Symbol
    binding::Union{Nothing,ResolvedBinding}
end

# The global-name list arrives as a tuple or vector of Symbols; `nothing` means
# the simulation declares no global names (only passthrough families allowed).
_normalize_global_names(::Nothing) = nothing
function _normalize_global_names(names)
    tup = Tuple(names)
    (tup isa Tuple{Vararg{Symbol}} && !isempty(tup)) || throw(ArgumentError(
        "param_names must be a nonempty tuple or vector of Symbols; got $(repr(names))"))
    allunique(tup) || throw(ArgumentError(
        "param_names must be unique; got $(tup)"))
    return tup
end

"""
    resolve_entries(entries, global_names) -> Dict{DataType,ResolvedEntry}

Resolve a normalized event-entry list against the model's global parameter
names (an `NTuple{N,Symbol}`, or `nothing` when the simulation declares none):
per family, the effective memory policy and the resolved binding, keyed by the
event type. This is the free-standing piece a model value assembles on top of
(phase OB-3c); [`SimulationFSM`](@ref) calls it at construction.

Throws when the same event type appears twice -- v1 does not support
same-type-twice families, because the instance `Break(3)` could not say which
family it belongs to; give each inclusion its own parametric type instead
(`Break{:lineA}`, `Break{:lineB}`). Throws when a family needs binding
resolution (nonempty [`param_names`](@ref) formals) but `global_names` is
`nothing`.
"""
function resolve_entries(entries, global_names::Union{Nothing,NTuple{N,Symbol} where N})
    resolved = Dict{DataType,ResolvedEntry}()
    for ent in entries
        ent isa EventEntry || throw(ArgumentError(
            "resolve_entries expects EventEntry values (normalize bare types " *
            "with `entry` first); got $(repr(ent))"))
        E = event_type(ent)
        haskey(resolved, E) && throw(ArgumentError(
            "the event type $E appears twice in the event list. Two families of " *
            "one type are not supported: the instance $E(...) could not say " *
            "which family it belongs to. Give each inclusion its own parametric " *
            "type instead, e.g. `struct $(nameof(E)){line} <: SimEvent ... end` " *
            "with $(nameof(E)){:lineA} and $(nameof(E)){:lineB} as separate " *
            "event-list members."))
        formals = param_names(E)
        formals isa Tuple{Vararg{Symbol}} || throw(ArgumentError(
            "param_names($E) must return a tuple of Symbols; got $(repr(formals))"))
        mem = ent.memory === nothing ? memory_policy(E) : ent.memory
        binding = if isempty(formals)
            # No formals => no binding => whole-θ passthrough (the migration
            # rule: pre-entry models keep the exact vector they always got).
            nothing
        else
            global_names === nothing && throw(ArgumentError(
                "the event family $E declares a parameter binding " *
                "(param_names($E) = $(formals)) but the simulation has no " *
                "global parameter names; pass param_names=(:name1, :name2, ...) " *
                "to SimulationFSM."))
            ResolvedBinding(formals, resolve_binding(formals, ent.params, global_names))
        end
        resolved[E] = ResolvedEntry(mem, binding)
    end
    return resolved
end
