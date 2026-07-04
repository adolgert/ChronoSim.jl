# Runtime diagnostics for derived generators: a soundness oracle and a cost metric.
#
# Both are opt-in and, when off, cost a single `Ref{Bool}` load on the hot path so
# a production run is byte-for-byte unaffected. They exist to turn two properties of
# the `@precondition`-derived generators into mechanically checkable assertions:
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
