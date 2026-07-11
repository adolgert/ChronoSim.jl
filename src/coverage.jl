# Runtime diagnostics for derived generators: a soundness oracle and a cost metric.
#
# THE G1 THREE-TIER REGIME. The read-coverage oracle in this file is the middle
# tier of guarantee G1, which turns "the incrementalization keeps state and events
# consistent" into a defense in depth of three tiers over one interface:
#
#   1. DECLARATIONS (the production interface). A derived generator's
#      `derivation_spec` -- the set of place addresses it reacts to -- IS the
#      contract the engine prunes by: only a change to a declared address can
#      re-evaluate an event. This is what runs in production and it is fast.
#
#   2. DYNAMIC CAPTURE (this file, the audit tier). Under-declaration is silent:
#      if a precondition reads an address no trigger covers, a change there flips
#      the precondition without the generator ever proposing the event -- a missed
#      event with no error. The audit captures every precondition read AS IT HAPPENS
#      and asserts it is covered by the declaration, turning silent drift into a
#      LOUD per-evaluation `DerivationCoverageError` naming the event and the
#      uncovered place. Enable it with `enable_read_verification!` (or the scoped
#      `with_read_verification`) around a representative run in CI. It is the tier
#      that would have caught the 34-standard-error under-declaration bias at its
#      source, per-evaluation, instead of downstream in a statistic.
#
#   3. PURE REPLAY (the production check, `effect_check` in minimal_record.jl). For
#      a draw-free model, forward accumulation and trace replay share the same
#      enable path, so their log-likelihoods must match to the last bit. Any drift
#      is an incrementalization bug -- the exact-equality check that DID catch the
#      34-sigma bias downstream on 20/20 trajectories.
#
# The two functions below are opt-in and, when off, cost a single `Ref{Bool}` load
# on the hot path so a production run is byte-for-byte unaffected. They exist to
# turn two properties of the `@precondition`-derived generators into mechanically
# checkable assertions:
#
#   1. Coverage (soundness). A derived generator reacts only to the place addresses
#      named by its `derivation_spec`. If a precondition reads an address that no
#      spec trigger covers, a change to that address can flip the precondition
#      without the generator ever proposing the event -> a missed event. The oracle
#      catches this by comparing every captured precondition read against the spec.
#
#   2. Over-approximation (cost). Derived generators are deliberately a superset of
#      the hand-written ones: they propose candidates the precondition then filters.
#      The counters measure that superset so the price of derivation is quantified.

export check_derivation_coverage,
    enable_read_verification!, disable_read_verification!,
    read_verification_enabled, with_read_verification,
    collect_generation_stats, reset_generation_stats!, generation_stats

########################### Coverage self-check ###########################

const _CHECK_COVERAGE = Ref(false)

"""
    check_derivation_coverage(flag::Bool)
    check_derivation_coverage() -> Bool

Toggle the derivation-coverage oracle (default off). When on, each precondition
evaluation of an event type that has a `derivation_spec` verifies that every place
address the precondition read is covered by one of the derived triggers. An
uncovered read is a soundness bug in the derivation and throws
`DerivationCoverageError`. Events without a `derivation_spec` (hand-written
generators) are skipped.

Only precondition reads are checked. `enable`/`reenable` reads are rate
dependencies that legitimately touch state outside the precondition — and thus
outside `derivation_spec`, which is derived from the precondition body alone — so
checking them would false-positive on every model whose rate depends on state the
condition does not.
"""
check_derivation_coverage(flag::Bool) = (_CHECK_COVERAGE[]=flag; flag)
check_derivation_coverage() = _CHECK_COVERAGE[]

"""
    enable_read_verification!()
    disable_read_verification!()
    read_verification_enabled() -> Bool
    with_read_verification(f)

The first-class API for the DYNAMIC-CAPTURE audit tier of guarantee G1 (the second
of the three tiers described in this module's header). Read verification asserts,
at every precondition evaluation, that the DECLARATIONS a derived generator prunes
by (`derivation_spec`) cover every place address the precondition actually reads.
An uncovered read is silent under-declaration -- a change there could flip the
precondition without the generator proposing the event -- so verification turns it
into a LOUD `DerivationCoverageError` naming the event type and the uncovered place,
raised at the offending evaluation rather than downstream in a biased statistic.

The mode is a process-wide toggle (default OFF), not an [`ExecutionPolicy`](@ref):
the check point is inside `sim_event_precondition`, which holds the captured reads
and is not reached by any policy hook, so a `Ref`-backed toggle is the natural
seam. It costs a production run a single `Ref{Bool}` load when off. Turn it on
around a representative run in CI:

  * `enable_read_verification!()` / `disable_read_verification!()` — the explicit
    on/off pair.
  * `read_verification_enabled()` — the current state.
  * `with_read_verification(f)` — run `f()` with verification on and restore the
    previous state afterward, even on error. Prefer this in tests so the toggle
    never leaks.

```julia
with_read_verification() do
    ChronoSim.run(sim, init, stop)   # throws DerivationCoverageError on drift
end
```

This is a thin, documented layer over [`check_derivation_coverage`](@ref); the
underlying oracle (`verify_read_coverage`, `DerivationCoverageError`) is unchanged.
"""
enable_read_verification!() = (_CHECK_COVERAGE[] = true; nothing)
disable_read_verification!() = (_CHECK_COVERAGE[] = false; nothing)
read_verification_enabled() = _CHECK_COVERAGE[]

