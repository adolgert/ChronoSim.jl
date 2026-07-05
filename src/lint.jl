# Phase 3: footprint lints — interference, races, and missed triggers.
#
# `lint(events)` intersects every event's static WRITE masks (`@fire`, Phase 2)
# with every event's static GUARD-READ masks (`@precondition` or the new
# analysis-only `@guard`) and reports the write→guard interference graph. An edge
# that no trigger of the reader covers is a WARNING: a write can flip a guard
# whose event is never proposed (the historical doors_open / StopElevator bugs).
#
# Everything consumed here is a baked method (`effect_spec`, `derivation_spec`,
# `guard_spec`, `generators`) — no registry walking, no runtime `eval`, no
# precompilation hazard. The analysis is over-approximate: it sees address masks,
# not expression semantics (honest scope; see docs/src/lint_footprints.md).
#
# See .claude/design/phase3_design.md for the authoritative design.

export @guard, lint, LintReport

public masks_intersect, AddressPattern, GuardSpec, guard_spec, LintEdge, LintAllow,
    assert_lint_clean, LintFailure, LintHarvest, static_covers_dynamic, print_lint,
    warnings, DynamicCoverage

########################### AddressPattern — the one currency ###########################

"""
    AddressPattern

A masked address pattern: `mask` is the `placekey_mask_index` tuple of
`Member`/`MEMBERINDEX` components (generators.jl), `indices` holds one constraint
(`FieldBinding`/`LiteralIndex`/`TaintedIndex`/`TupleIndex`, derive.jl) per
`MEMBERINDEX` position in path order, and `subtree=true` means the pattern covers
this address and every descendant.
"""
struct AddressPattern
    mask::Tuple{Vararg{Member}}
    indices::Vector{Any}
    subtree::Bool
end

# Four constructors, all total (design D2).
AddressPattern(s::ReadSpec) = AddressPattern(placekey_mask_index(s.matchstr), s.indices, false)
AddressPattern(w::WriteSpec) = AddressPattern(write_mask(w), w.indices, w.subtree)

# whole-container guard read (from GuardSpec.whole_containers):
_whole_pattern(c::Member) = AddressPattern((c,), Any[], true)

# a ToPlace trigger (indices opaque inside the closure -> all wildcards):
function AddressPattern(g::EventGenerator)
    m = placekey_mask_index(g.matchstr)
    return AddressPattern(m, Any[TaintedIndex() for x in m if x === MEMBERINDEX], false)
end

# a CONCRETE runtime placekey (LintHarvest side): indices are literal values.
function AddressPattern(place::Tuple)
    m = placekey_mask_index(place)
    return AddressPattern(m, Any[LiteralIndex(v) for v in place if !(v isa Member)], false)
end

# A masked tuple with all-wildcard indices (used for trigger / edge coverage).
_mask_pattern(mask::Tuple) =
    AddressPattern(mask, Any[TaintedIndex() for x in mask if x === MEMBERINDEX], false)

########################### The kernel: _intersect_verdict ###########################

# _unify_index truth table (design K1–K12). Returns :overlap | :possible | :disjoint.
_unify_index(::TaintedIndex, ::TaintedIndex) = :overlap
_unify_index(::TaintedIndex, ::Any) = :overlap                     # K1 / K8
_unify_index(::Any, ::TaintedIndex) = :overlap                     # K1 / K8
_unify_index(a::LiteralIndex, b::LiteralIndex) = a.value == b.value ? :overlap : :disjoint  # K2/K3
_unify_index(::LiteralIndex, ::FieldBinding) = :possible           # K4
_unify_index(::FieldBinding, ::LiteralIndex) = :possible           # K4
_unify_index(::FieldBinding, ::FieldBinding) = :possible           # K5 / K12
_unify_index(::TupleIndex, ::FieldBinding) = :possible             # K11
_unify_index(::FieldBinding, ::TupleIndex) = :possible             # K11

function _fold_tuple(cs, ds)                                       # K6
    length(cs) == length(ds) || return :disjoint                  # K7
    verdict = :overlap
    for (c, d) in zip(cs, ds)
        v = _unify_index(c, d)
        v === :disjoint && return :disjoint
        v === :possible && (verdict = :possible)
    end
    return verdict
end
_unify_index(a::TupleIndex, b::TupleIndex) = _fold_tuple(a.components, b.components)

function _unify_index(a::TupleIndex, b::LiteralIndex)              # K9 / K10
    (b.value isa Tuple && length(b.value) == length(a.components)) || return :disjoint
    return _fold_tuple(a.components, Any[LiteralIndex(v) for v in b.value])
