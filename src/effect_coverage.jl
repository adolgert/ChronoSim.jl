# Runtime effect-conformance oracle for `@fire`-derived write specs.
#
# `CheckEffects` is an `ExecutionPolicy` that verifies, after initialization and
# after every fired event, that every captured changed address matches some
# `WriteSpec` mask of the fired event type (unioned with the specs of any
# `isimmediate` event types, since immediate-event writes are merged into the same
# `changed_places`). The direction is `changed ⊆ declared`: widening and may-write
# union only ADD spec coverage, so branches/loops never false-positive; the only
# throw is a genuinely undeclared write shape.
#
# It enters exclusively through the existing on_postfire/on_init hooks — zero
# framework.jl lines — and is opt-in and test-tier: it consumes no randomness and
# never mutates state, so a trajectory with it on equals one with it off.

export CheckEffects, EffectCoverageError

"""
    EffectCoverageError

A fired event changed an address that no `WriteSpec` of the fired (or immediate)
event types covers. `classification` is `:missing_container` when the address's
top-level field is named by no spec at all (an undeclared effect — the seeded-bug
class) or `:shape_mismatch` when the container is covered but at a different
leaf/index shape (a walker classification miss, or an observed-container-valued
field assignment). `immediate_types` names the `isimmediate` event types whose
specs were unioned into the check.
"""
struct EffectCoverageError <: Exception
    event_type::Type
    address::Any
    classification::Symbol
    spec_masks::Vector{Any}
    immediate_types::Vector{Symbol}
end

function Base.showerror(io::IO, e::EffectCoverageError)
    kind = if e.classification === :missing_container
        "no WriteSpec names this top-level field (an undeclared effect)"
    else
        "the container is declared but at a different leaf/index shape"
    end
    println(io, "EffectCoverageError: event $(nameof(e.event_type)) wrote an address not ")
    println(io, "covered by any WriteSpec.")
    println(io, "  changed address: $(e.address)")
    println(io, "  masked to      : $(placekey_mask_index(e.address))")
    println(io, "  classified     : $(e.classification) — $(kind)")
    if !isempty(e.immediate_types)
        println(io, "  (union also checked immediate events: $(join(e.immediate_types, ", ")))")
    end
    println(io, "  declared writes (masked):")
    for m in e.spec_masks
        println(io, "    $(m)")
    end
    print(
        io,
        "This event performed a write its @fire analysis did not declare — either the " *
        "write hides behind an opaque helper (register it with @fragment or use a " *
        "recognized mutation form) or the walker misclassified the address shape.",
    )
end

"""
    CheckEffects(events::AbstractVector) -> CheckEffects

An [`ExecutionPolicy`](@ref) that verifies, after initialization and after every
fired event, that every captured changed address matches some `WriteSpec` mask of
the fired event type (unioned with the specs of any `isimmediate` event types in
`events`, since immediate-event writes merge into the same `changed_places`). A
miss throws [`EffectCoverageError`](@ref); event types without an `effect_spec`
are skipped.

Test-tier and opt-in: pass `policy=CheckEffects(events)` to [`SimulationFSM`](@ref)
or compose it via `PolicyStack`. The policy is read-only and consumes no
randomness, so trajectories with it on equal trajectories with it off.
"""
struct CheckEffects <: ExecutionPolicy
    immediate_specs::Vector{Pair{Symbol,EffectSpec}}
end

CheckEffects(events::AbstractVector) = CheckEffects(
    Pair{Symbol,EffectSpec}[
        nameof(T) => effect_spec(T) for T in events
        if isimmediate(T) && hasmethod(effect_spec, Tuple{Type{T}})
    ],
)

function on_postfire(chk::CheckEffects, sim, clock_key_, event, when, changed_places)
    verify_write_coverage(typeof(event), changed_places, chk)
    return nothing
end

function on_init(chk::CheckEffects, sim, init_evt, changed_places)
    # Only when the init event itself is @fire'd (run(sim, evt, stop) form). A custom
    # init closure run under an event (3-arg run) would mis-attribute; examples use
    # the safe forms.
    hasmethod(effect_spec, Tuple{Type{typeof(init_evt)}}) || return nothing
    verify_write_coverage(typeof(init_evt), changed_places, chk)
    return nothing
end

# Exact for leaf specs; prefix for subtree specs. Components are Member/MEMBERINDEX.
_mask_covers(spec_mask, addr_mask, subtree::Bool) =
    subtree ?
    (length(addr_mask) >= length(spec_mask) &&
     all(spec_mask[i] == addr_mask[i] for i in eachindex(spec_mask))) :
    spec_mask == addr_mask

"""
    verify_write_coverage(::Type{T}, changed, chk::CheckEffects)

Check every changed address against `effect_spec(T)` (unioned with `chk`'s
immediate-event specs); throw [`EffectCoverageError`](@ref) on the first
uncovered write. A no-op for event types without an `effect_spec`.
"""
function verify_write_coverage(::Type{T}, changed, chk::CheckEffects) where {T}
    hasmethod(effect_spec, Tuple{Type{T}}) || return nothing
    pairs = Tuple{Any,Bool}[(write_mask(w), w.subtree) for w in effect_spec(T).writes]
    for (_, ispec) in chk.immediate_specs
        for w in ispec.writes
            push!(pairs, (write_mask(w), w.subtree))
        end
    end
    tops = Set{Symbol}(sm[1] isa Member ? sm[1].name : Symbol(sm[1]) for (sm, _) in pairs if !isempty(sm))
    for a in changed
        m = placekey_mask_index(a)
        any(((sm, deep),) -> _mask_covers(sm, m, deep), pairs) && continue
        cls = _address_top(a) in tops ? :shape_mismatch : :missing_container
        throw(EffectCoverageError(T, a, cls, Any[sm for (sm, _) in pairs],
            Symbol[k for (k, _) in chk.immediate_specs]))
    end
    return nothing
end
