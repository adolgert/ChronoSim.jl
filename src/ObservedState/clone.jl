# ---------------------------------------------------------------------------
# clone.jl — an independent deep copy of an observed physical state, with the
# address protocol restored (World-clone protocol, guarantee G2).
#
# Why deepcopy is wrong here. Every `@keyedby` element carries an
# `_address::Address{Key}` whose `container` field is a BACK-POINTER to the
# observed container that holds it (obs_traits.jl). A naive `deepcopy` follows
# that back-pointer and drags the WHOLE original world into the copy graph —
# including the tracking buffers `obs_modified`/`obs_read` on the
# ObservedPhysical — and worse, whether it aliases or duplicates depends on
# traversal order, so a copied element may end up notifying the ORIGINAL's
# container: the clone would mutate the original through a shared hidden edge.
#
# The fix mirrors what the containers already do at insertion time. We copy the
# structure with elements duplicated (leaving each Address at its default,
# container == nothing), then run a SINGLE wiring pass that calls the SAME
# `update_index` maintenance the containers run in `setindex!`, rebinding every
# element's back-pointer to the COPIED container. No parallel address mechanism
# is invented; the wiring is the insertion-time maintenance replayed over the
# whole copied state.
#
# The tracking buffers live INSIDE the clone boundary and start fresh-empty: a
# capture window (`capture_state_changes`/`capture_state_reads`) opens and
# drains within a single `fire!`, and a clone is only ever taken BETWEEN
# firings, so a clone never inherits pending captures. Forcing them empty keeps
# the clone's read/write accounting its own.
# ---------------------------------------------------------------------------

import CompetingClocks: clone

export clone, verify_clone

# ----- structural deep copy (addresses left at their default) ---------------

# Whether a leaf value is safe to SHARE between the original and the clone
# because it cannot be mutated in place through the observed API. An isbits value
# has pure value semantics; a `String` or `Symbol` is content-immutable (Julia's
# `ismutable` reports `true` for a `String`, but its characters cannot change).
# Anything else is a live mutable object (a plain `Set` such as an elevator's
# `buttons_pressed`, a `Vector`, a `Dict`) that must be duplicated so a write to
# the clone cannot reach the original. clone and verify use the SAME predicate so
# their notions of "shared is fine" agree.
_share_safe(x) = isbits(x) || x isa AbstractString || x isa Symbol
_clone_value(x) = _share_safe(x) ? x : deepcopy(x)

# Config (`Param`) is read-only by contract, but we still duplicate a mutable
# payload so the clone is a fully independent world.
_clone_value(x::Param) = _share_safe(x) ? x : Param(deepcopy(x.value))

_clone_value(x::ObservedArray) = _clone_array(x)
_clone_value(x::ObservedDict) = _clone_dict(x)
_clone_value(x::ObservedSet) = _clone_set(x)
_clone_value(x::Addressed) = _clone_addressed(x)

function _clone_array(v::ObservedArray{T,N,Index}) where {T,N,Index}
    inner = getfield(v, :arr)
    new_inner = similar(inner)
    for i in eachindex(inner)
        # A slot may be undef on an array allocated with `undef` and only
        # partly filled; leave it undef in the copy, matching the container.
        isassigned(inner, i) && (new_inner[i] = _clone_value(inner[i]))
    end
    return ObservedArray{T,N,Index}(new_inner)
end

function _clone_dict(d::ObservedDict{K,V,Index}) where {K,V,Index}
    src = getfield(d, :dict)
    new_dict = Dict{K,V}()
    for (k, v) in src
        new_dict[k] = _clone_value(v)
    end
    return ObservedDict{K,V,Index}(new_dict)
end

# Set elements carry no address (ObservedSet is not a container of addressed
# things), so duplicating the element values is a complete copy.
function _clone_set(s::ObservedSet{T,Key}) where {T,Key}
    src = getfield(s, :set)
    return ObservedSet{T,Key}(Set{T}(_clone_value(x) for x in src))
end

# A `@keyedby` element's constructor takes its user fields in declaration order
# and installs a fresh, unbound Address; the wiring pass binds it afterward.
function _clone_addressed(el::A) where {A<:Addressed}
    args = Any[]
    for fn in fieldnames(A)
        fn === :_address && continue
        push!(args, _clone_value(getfield(el, fn)))
    end
    return A(args...)
end

# ----- wiring pass: rebind every back-pointer via update_index --------------