end
_unify_index(a::LiteralIndex, b::TupleIndex) = _unify_index(b, a)

# Pair the per-MEMBERINDEX index constraints of a and b over the shared prefix of
# length n. Robust to short/absent index vectors (masked concrete places).
function _paired_indices(a::AddressPattern, b::AddressPattern, n::Int)
    pairs = Tuple{Any,Any}[]
    ka = 0
    kb = 0
    for i in 1:n
        ami = a.mask[i] === MEMBERINDEX
        bmi = b.mask[i] === MEMBERINDEX
        if ami
            ka += 1
        end
        if bmi
            kb += 1
        end
        if ami && bmi
            ia = ka <= length(a.indices) ? a.indices[ka] : TaintedIndex()
            ib = kb <= length(b.indices) ? b.indices[kb] : TaintedIndex()
            push!(pairs, (ia, ib))
        end
    end
    return pairs
end

"""
    _intersect_verdict(a::AddressPattern, b::AddressPattern) -> Symbol

Three-valued interference kernel: `:overlap` (a concrete address matches both),
`:possible` (index constraints could be uninhabited — the enumeration pass
refines it), or `:disjoint` (provably no shared address). The sound direction:
never `:disjoint` unless provably so.
"""
function _intersect_verdict(a::AddressPattern, b::AddressPattern)::Symbol
    # 1. structural alignment of the Member masks
    local n::Int
    if a.subtree || b.subtree
        n = min(length(a.mask), length(b.mask))
        ((a.subtree && length(a.mask) <= length(b.mask)) ||
         (b.subtree && length(b.mask) <= length(a.mask))) || return :disjoint
    else
        length(a.mask) == length(b.mask) || return :disjoint
        n = length(a.mask)
    end
    for i in 1:n
        a.mask[i] == b.mask[i] || return :disjoint
    end
    # 2. per-MEMBERINDEX index unification over the shared prefix
    verdict = :overlap
    for (ia, ib) in _paired_indices(a, b, n)
        v = _unify_index(ia, ib)
        v === :disjoint && return :disjoint
        v === :possible && (verdict = :possible)
    end
    return verdict
end

"""
    masks_intersect(a::AddressPattern, b::AddressPattern) -> Bool

`true` unless the two masked address patterns are provably disjoint by
component-wise unification. `false` means no concrete address matches both — the
sound direction.
"""
masks_intersect(a::AddressPattern, b::AddressPattern) = _intersect_verdict(a, b) !== :disjoint

########################### GuardSpec + @guard ###########################

"""
    GuardSpec

The static guard-read specification baked by [`@guard`](@ref). `reads` are
`ReadSpec`s (the same IR as `derivation_spec`); `whole_containers` are `Member`s
read via `length`/`keys`/`values`/`pairs`/`isempty` without a covering element
read (recorded as container-level subtree reads); `notes` records e.g. a
zero-read guard.
"""
struct GuardSpec
    reads::Vector{ReadSpec}
    whole_containers::Vector{Any}
    notes::Vector{String}
end

"""
    guard_spec(::Type{EvtType}) -> GuardSpec

The static guard-read specification baked by [`@guard`](@ref). Defined only for
`@guard`-annotated event types; derived events expose the same information through
`derivation_spec`.
"""
function guard_spec end

# `@guard`'s read derivation: the `@precondition` read pass (derive.jl) with two
# leniencies — an uncovered whole-container read becomes a container subtree
# pattern instead of erroring, and a zero-read body yields an empty spec with a
# note instead of erroring. Everything else (aliasing, loop widening,
# precondition-recursion and @fragment inlining, opaque-state-call error) is the
# read pass byte-for-byte, reused by dispatch on `_TaintCtx`.
function _derive_guardspecs(body, statesym::Symbol, evtsym::Symbol, mod)
    ctx = _TaintCtx(statesym, evtsym, mod)
    _walk_block!(ctx, body)
    whole = Any[]
    for (cmember, _src) in ctx.whole_reads
        covered =
            any(s -> !spec_clean(s) && !isempty(s.matchstr) && s.matchstr[1] == cmember,
                ctx.reads) ||
            any(m -> !isempty(m) && m[1] == cmember, ctx.iterated)
        covered || (cmember in whole || push!(whole, cmember))
    end
    notes = copy(ctx.notes)
    if isempty(ctx.reads) && isempty(whole)
        push!(notes, "reads no state")
    end
    return (ctx.reads, whole, notes)
end

