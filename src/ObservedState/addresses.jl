# ---------------------------------------------------------------------------
# addresses.jl — enumerate every address tuple of an observed physical state.
#
# Phase OB-2 (design doc Section 8, "the initial law"). The declared-law
# initialization path installs a sampled time-zero state and must then tell the
# engine that EVERYTHING changed, so the standard generator reaction proposes
# the first events without any write-to-seed discipline from the user. "The set
# of everything" is this enumeration: exactly the address tuples that
# `observed_notify` would produce for a write at each site, because the
# generator matcher (`placekey_mask_index` -> `generators.byarray`) matches on
# those tuples. The traversal is modeled on clone.jl's `_collect_leaves` walk
# (sorted `eachindex` for arrays, dict keys sorted by `repr`, addressed-element
# Member fields, skipping `obs_modified`/`obs_read`), so the two walks agree on
# what a state's sites are.
# ---------------------------------------------------------------------------

export all_addresses

"""
    all_addresses(physical::ObservedPhysical) -> OrderedSet{Tuple}

Enumerate every address tuple of an observed physical state — the tuples that
`observed_notify` would report for a write at each site, in a deterministic
order (array indices in `eachindex` order, dictionary keys sorted by `repr`).
This is the "everything changed at time zero" set the declared initial-law
initialization hands to `deal_with_changes`, so the generators react to a
sampled initial state exactly as they would to an initializer that wrote every
address.

Contents are enumerated as they CURRENTLY are (the semantics of time zero):

  * a tracked scalar field of the physical or of a `@keyedby` element
    contributes its own tuple, e.g. `(Member(:machine), 3, Member(:status))`;
  * an `ObservedArray` of primitives contributes one tuple per slot (an `Int`
    index for 1-D, the Cartesian index tuple for N-D); unassigned slots are
    skipped;
  * an `ObservedDict` of primitives contributes one tuple per current key;
  * an `ObservedSet` carries no per-element addresses, so it contributes the
    single set-level address its writes notify with (matching change capture);
  * a `Param` field is configuration: it never notifies, so it contributes
    nothing.
"""
function all_addresses(physical::P) where {P<:ObservedPhysical}
    addrs = OrderedSet{Tuple}()
    for fn in fieldnames(P)
        (fn === :obs_modified || fn === :obs_read) && continue
        v = getfield(physical, fn)
        if v isa ObservedArray || v isa ObservedDict
            _addresses_container!(addrs, v, (Member(fn),))
        elseif v isa ObservedSet
            push!(addrs, (Member(fn),))
        elseif v isa Addressed
            _addresses_element!(addrs, v, (Member(fn),))
        else
            # A PrimitiveTrait field notifies `(Member(fn),)` on write; an
            # UnObservableTrait (`Param`) field never notifies at all.
            if structure_trait(fieldtype(P, fn)) isa PrimitiveTrait
                push!(addrs, (Member(fn),))
            end
        end
    end
    return addrs
end

function _addresses_container!(addrs, v::ObservedArray{T,N}, prefix) where {T,N}
    inner = getfield(v, :arr)
    compound = structure_trait(eltype(v)) isa CompoundTrait
    ci = N == 1 ? nothing : CartesianIndices(inner)
    for i in eachindex(inner)
        isassigned(inner, i) || continue
        # 1-D uses the integer index; N-D uses the Cartesian tuple — exactly
        # the keys the container's observed_notify reports.
        idx = N == 1 ? i : Tuple(ci[i])
        if compound
            _addresses_child!(addrs, inner[i], (prefix..., idx))
        else
            push!(addrs, (prefix..., idx))
        end
    end
    return nothing
end

function _addresses_container!(addrs, d::ObservedDict, prefix)
    src = getfield(d, :dict)
    compound = structure_trait(valtype(d)) isa CompoundTrait
    for k in sort!(collect(keys(src)); by=repr)
        if compound
            _addresses_child!(addrs, src[k], (prefix..., k))
        else
            push!(addrs, (prefix..., k))
        end
    end
    return nothing
end

_addresses_child!(addrs, el::Addressed, prefix) = _addresses_element!(addrs, el, prefix)
_addresses_child!(addrs, el::ObservedArray, prefix) = _addresses_container!(addrs, el, prefix)
_addresses_child!(addrs, el::ObservedDict, prefix) = _addresses_container!(addrs, el, prefix)
# A set has no per-element addresses; its writes notify at the set itself.
_addresses_child!(addrs, ::ObservedSet, prefix) = (push!(addrs, prefix); nothing)

function _addresses_element!(addrs, el::A, prefix) where {A<:Addressed}
    for fn in fieldnames(A)
        fn === :_address && continue
        child = getfield(el, fn)
        if is_observed_container(child)
            _addresses_child!(addrs, child, (prefix..., Member(fn)))
        else
            push!(addrs, (prefix..., Member(fn)))
        end
    end
    return nothing
end