# Wire a container's OWN back-pointer to its owner, then descend. Called for
# each observed field of the physical state (and recursively for nested
# containers inside addressed elements).
function _wire_children!(v::ObservedArray{T,N,Index}) where {T,N,Index}
    structure_trait(T) isa CompoundTrait || return nothing
    inner = getfield(v, :arr)
    ci = N == 1 ? nothing : CartesianIndices(inner)
    for i in eachindex(inner)
        isassigned(inner, i) || continue
        el = inner[i]
        # 1-D uses the integer index as the place identity; N-D uses the
        # Cartesian tuple — exactly the keys `_getindex` hands `update_index`.
        idx = N == 1 ? i : Tuple(ci[i])
        update_index(el._address, v, idx)
        _wire_element!(el)
    end
    return nothing
end

function _wire_children!(d::ObservedDict{K,V,Index}) where {K,V,Index}
    structure_trait(V) isa CompoundTrait || return nothing
    for (k, val) in getfield(d, :dict)
        update_index(val._address, d, k)
        _wire_element!(val)
    end
    return nothing
end

_wire_children!(::ObservedSet) = nothing

# An addressed element may itself hold observed containers (e.g. a nested
# ObservedSet); bind each such child to this element and recurse.
function _wire_children!(el::A) where {A<:Addressed}
    for fn in fieldnames(A)
        fn === :_address && continue
        child = getfield(el, fn)
        if is_observed_container(child)
            update_index(child._address, el, Member(fn))
            _wire_children!(child)
        end
    end
    return nothing
end

# Dispatch for a compound element already bound to its slot/key: an addressed
# element has children to wire; an observed-container element (ObservedSet in an
# ObservedVector, or a nested array/dict) recurses; anything else is a leaf.
_wire_element!(el::Addressed) = _wire_children!(el)
_wire_element!(el::ObservedArray) = _wire_children!(el)
_wire_element!(el::ObservedDict) = _wire_children!(el)
_wire_element!(::ObservedSet) = nothing
_wire_element!(::Any) = nothing

function _wire!(physical::ObservedPhysical)
    for fn in fieldnames(typeof(physical))
        (fn === :obs_modified || fn === :obs_read) && continue
        v = getfield(physical, fn)
        if is_observed_container(v)
            update_index(v._address, physical, Member(fn))
            _wire_children!(v)
        end
    end
    return physical
end

# ----- the public clone -----------------------------------------------------

"""
    clone(physical::ObservedPhysical) -> ObservedPhysical

An independent deep copy of an observed physical state with the ObservedState
address protocol restored (guarantee G2). The copy shares no mutable object with
the original: containers and their addressed elements are duplicated, plain
mutable fields (e.g. a `Set` inside a `@keyedby` element) are deep-copied,
`isbits`/immutable values are shared by value, and `Param` payloads are
duplicated. Every element's `_address.container` back-pointer is rebound to the
COPIED container by replaying the containers' own insertion-time `update_index`
maintenance over the whole copied state, so the clone notifies ITS OWN
containers and never the original's. The clone's tracking buffers
(`obs_modified`, `obs_read`) start fresh-empty — a clone is only taken between
firings, so it inherits no pending captures.

Works for any `@observedphysical` type by fieldname reflection; nothing is
model-specific.
"""
function clone(physical::P) where {P<:ObservedPhysical}
    args = Any[]
    for fn in fieldnames(P)
        (fn === :obs_modified || fn === :obs_read) && continue
        push!(args, _clone_value(getfield(physical, fn)))
    end
    # The generated constructor installs fresh empty tracking buffers and wires
    # the TOP-LEVEL container back-pointers; `_wire!` then wires every nested
    # level (idempotently re-affirming the top level).
    newp = P(args...)
    _wire!(newp)
    return newp
end

# ---------------------------------------------------------------------------
# verify_clone — a two-part debug verifier. Returns (ok::Bool, diagnostics).
# ---------------------------------------------------------------------------

# Notify-free structural equality (uses getfield, never getproperty, so
# comparing does not itself push reads into the tracking buffers).
_value_equal(a, b) = a == b
_value_equal(a::Param, b::Param) = a.value == b.value
function _value_equal(a::ObservedArray, b::ObservedArray)
    ia = getfield(a, :arr); ib = getfield(b, :arr)
    size(ia) == size(ib) || return false
    for i in eachindex(ia)
        isassigned(ia, i) == isassigned(ib, i) || return false
        isassigned(ia, i) || continue
        _value_equal(ia[i], ib[i]) || return false
    end
    return true
end
function _value_equal(a::ObservedDict, b::ObservedDict)
    da = getfield(a, :dict); db = getfield(b, :dict)
    keys(da) == keys(db) || return false
    for k in keys(da)
        _value_equal(da[k], db[k]) || return false
    end
    return true