"""
    @guard function precondition(evt::EvtType, state)
        <body>
    end

Emit the precondition verbatim (analysis-only; runtime behavior is identical to
the unannotated method) and derive its static read specification for the footprint
lint, WITHOUT deriving generators — the hand-written `@conditionsfor` generators
stay in charge. This is how a model with hand-written generators opts into
[`lint`](@ref)'s missed-trigger check. Also bakes `precondition_ast` so
`guard_clauses` works on the annotated event.

Differences from [`@precondition`](@ref): a body that reads no state is allowed
(empty spec — e.g. `precondition(evt, state) = true`), and whole-container reads
(`length`/`keys`/`isempty`) are recorded as container-level subtree reads instead
of requiring a covering trigger. Passing state to an unregistered helper is still
a macro-time error; register the helper with `@fragment`.

Use exactly one of `@guard` or `@precondition` on a given event type.
"""
macro guard(fdef)
    sig, body = _split_funcdef(fdef)
    (sig isa Expr && sig.head === :call) ||
        error("@guard expects `function precondition(evt::EvtType, state) ... end`")
    length(sig.args) == 3 || error("@guard: precondition must take (evt::EvtType, state)")
    evt_arg = sig.args[2]
    (evt_arg isa Expr && evt_arg.head === :(::)) ||
        error("@guard: first argument must be `evt::EventType`")
    evtsym = evt_arg.args[1]::Symbol
    EvtType = evt_arg.args[2]
    state_arg = sig.args[3]
    statesym = state_arg isa Expr && state_arg.head === :(::) ? state_arg.args[1] : state_arg
    statesym isa Symbol || error("@guard: state argument must be a plain name")

    # Register before deriving so precondition-recursion into this event inlines.
    _PRECOND_REGISTRY[(__module__, :precondition, _evt_name(EvtType))] = (evtsym, statesym, body)

    reads, whole, notes = _derive_guardspecs(body, statesym, evtsym, __module__)
    spec = GuardSpec(reads, whole, notes)

    return Expr(:block,
        esc(fdef),                                                   # verbatim; zero runtime change
        :(ChronoSim.guard_spec(::Type{$(esc(EvtType))}) = $spec),
        :(ChronoSim.precondition_ast(::Type{$(esc(EvtType))}) =
            ($(QuoteNode(evtsym)), $(QuoteNode(statesym)), $(QuoteNode(body)))),
    )
end

########################### LintEdge, LintReport, LintAllow, LintFailure ###########################

"""
    LintEdge

One interference edge. `kind` is `:write_guard` or `:write_write`; `writer`/`reader`
are event-type names (for `:write_write`, the lexically first/second writer);
`overlap_mask` is the address group; `level` is `:warning` or `:info`;
`trigger_covered`/`covering_trigger` apply to `:write_guard`; `verdict` is
`:overlap`/`:possible`/`:empty`; `note` records enumeration outcome.
"""
struct LintEdge
    kind::Symbol
    writer::Symbol
    reader::Symbol
    write_mask::Tuple
    read_mask::Tuple
    overlap_mask::Tuple
    level::Symbol
    trigger_covered::Bool
    covering_trigger::String
    verdict::Symbol
    note::String
end

const RATE_NOTE = "write→rate edges: not analyzed (enable-time reads are runtime-only " *
    "in v1; the depnet tracks them dynamically)"

"""
    LintReport

The result of [`lint`](@ref): `events` (linted names, sorted), `edges`,
`dead_addresses`, `unanalyzed_guards`, `unanalyzed_effects`, the fixed `rate_note`,
and `caps` (enumeration / missing-physical notes). `show` prints a bounded summary;
[`print_lint`](@ref) prints every edge.
"""
struct LintReport
    events::Vector{Symbol}
    edges::Vector{LintEdge}
    dead_addresses::Vector{Symbol}
    unanalyzed_guards::Vector{Symbol}
    unanalyzed_effects::Vector{Symbol}
    rate_note::String
    caps::Vector{String}
    # Private: reader name -> its guard AddressPatterns, for static_covers_dynamic.
    guard_index::Dict{Symbol,Vector{AddressPattern}}
end

"""
    warnings(r::LintReport) -> Vector{LintEdge}

The warning-level edges of `r` (the missed-trigger interferences).
"""
warnings(r::LintReport) = LintEdge[e for e in r.edges if e.level === :warning]

"""
    LintAllow(; reader=nothing, writer=nothing, mask=nothing, reason)

An allowlist descriptor for [`assert_lint_clean`](@ref). A `nothing` field is a
wildcard; `mask` is matched against the exact string the report prints for the
overlap mask (e.g. `"[person, ℤ, waiting]"`). `reason` is mandatory: it documents
WHY this interference is an intended trigger narrowing.
"""
struct LintAllow
    reader::Union{Symbol,Nothing}
    writer::Union{Symbol,Nothing}
    mask::Union{String,Nothing}
    reason::String