function with_read_verification(f::Function)
    prev = _CHECK_COVERAGE[]
    _CHECK_COVERAGE[] = true
    try
        return f()
    finally
        _CHECK_COVERAGE[] = prev
    end
end

"""
    DerivationCoverageError

A precondition read an address no derived trigger covers. `classification` is
`:missing_field` when the address's top-level container is named by no spec at all
(a plausible dead read or unobserved-parameter read — a future-allowlist candidate)
or `:shape_mismatch` when the same container is covered but at a different
leaf/index shape (a genuine index/classification miss in the derivation).
"""
struct DerivationCoverageError <: Exception
    event_type::Type
    address::Any
    classification::Symbol
    spec_masks::Vector{Any}
end

function Base.showerror(io::IO, e::DerivationCoverageError)
    kind = if e.classification === :missing_field
        "the address names a top-level field that NO derivation spec mentions " *
        "(a plausible dead read or unobserved-parameter read)"
    else
        "the same container is covered but at a different leaf/index shape " *
        "(a genuine index/classification miss)"
    end
    println(io, "DerivationCoverageError: event $(nameof(e.event_type)) read an ")
    println(io, "address not covered by any derived trigger.")
    println(io, "  read address: $(e.address)")
    println(io, "  masked to   : $(placekey_mask_index(e.address))")
    println(io, "  classified  : $(e.classification) — $(kind)")
    println(io, "  derived triggers (masked):")
    for m in e.spec_masks
        println(io, "    $(m)")
    end
    print(
        io,
        "This is a soundness bug in the derivation: a change to this address can " *
        "flip the precondition without the generator proposing the event.",
    )
end

_address_top(a) = a[1] isa Member ? a[1].name : Symbol(a[1])

"""
    verify_read_coverage(::Type{T}, reads)

Check every read address against `derivation_spec(T)`; throw on the first
uncovered read. A no-op for event types without a `derivation_spec`.
"""
function verify_read_coverage(::Type{T}, reads) where {T}
    hasmethod(derivation_spec, Tuple{Type{T}}) || return nothing
    specs = derivation_spec(T)
    spec_masks = Any[placekey_mask_index(s.matchstr) for s in specs]
    spec_top = Set{Symbol}(s.matchstr[1].name for s in specs if !isempty(s.matchstr))
    for a in reads
        m = placekey_mask_index(a)
        any(==(m), spec_masks) && continue
        classification = _address_top(a) in spec_top ? :shape_mismatch : :missing_field
        throw(DerivationCoverageError(T, a, classification, spec_masks))
    end
    return nothing
end

# Hot-path entry: the flag load is inlined at the call site; this runs only when on.
@inline function maybe_verify_coverage(event, reads)
    _CHECK_COVERAGE[] && verify_read_coverage(typeof(event), reads)
    return nothing
end

########################### Candidate counters ###########################

const _COLLECT_STATS = Ref(false)
const _PROPOSED = Dict{Symbol,Int}()
const _ADMITTED = Dict{Symbol,Int}()

"""
    collect_generation_stats(flag::Bool)
    collect_generation_stats() -> Bool

Toggle accumulation of per-event-type candidate counts (default off). See
`generation_stats`.
"""
collect_generation_stats(flag::Bool) = (_COLLECT_STATS[]=flag; flag)
collect_generation_stats() = _COLLECT_STATS[]

"""
    reset_generation_stats!()

Clear the accumulated `proposed`/`admitted` counters.
"""
reset_generation_stats!() = (empty!(_PROPOSED); empty!(_ADMITTED); nothing)

"""
    generation_stats() -> Dict{Symbol,@NamedTuple{proposed::Int, admitted::Int}}

Per-event-type-Symbol candidate counts since the last reset:

  * `proposed`  — candidates a generator yielded and that were newly added to the
    dedup (`seen`) set during invariant processing.
  * `admitted`  — candidates whose precondition evaluated true and that were newly
    enabled.

`admitted <= proposed` for derived events (the precondition filters the
over-approximation). Empty when collection is disabled.
"""
function generation_stats()
    types = union(keys(_PROPOSED), keys(_ADMITTED))
    return Dict(t => (proposed=get(_PROPOSED, t, 0), admitted=get(_ADMITTED, t, 0)) for t in types)
end

@inline function record_proposed(event)
    _COLLECT_STATS[] || return nothing
    s = nameof(typeof(event))
    _PROPOSED[s] = get(_PROPOSED, s, 0) + 1
    return nothing
end

@inline function record_admitted(event)
    _COLLECT_STATS[] || return nothing
    s = nameof(typeof(event))
    _ADMITTED[s] = get(_ADMITTED, s, 0) + 1
    return nothing
end