end
_value_equal(a::ObservedSet, b::ObservedSet) = getfield(a, :set) == getfield(b, :set)
function _value_equal(a::A, b::A) where {A<:Addressed}
    for fn in fieldnames(A)
        fn === :_address && continue
        _value_equal(getfield(a, fn), getfield(b, fn)) || return false
    end
    return true
end
_value_equal(::Addressed, ::Addressed) = false  # different concrete types

function _state_equal(a::ObservedPhysical, b::ObservedPhysical)
    typeof(a) === typeof(b) || return false
    for fn in fieldnames(typeof(a))
        (fn === :obs_modified || fn === :obs_read) && continue
        _value_equal(getfield(a, fn), getfield(b, fn)) || return false
    end
    return true
end

# Find the first mutable object shared (===) between original and clone, or
# nothing. A shared mutable object is the aliasing bug this protocol prevents.
_shared_val(a, b, path) =
    (_share_safe(a) || a !== b) ? nothing : path
_shared_val(::Param, ::Param, path) = nothing  # config; sharing is contractually fine
function _shared_val(a::ObservedArray, b::ObservedArray, path)
    a === b && return path
    getfield(a, :arr) === getfield(b, :arr) && return path * ".arr"
    ia = getfield(a, :arr); ib = getfield(b, :arr)
    for i in eachindex(ia)
        isassigned(ia, i) || continue
        r = _shared_val(ia[i], ib[i], "$path[$i]"); r !== nothing && return r
    end
    return nothing
end
function _shared_val(a::ObservedDict, b::ObservedDict, path)
    a === b && return path
    getfield(a, :dict) === getfield(b, :dict) && return path * ".dict"
    da = getfield(a, :dict); db = getfield(b, :dict)
    for k in keys(da)
        r = _shared_val(da[k], db[k], "$path[$k]"); r !== nothing && return r
    end
    return nothing
end
function _shared_val(a::ObservedSet, b::ObservedSet, path)
    a === b && return path
    getfield(a, :set) === getfield(b, :set) && return path * ".set"
    return nothing
end
function _shared_val(a::A, b::A, path) where {A<:Addressed}
    a === b && return path
    for fn in fieldnames(A)
        fn === :_address && continue
        r = _shared_val(getfield(a, fn), getfield(b, fn), "$path.$fn")
        r !== nothing && return r
    end
    return nothing
end

function _find_shared_mutable(a::ObservedPhysical, b::ObservedPhysical)
    for fn in fieldnames(typeof(a))
        (fn === :obs_modified || fn === :obs_read) && continue
        r = _shared_val(getfield(a, fn), getfield(b, fn), string(fn))
        r !== nothing && return r
    end
    return nothing
end

# A leaf is a scalar site with raw (no-notify) get/set and a tracked set that
# goes through the observed API so it notifies.
struct _CloneLeaf
    rawget::Function
    rawset::Function
    trackedset::Function
end

function _container_leaves!(leaves, v::ObservedArray)
    inner = getfield(v, :arr)
    compound = structure_trait(eltype(v)) isa CompoundTrait
    for i in eachindex(inner)
        isassigned(inner, i) || continue
        if compound
            _element_leaves!(leaves, inner[i])
        else
            let vv = v, ii = i
                push!(leaves, _CloneLeaf(
                    () -> getfield(vv, :arr)[ii],
                    x -> (getfield(vv, :arr)[ii] = x; nothing),
                    x -> (vv[ii] = x; nothing)))
            end
        end
    end
    return nothing
end

function _container_leaves!(leaves, v::ObservedDict)
    d = getfield(v, :dict)
    compound = structure_trait(valtype(v)) isa CompoundTrait
    for k in sort!(collect(keys(d)); by=repr)
        if compound
            _element_leaves!(leaves, d[k])
        else
            let vv = v, kk = k
                push!(leaves, _CloneLeaf(
                    () -> getfield(vv, :dict)[kk],
                    x -> (getfield(vv, :dict)[kk] = x; nothing),
                    x -> (vv[kk] = x; nothing)))
            end
        end
    end
    return nothing
end

_element_leaves!(leaves, ::ObservedSet) = nothing
_element_leaves!(leaves, el::ObservedArray) = _container_leaves!(leaves, el)
_element_leaves!(leaves, el::ObservedDict) = _container_leaves!(leaves, el)
function _element_leaves!(leaves, el::A) where {A<:Addressed}
    for fn in fieldnames(A)
        fn === :_address && continue
        child = getfield(el, fn)
        if child isa ObservedArray || child isa ObservedDict
            _container_leaves!(leaves, child)
        elseif child isa ObservedSet
            # no scalar leaves inside a set
        elseif child isa Addressed
            _element_leaves!(leaves, child)
        else
            let e = el, f = fn
                push!(leaves, _CloneLeaf(
                    () -> getfield(e, f),
                    x -> (setfield!(e, f, x); nothing),
                    x -> (setproperty!(e, f, x); nothing)))
            end
        end
    end
    return nothing