end
LintAllow(; reader=nothing, writer=nothing, mask=nothing, reason) =
    LintAllow(reader, writer, mask, reason)

"""
    LintFailure

Thrown by [`assert_lint_clean`](@ref) when the report has warning-level edges not
matched by an allowlist entry.
"""
struct LintFailure <: Exception
    unallowed::Vector{LintEdge}
    report::LintReport
end

_mask_str(m) = _matchstr_str(m)

function Base.showerror(io::IO, e::LintFailure)
    println(io, "LintFailure: $(length(e.unallowed)) unallowed warning(s) (missed triggers):")
    shown = 0
    for w in e.unallowed
        shown += 1
        if shown > 20
            println(io, "  ... and $(length(e.unallowed) - 20) more (see print_lint)")
            break
        end
        println(io, "  reader $(w.reader)  mask $(_mask_str(w.overlap_mask))  writer $(w.writer)")
    end
    print(io, "add a LintAllow(reader=..., mask=\"...\", reason=...) entry if intended.")
    return nothing
end

########################### Per-event lint info ###########################

struct _Pat
    pattern::AddressPattern
    spec::Any    # ReadSpec / WriteSpec / nothing
end

function _event_lint_info(T)
    name = nameof(T)
    # writes
    writes = if hasmethod(effect_spec, Tuple{Type{T}})
        _Pat[_Pat(AddressPattern(w), w) for w in effect_spec(T).writes]
    else
        nothing
    end
    # guard reads + trigger surface
    local guard, place_triggers, fired_triggers
    if hasmethod(guard_spec, Tuple{Type{T}})
        gs = guard_spec(T)
        guard = _Pat[_Pat(AddressPattern(s), s) for s in gs.reads]
        for c in gs.whole_containers
            push!(guard, _Pat(_whole_pattern(c isa Member ? c : Member(Symbol(c))), nothing))
        end
        gens = generators(T)
        place_triggers = AddressPattern[AddressPattern(g) for g in gens if matches_place(g)]
        fired_triggers = Symbol[Symbol(g.matchstr[1]) for g in gens if matches_event(g)]
    elseif hasmethod(derivation_spec, Tuple{Type{T}})
        specs = derivation_spec(T)
        guard = _Pat[_Pat(AddressPattern(s), s) for s in specs]
        seen = Tuple[]
        place_triggers = AddressPattern[]
        for s in specs
            m = placekey_mask_index(s.matchstr)
            if !(m in seen)
                push!(seen, m)
                push!(place_triggers, _mask_pattern(m))
            end
        end
        fired_triggers = Symbol[]
    else
        guard = nothing
        place_triggers = AddressPattern[]
        fired_triggers = Symbol[]
    end
    return (name=name, evttype=T, writes=writes, guard=guard,
            place_triggers=place_triggers, fired_triggers=fired_triggers)
end

# Exact-mask trigger coverage (design D5): a ToPlace trigger mask equals the
# overlap mask, or the writer name is among the reader's fired triggers.
function _trigger_covered(B, writername::Symbol, om::Tuple)
    if writername in B.fired_triggers
        return (true, "fired($writername)")
    end
    for pt in B.place_triggers
        pt.mask == om && return (true, "place $(_mask_str(om))")
    end
    return (false, "")
end

########################### Enumeration refinement (plan task 3) ###########################

# A writer's event fields are bound to containers by its WRITES (e.g. `actors[who]`),
# not only its body reads, so container-key domain inference consults both.
function _writer_read_specs(A)
    hasmethod(effect_spec, Tuple{Type{A.evttype}}) || return ReadSpec[]
    es = effect_spec(A.evttype)
    specs = ReadSpec[s for s in es.reads]
    for w in es.writes
        push!(specs, ReadSpec(w.matchstr, w.indices, w.source))
    end
    return specs
end
_guard_read_specs(B) = ReadSpec[gp.spec for gp in B.guard if gp.spec isa ReadSpec]

function _field_domain_values(::Type{T}, field, specs, physical, enum_cap, caps) where {T}
    resolver, _prov = _resolve_field_domain(T, field, specs)
    if resolver === nothing
        push!(caps, "domain for $(nameof(T)).$field unresolvable without @domain")
        return nothing
    end
    dom = resolver(physical)
    vals = Any[]
    n = 0
    for v in dom
        n += 1
        if n > enum_cap
            push!(caps, "enumeration cap hit for $(nameof(T)).$field (> $enum_cap)")
            return nothing
        end
        push!(vals, v)
    end
    return vals
end

# :inhabited | :empty | :unknown for one paired index position.
function _pos_status(ia, ib, A, specsA, B, specsB, physical, enum_cap, caps)
    if ia isa TaintedIndex || ib isa TaintedIndex
        return :inhabited
    elseif ia isa LiteralIndex && ib isa LiteralIndex
        return ia.value == ib.value ? :inhabited : :empty
    elseif ia isa LiteralIndex && ib isa FieldBinding
        dom = _field_domain_values(B.evttype, ib.field, specsB, physical, enum_cap, caps)
        dom === nothing && return :unknown
        return ia.value in dom ? :inhabited : :empty
    elseif ia isa FieldBinding && ib isa LiteralIndex
        dom = _field_domain_values(A.evttype, ia.field, specsA, physical, enum_cap, caps)
        dom === nothing && return :unknown
        return ib.value in dom ? :inhabited : :empty
    elseif ia isa FieldBinding && ib isa FieldBinding
        da = _field_domain_values(A.evttype, ia.field, specsA, physical, enum_cap, caps)
        db = _field_domain_values(B.evttype, ib.field, specsB, physical, enum_cap, caps)
        (da === nothing || db === nothing) && return :unknown
        return isempty(intersect(Set(da), Set(db))) ? :empty : :inhabited
    elseif ia isa TupleIndex && ib isa TupleIndex
        length(ia.components) == length(ib.components) || return :empty
        st = :inhabited
        for (ca, cb) in zip(ia.components, ib.components)
            s = _pos_status(ca, cb, A, specsA, B, specsB, physical, enum_cap, caps)
            s === :empty && return :empty
            s === :unknown && (st = :unknown)
        end
        return st
    else
        return :unknown    # tuple-vs-literal / tuple-vs-fieldbinding: no relational reasoning
    end
end

# Refine a :possible write→guard verdict against the live physical domains. Returns
# (verdict, note). Only called with a live physical instance.
function _refine!(caps, verdict, wp, rp, A, B, physical, enum_cap)
    verdict === :possible || return (verdict, "")
    n = min(length(wp.pattern.mask), length(rp.pattern.mask))
    pairs = _paired_indices(wp.pattern, rp.pattern, n)
    specsA = _writer_read_specs(A)
    specsB = _guard_read_specs(B)
    any_unknown = false
    for (ia, ib) in pairs
        s = _pos_status(ia, ib, A, specsA, B, specsB, physical, enum_cap, caps)
        if s === :empty
            return (:empty, "provably empty overlap (enumeration)")
        elseif s === :unknown
            any_unknown = true
        end
    end
    return any_unknown ? (:possible, "") : (:overlap, "")
end

########################### Dead-address smell (plan task 2d) ###########################

function _dead_addresses(physical, infos)
    physical === nothing && return (Symbol[], String[])
    PT = physical isa Type ? physical : typeof(physical)
    written = Set{Symbol}()
    guardread = Set{Symbol}()
    for i in infos
        if i.writes !== nothing
            for wp in i.writes
                isempty(wp.pattern.mask) || push!(written, Symbol(wp.pattern.mask[1]))
            end
        end
        if i.guard !== nothing
            for gp in i.guard
                isempty(gp.pattern.mask) || push!(guardread, Symbol(gp.pattern.mask[1]))
            end
        end
    end
    dead = Symbol[]
    for f in fieldnames(PT)
        (f === :obs_modified || f === :obs_read) && continue
        ft = fieldtype(PT, f)
        ObservedState.structure_trait(ft) isa ObservedState.UnObservableTrait && continue
        (f in written || f in guardread) && continue
        push!(dead, f)
    end
    return (dead, String[])
end

########################### lint ###########################

function _dedup_edges(edges)
    out = LintEdge[]
    seen = Set{Tuple{Symbol,Symbol,Symbol,Tuple,Symbol,Symbol}}()
    for e in edges
        k = (e.kind, e.writer, e.reader, e.overlap_mask, e.level, e.verdict)
        k in seen && continue
        push!(seen, k)
        push!(out, e)
    end
    return out
end

_edge_sortkey(e::LintEdge) =
    (string(e.kind), _mask_str(e.overlap_mask), string(e.writer), string(e.reader))