end

function _collect_leaves(physical::ObservedPhysical)
    leaves = _CloneLeaf[]
    for fn in fieldnames(typeof(physical))
        (fn === :obs_modified || fn === :obs_read) && continue
        v = getfield(physical, fn)
        if v isa ObservedArray || v isa ObservedDict
            _container_leaves!(leaves, v)
        elseif v isa ObservedSet
            # no scalar leaves
        elseif v isa Addressed
            _element_leaves!(leaves, v)
        else
            let ph = physical, f = fn
                push!(leaves, _CloneLeaf(
                    () -> getfield(ph, f),
                    x -> (setfield!(ph, f, x); nothing),
                    x -> (setproperty!(ph, f, x); nothing)))
            end
        end
    end
    return leaves
end

# A value distinct from `x`, or `nothing` if we do not know how to perturb it.
_perturb(x::Bool) = !x
_perturb(x::Integer) = x + one(x)
_perturb(x::AbstractFloat) = x + one(x)
_perturb(x::String) = x * "*"
_perturb(x::Symbol) = Symbol(string(x), "_p")
_perturb(::Any) = nothing

"""
    verify_clone(original::ObservedPhysical, clone::ObservedPhysical) -> (ok::Bool, diagnostics::Vector{String})

Debug verifier for [`clone`](@ref). It returns a Bool and a list of diagnostics
(never throws) so a test can assert on it. Two properties are checked:

  1. **State equality without aliasing.** The two states hold equal values
     (structural equality), share no mutable object, and mutating a copied
     element through the clone leaves the original untouched — and vice versa
     (each probe is restored afterward).

  2. **Notify isolation.** A tracked write on the clone lands in the clone's own
     `obs_modified` buffer and NOT in the original's — proof that the copied
     elements notify the clone's containers, not the original's.

`verify_clone` operates on scratch of the live states: it perturbs and restores
in place and clears the tracking buffers it uses, leaving both states as it
found them.
"""
function verify_clone(original::ObservedPhysical, clone::ObservedPhysical)
    diags = String[]
    ok = true

    if !_state_equal(original, clone)
        ok = false
        push!(diags, "state values differ between original and clone")
    end

    shared = _find_shared_mutable(original, clone)
    if shared !== nothing
        ok = false
        push!(diags, "clone shares a mutable object with the original at `$shared`")
    end

    leaves_o = _collect_leaves(original)
    leaves_c = _collect_leaves(clone)
    if length(leaves_o) != length(leaves_c)
        ok = false
        push!(diags, "leaf count mismatch ($(length(leaves_o)) vs $(length(leaves_c)))")
    else
        idx = findfirst(l -> _perturb(l.rawget()) !== nothing, leaves_c)
        if idx === nothing
            push!(diags, "no perturbable scalar leaf found; mutation-isolation probe skipped")
        else
            lc = leaves_c[idx]; lo = leaves_o[idx]
            oldc = lc.rawget(); oldo = lo.rawget()
            # Mutate the clone; the original must not move.
            lc.rawset(_perturb(oldc))
            if lo.rawget() != oldo
                ok = false
                push!(diags, "mutating clone leaf $idx changed the original")
            end
            lc.rawset(oldc)
            # Mutate the original; the clone must not move.
            lo.rawset(_perturb(oldo))
            if lc.rawget() != oldc
                ok = false
                push!(diags, "mutating original leaf $idx changed the clone")
            end
            lo.rawset(oldo)
        end

        # Notify isolation: tracked write on the clone, watch both buffers.
        empty!(getfield(original, :obs_modified)); empty!(getfield(original, :obs_read))
        empty!(getfield(clone, :obs_modified)); empty!(getfield(clone, :obs_read))
        idx2 = findfirst(l -> _perturb(l.rawget()) !== nothing, leaves_c)
        if idx2 !== nothing
            lc = leaves_c[idx2]
            old = lc.rawget()
            lc.trackedset(_perturb(old))
            if !isempty(getfield(original, :obs_modified))
                ok = false
                push!(diags, "a tracked write on the clone notified the original's obs_modified")
            end
            if isempty(getfield(clone, :obs_modified))
                ok = false
                push!(diags, "a tracked write on the clone did NOT notify the clone's obs_modified")
            end
            lc.rawset(old)
            empty!(getfield(clone, :obs_modified)); empty!(getfield(clone, :obs_read))
            empty!(getfield(original, :obs_modified)); empty!(getfield(original, :obs_read))
        end
    end

    return (ok, diags)
end