"""
    lint(events::AbstractVector; physical=nothing, enum_cap=10_000) -> LintReport
    lint(mod::Module; kwargs...) -> LintReport

Construction-time footprint lint over the static read/write masks of `events` (the
same event-type vector passed to [`SimulationFSM`](@ref)). Computes write→guard
interference edges (an edge no trigger covers is a WARNING), write→write races
(info), dead-address smells (info; requires `physical`); write→rate edges are NOT
analyzed in v1 and the report says so.

With a live `physical` instance, `:possible` index intersections are refined by
enumerating the inferred finite domains; a provably empty overlap demotes the edge
to info (the edge remains). Enumeration is capped at `enum_cap` per domain; caps
are reported. Passing a `physical` type enables dead-address reflection only.

The lint is static and over-approximate — it sees address masks, not expression
semantics. See the "Linting a model's footprints" guide.
"""
function lint(events::AbstractVector; physical=nothing, enum_cap=10_000)
    caps = String[]
    sorted = sort(collect(events); by=nameof)
    infos = [_event_lint_info(T) for T in sorted]
    do_enum = !(physical === nothing || physical isa Type)
    edges = LintEdge[]

    # write→guard: ordered pairs, incl. A == B (self-interference is meaningful).
    for A in infos, B in infos
        (A.writes === nothing || B.guard === nothing) && continue
        for wp in A.writes, rp in B.guard
            v = _intersect_verdict(wp.pattern, rp.pattern)
            v === :disjoint && continue
            note = ""
            if do_enum && v === :possible
                v, note = _refine!(caps, v, wp, rp, A, B, physical, enum_cap)
            end
            om = length(wp.pattern.mask) >= length(rp.pattern.mask) ?
                Tuple(wp.pattern.mask) : Tuple(rp.pattern.mask)
            covered, ctrig = _trigger_covered(B, A.name, om)
            level = (v === :empty || covered) ? :info : :warning
            push!(edges, LintEdge(:write_guard, A.name, B.name, Tuple(wp.pattern.mask),
                Tuple(rp.pattern.mask), om, level, covered, ctrig, v, note))
        end
    end

    # write→write races: distinct unordered type pairs, info always (design D10).
    for ia in 1:length(infos), ib in (ia + 1):length(infos)
        A = infos[ia]
        B = infos[ib]
        (A.writes === nothing || B.writes === nothing) && continue
        for wp in A.writes, rp in B.writes
            v = _intersect_verdict(wp.pattern, rp.pattern)
            v === :disjoint && continue
            om = length(wp.pattern.mask) >= length(rp.pattern.mask) ?
                Tuple(wp.pattern.mask) : Tuple(rp.pattern.mask)
            push!(edges, LintEdge(:write_write, A.name, B.name, Tuple(wp.pattern.mask),
                Tuple(rp.pattern.mask), om, :info, false, "", v, ""))
        end
    end

    edges = _dedup_edges(edges)
    sort!(edges; by=_edge_sortkey)

    dead, deadcaps = _dead_addresses(physical, infos)
    append!(caps, deadcaps)
    if physical === nothing
        push!(caps, "index enumeration skipped (no physical provided)")
        push!(caps, "dead-address reflection skipped (no physical provided)")
    elseif physical isa Type
        push!(caps, "index enumeration skipped (physical type given; live instance needed)")
    end

    unan_g = Symbol[i.name for i in infos if i.guard === nothing]
    unan_e = Symbol[i.name for i in infos if i.writes === nothing]

    guard_index = Dict{Symbol,Vector{AddressPattern}}()
    for i in infos
        i.guard === nothing && continue
        guard_index[i.name] = AddressPattern[p.pattern for p in i.guard]
    end

    return LintReport([i.name for i in infos], edges, dead, unan_g, unan_e,
        RATE_NOTE, unique(caps), guard_index)
end

function lint(mod::Module; kwargs...)
    evs = Type[]
    for nm in names(mod; all=true, imported=false)
        isdefined(mod, nm) || continue
        v = getfield(mod, nm)
        if v isa Type && v !== SimEvent && v <: SimEvent && isconcretetype(v)
            push!(evs, v)
        end
    end
    return lint(sort(evs; by=nameof); kwargs...)
end

########################### Report display ###########################

function Base.show(io::IO, r::LintReport)
    print(io, "LintReport($(length(r.events)) events, $(length(r.edges)) edges, ",
        "$(length(warnings(r))) warnings)")
    return nothing
end

# Ordered grouping of warning edges by (reader, overlap mask) with writer list.
function _warning_groups(r::LintReport)
    order = Tuple{Symbol,Tuple}[]
    writers = Dict{Tuple{Symbol,Tuple},Vector{Symbol}}()
    for e in warnings(r)
        key = (e.reader, e.overlap_mask)
        if !haskey(writers, key)
            push!(order, key)
            writers[key] = Symbol[]
        end
        e.writer in writers[key] || push!(writers[key], e.writer)
    end
    return order, writers
end

function Base.show(io::IO, ::MIME"text/plain", r::LintReport)
    wg = LintEdge[e for e in r.edges if e.kind === :write_guard]
    ww = LintEdge[e for e in r.edges if e.kind === :write_write]
    warns = LintEdge[e for e in wg if e.level === :warning]
    ninfo = length(wg) - length(warns)
    naddr = length(unique(Tuple[e.overlap_mask for e in wg]))
    order, writers = _warning_groups(r)
    println(io, "LintReport: $(length(r.events)) events")
    println(io, "  write→guard: $(length(wg)) edges over $naddr addresses ",
        "($(length(warns)) warnings in $(length(order)) groups, $ninfo info)")
    shown = 0
    for key in order
        shown += 1
        if shown > 20
            println(io, "  ... (+$(length(order) - 20) more — print_lint(io, report))")
            break
        end
        reader, mask = key
        println(io, "  WARNING missed trigger: reader $reader  mask $(_mask_str(mask))  ",
            "writers: $(join(writers[key], ", "))")
    end
    println(io, "  write→write: $(length(ww)) shared-address pairs (info)")
    println(io, "  " * r.rate_note)
    println(io, "  dead addresses: ",
        isempty(r.dead_addresses) ? "none" : join(r.dead_addresses, ", "))
    println(io, "  unanalyzed guards: ",
        isempty(r.unanalyzed_guards) ? "none" : join(r.unanalyzed_guards, ", "),
        "    unanalyzed effects: ",
        isempty(r.unanalyzed_effects) ? "none" : join(r.unanalyzed_effects, ", "))
    print(io, "  caps: ", isempty(r.caps) ? "none" : join(r.caps, "; "))
    return nothing
end

"""
    print_lint(io::IO, report::LintReport)

The full, unbounded, greppable report: every edge on one line, stable field order.
CI test logs use this; `show(io, MIME"text/plain"(), report)` prints the bounded
summary.
"""
function print_lint(io::IO, r::LintReport)
    println(io, "LintReport: $(length(r.events)) events [$(join(r.events, ", "))]")
    for e in r.edges
        cov = e.kind === :write_guard ?
            (e.trigger_covered ? "covered($(e.covering_trigger))" : "uncovered") : "-"
        kindstr = e.kind === :write_guard ? "write→guard" : "write→write"
        println(io, "edge $kindstr $(e.writer) -> $(e.reader) $(_mask_str(e.overlap_mask)) ",
            "$(e.level) $cov $(e.verdict) \"$(e.note)\"")
    end
    println(io, r.rate_note)
    println(io, "dead addresses: ",
        isempty(r.dead_addresses) ? "none" :
        join(["$d — written by no event, read by no guard (rate reads not analyzed)"
              for d in r.dead_addresses], "\n  "))
    println(io, "unanalyzed guards: ",
        isempty(r.unanalyzed_guards) ? "none" : join(r.unanalyzed_guards, ", "))
    println(io, "unanalyzed effects: ",
        isempty(r.unanalyzed_effects) ? "none" : join(r.unanalyzed_effects, ", "))
    println(io, "caps: ", isempty(r.caps) ? "none" : join(r.caps, "; "))
    return nothing
end
print_lint(r::LintReport) = print_lint(stdout, r)

########################### assert_lint_clean + allowlist ###########################

_allow_matches(a::LintAllow, e::LintEdge) =
    (a.reader === nothing || a.reader == e.reader) &&
    (a.writer === nothing || a.writer == e.writer) &&
    (a.mask === nothing || a.mask == _mask_str(e.overlap_mask))

"""
    assert_lint_clean(report::LintReport; allow=LintAllow[], io=stdout)

Throw [`LintFailure`](@ref) if `report` contains any warning-level edge not matched
by an `allow` entry. Info-level findings never fail. Unused `allow` entries print a
staleness notice to `io` (not a failure). This is the CI entry point.
"""
function assert_lint_clean(report::LintReport; allow::AbstractVector{LintAllow}=LintAllow[],
                           io::IO=stdout)
    warns = warnings(report)
    used = falses(length(allow))
    unallowed = LintEdge[]
    for e in warns
        matched = false
        for (i, a) in enumerate(allow)
            if _allow_matches(a, e)
                used[i] = true
                matched = true
            end
        end
        matched || push!(unallowed, e)
    end
    for (i, a) in enumerate(allow)
        used[i] && continue
        println(io, "note: stale LintAllow (matched no warning): ",
            "reader=$(a.reader) writer=$(a.writer) mask=$(a.mask) — $(a.reason)")
    end
    isempty(unallowed) || throw(LintFailure(unallowed, report))
    return report
end

########################### LintHarvest + static_covers_dynamic (plan task 5) ###########################

"""
    LintHarvest()

An [`ExecutionPolicy`](@ref) that records, at every `on_postfire`/`on_init`, each
enabled event's enable-dependency places (masked to `(reader, place)`) and, for
each address the fired event changed, the `(writer, reader, place)` interactions
the live dependency network shows. Feed the result to [`static_covers_dynamic`](@ref)
to check the static report covers every runtime edge (soundness direction only).
Test-tier and opt-in; do not run it in production replicates.
"""
struct LintHarvest <: ExecutionPolicy
    read_deps::Set{Tuple{Symbol,Any}}
    pairs::Set{Tuple{Symbol,Symbol,Any}}
end
LintHarvest() = LintHarvest(Set{Tuple{Symbol,Any}}(), Set{Tuple{Symbol,Symbol,Any}}())

function on_postfire(h::LintHarvest, sim, clock_key_, event, when, changed_places)
    dep = sim.event_dependency.depnet
    for (evtkey, de) in dep.event
        for p in de.en
            push!(h.read_deps, (evtkey[1], p))
        end
    end
    w = nameof(typeof(event))
    for p in changed_places
        for rk in getplace_enable(dep, p)
            push!(h.pairs, (w, rk[1], p))
        end
    end
    return nothing
end
on_init(h::LintHarvest, sim, init_evt, changed_places) =
    on_postfire(h, sim, nothing, init_evt, sim.when, changed_places)

"""
    DynamicCoverage

Result of [`static_covers_dynamic`](@ref): `covered`, plus the runtime
`missing_reads` and `missing_edges` the static report failed to cover.
"""
struct DynamicCoverage
    covered::Bool
    missing_reads::Vector{Tuple{Symbol,Any}}
    missing_edges::Vector{Tuple{Symbol,Symbol,Any}}
end

function Base.show(io::IO, dc::DynamicCoverage)
    print(io, "DynamicCoverage(covered=$(dc.covered), ",
        "$(length(dc.missing_reads)) missing reads, $(length(dc.missing_edges)) missing edges)")
    return nothing
end

# One-directional prefix cover: the edge's overlap mask must equal, or be a
# prefix of (subtree write over a deeper concrete place), the harvested place
# mask. A deeper edge mask never covers a shallower place.
function _edge_mask_covers_place(edge_mask, place_mask)
    length(edge_mask) <= length(place_mask) || return false
    for i in eachindex(edge_mask)
        edge_mask[i] == place_mask[i] || return false
    end
    return true
end

"""
    static_covers_dynamic(report::LintReport, harvest::LintHarvest;
                          ignore_writers=Symbol[]) -> DynamicCoverage

Check static ⊇ dynamic: every harvested enable-dependency place of a linted event
is covered by some static guard pattern, and every harvested (writer, reader, place)
interaction is covered by a write→guard edge (info or warning — demoted edges still
count). `ignore_writers` skips initializer events absent from the linted vector.
`covered == true` is the CI assertion.
"""
function static_covers_dynamic(report::LintReport, harvest::LintHarvest;
                               ignore_writers=Symbol[])
    linted = Set(report.events)
    ignore = Set(ignore_writers)
    missing_reads = Tuple{Symbol,Any}[]
    for (B, place) in harvest.read_deps
        B in linted || continue
        pats = get(report.guard_index, B, nothing)
        if pats === nothing
            # An unanalyzed reader with harvested enable deps is UNCOVERED: the
            # static report has no guard patterns for it, so the theorem's read
            # clause fails (an unanalyzed reader whose runtime read set is empty
            # never reaches here — the depnet holds no en edges for it).
            push!(missing_reads, (B, place))
            continue
        end
        pp = AddressPattern(place)
        any(g -> masks_intersect(pp, g), pats) || push!(missing_reads, (B, place))
    end
    missing_edges = Tuple{Symbol,Symbol,Any}[]
    for (A, B, place) in harvest.pairs
        A in ignore && continue
        pm = placekey_mask_index(place)
        ok = any(report.edges) do e
            e.kind === :write_guard && e.writer == A && e.reader == B &&
                _edge_mask_covers_place(e.overlap_mask, pm)
        end
        ok || push!(missing_edges, (A, B, place))
    end
    covered = isempty(missing_reads) && isempty(missing_edges)
    return DynamicCoverage(covered, missing_reads, missing_edges)
end
