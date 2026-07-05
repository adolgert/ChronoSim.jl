# Deriving event generators from precondition source.
#
# `@precondition` runs a syntactic taint pass over a precondition body at macro
# time, producing `ReadSpec` literals. At setup time (first `generators()` call)
# `derived_generators` turns those specs into `EventGenerator` closures that are
# drop-in equivalents of hand-written `@conditionsfor`/`@reactto` generators, so
# the runtime (GeneratorSearch, over_generated_events) is untouched.
#
# See scratchpad/phase3_design.md for the authoritative design.

export @precondition, @domain, @fragment, derivation_report

########################### Read-spec data model ###########################

# One index-position classification. A read's `indices` holds one of these per
# MEMBERINDEX position, in path order. `inds[k]` at loop time is the concrete
# index the runtime delivers for position k.
struct FieldBinding
    field::Symbol   # this index position equals evt.field
end
struct LiteralIndex
    value::Any      # this index position is a compile-time literal -> runtime guard
end
struct TaintedIndex end   # index unresolvable from evt fields -> forces widening
struct TupleIndex
    components::Vector{Any}   # NTuple index (dict tuple key or N-dim array); per-component specs
end

index_clean(::FieldBinding) = true
index_clean(::LiteralIndex) = true
index_clean(::TaintedIndex) = false
index_clean(t::TupleIndex) = all(index_clean, t.components)

# A single state-read site derived from the precondition body.
struct ReadSpec
    matchstr::Vector{Any}   # e.g. [Member(:elevator), MEMBERINDEX, Member(:floor)]
    indices::Vector{Any}    # one index spec per MEMBERINDEX position, path order
    source::String          # original access text, for diagnostics
end

spec_clean(s::ReadSpec) = all(index_clean, s.indices)

# derivation_spec(::Type{EvtType}) is emitted per event for diagnostics/reports.
function derivation_spec end

# precondition_ast(::Type{EvtType}) -> (evtsym, statesym, body) is emitted per
# `@precondition` event as a baked runtime method (parallel to derivation_spec).
# The `_PRECOND_REGISTRY` that `@precondition` populates is a compile-time-only
# structure (mutated during macro expansion, consumed during derivation of other
# preconditions/fragments), so it is empty at runtime for precompiled packages.
# `guard_clauses` (Phase 1c) is the first RUNTIME consumer of the body, so the
# body is also emitted here as a method that survives precompilation.
function precondition_ast end

# `_is_registered_fragment(f)` reports whether `f` is an `@fragment` helper. Like
# the precondition body, the compile-time `_FRAGMENT_REGISTRY` is empty at runtime
# for precompiled packages; @fragment emits a per-helper method so guard_clauses
# (Phase 1c) can call a registered helper as a real function and still refuse
# arbitrary opaque calls.
_is_registered_fragment(@nospecialize(f)) = false

# `fragment_ast(helper) -> (params::Vector{Symbol}, body)` and
# `domain_ast(::Type{EvtType}, ::Val{field}) -> rhs_ast` are baked accessors for
# the ORIGINAL un-inlined helper/domain source, emitted by `@fragment`/`@domain`
# as literal-returning methods (the compile-time registries are empty after
# precompilation, Amendment 1). Phase 4's effect lowering emits fragments as
# Quint defs and domains as generator bodies from these. Defined only for the
# annotated helpers/fields; consumers hasmethod-gate.
function fragment_ast end
function domain_ast end

# Structural equality used for dedup/merge (default struct == is identity for the
# Vector-carrying TupleIndex, so we compare explicitly).
_idx_equal(a::FieldBinding, b::FieldBinding) = a.field == b.field
_idx_equal(a::LiteralIndex, b::LiteralIndex) = a.value == b.value
_idx_equal(::TaintedIndex, ::TaintedIndex) = true
function _idx_equal(a::TupleIndex, b::TupleIndex)
    length(a.components) == length(b.components) || return false
    return all(((x, y),) -> _idx_equal(x, y), zip(a.components, b.components))
end
_idx_equal(::Any, ::Any) = false

function _indices_equal(as, bs)
    length(as) == length(bs) || return false
    return all(((x, y),) -> _idx_equal(x, y), zip(as, bs))
end

function _matchstr_equal(a, b)
    length(a) == length(b) || return false
    return all(((x, y),) -> x == y, zip(a, b))
end

########################### Syntactic helpers ###########################

_is_literal(x) = x isa Number || x isa Bool || x isa String || x isa Char || x isa QuoteNode
_literal_value(x) = x isa QuoteNode ? x.value : x
_fieldsym(x) = x isa QuoteNode ? x.value : x

# Sentinel index standing for "element at an unknown key/position", used when a
# loop variable aliases an element of an iterated container.
const _TAINT = Symbol("#tainted_index#")

# Root symbol of a pure `.field`/`[index]` access chain, else `nothing`.
function _access_root(expr)
    cur = expr
    while cur isa Expr
        if cur.head === :. || cur.head === :ref
            cur = cur.args[1]
        else
            return nothing
        end
    end
    return cur isa Symbol ? cur : nothing
end

# Substitute state aliases everywhere, including inside index subexpressions, so a
# chain rooted at a local becomes a chain rooted at the state parameter.
function _resolve(expr, aliases)
    if expr isa Symbol
        return get(aliases, expr, expr)
    elseif expr isa Expr
        if expr.head === :.
            return Expr(:., _resolve(expr.args[1], aliases), expr.args[2])
        elseif expr.head === :ref
            return Expr(
                :ref,
                _resolve(expr.args[1], aliases),
                (_resolve(a, aliases) for a in expr.args[2:end])...,
            )
        else
            return Expr(expr.head, (_resolve(a, aliases) for a in expr.args)...)
        end
    else
        return expr
    end
end

# The `[index]` args along an access chain, outermost first (before reverse in
# access_to_argnames these are the raw index exprs; we use them to collect nested
# reads that live inside index subexpressions).
function _index_subexprs(expr)
    out = Any[]
    cur = expr
    while cur isa Expr && (cur.head === :. || cur.head === :ref)
        if cur.head === :ref
            append!(out, cur.args[2:end])
        end
        cur = cur.args[1]
    end
    return out
end

# Drop the state head so the reused access_to_searchkey yields no spurious leading
# Member for the state parameter.
function _strip_state_head(expr, statesym)
    if expr isa Expr
        if expr.head === :.
            base = expr.args[1]
            if base === statesym
                return _fieldsym(expr.args[2])
            else
                return Expr(:., _strip_state_head(base, statesym), expr.args[2])
            end
        elseif expr.head === :ref
            return Expr(:ref, _strip_state_head(expr.args[1], statesym), expr.args[2:end]...)
        end
    end
    return expr
end

########################### Fragment / precondition registries ###########################

# Both registries are populated at MACRO-EXPANSION time (inside @fragment / @precondition
# macro bodies), so a helper or callee precondition must be macro-expanded before any
# precondition that inlines it — the same top-to-bottom order Julia already uses to expand
# a module's top-level forms. Keys carry __module__ so identically named helpers in
# different modules never collide; re-registering the same key overwrites (Revise-friendly).

# (module, helper-name, arity) -> (param_names, body). Only single-method, positional,
# annotation-free-after-strip helpers are stored (see @fragment for the guards).
const _FRAGMENT_REGISTRY = Dict{Tuple{Module,Symbol,Int},Tuple{Vector{Symbol},Any}}()

# (module, :precondition, EvtType-name) -> (evtsym, statesym, body). Lets a precondition
# be inlined into another via `precondition(EvtType(args...), state)` recursion.
const _PRECOND_REGISTRY = Dict{Tuple{Module,Symbol,Symbol},Tuple{Symbol,Symbol,Any}}()

# Reducers whose generator/comprehension argument body is fully visible syntax we can walk.
const _REDUCERS = Set{Symbol}([:any, :all, :count, :sum, :prod, :minimum, :maximum])

const _INLINE_DEPTH_LIMIT = 8

# Last Symbol of an event-type expression (bare `Evt`, `Mod.Evt`, or `Evt{T}`) — the key
# under which its precondition is registered.
_evt_name(x::Symbol) = x
function _evt_name(x::Expr)
    if x.head === :. && x.args[2] isa QuoteNode
        return x.args[2].value
    elseif x.head === :curly
        return _evt_name(x.args[1])
    end
    error("@precondition: cannot determine event-type name from `$x`")
end

# Names assigned (and thus local) anywhere in a helper/precondition body: LHS of `=`, loop
# variables, and generator/comprehension iteration variables. These get α-renamed per call
# site so helper locals never collide with caller locals or with a second call site.
function _collect_lhs_names!(set, lhs)
    if lhs isa Symbol
        push!(set, lhs)
    elseif lhs isa Expr
        if lhs.head === :tuple
            for a in lhs.args
                _collect_lhs_names!(set, a)
            end
        elseif lhs.head === :(::) || lhs.head === :...
            _collect_lhs_names!(set, lhs.args[1])
        end
        # `.field`/`[index]` LHS is a mutation of an existing object, not a new local.
    end
    return nothing
end

function _collect_gen_spec_names!(set, spec)
    spec isa Expr || return nothing
    if spec.head === :filter
        for s in spec.args[2:end]
            _collect_gen_spec_names!(set, s)
        end
    elseif spec.head === :(=)
        _collect_lhs_names!(set, spec.args[1])
        _collect_assigned!(set, spec.args[2])
    end
    return nothing
end

function _collect_assigned!(set, expr)
    expr isa Expr || return nothing
    h = expr.head
    if h === :(=)
        _collect_lhs_names!(set, expr.args[1])
        _collect_assigned!(set, expr.args[2])
    elseif h === :for
        header = expr.args[1]
        if header isa Expr && header.head === :(=)
            _collect_lhs_names!(set, header.args[1])
            _collect_assigned!(set, header.args[2])
        elseif header isa Expr && header.head === :block
            for s in header.args
                if s isa Expr && s.head === :(=)
                    _collect_lhs_names!(set, s.args[1])
                    _collect_assigned!(set, s.args[2])
                end
            end
        end
        for a in expr.args[2:end]
            _collect_assigned!(set, a)
        end
    elseif h === :generator
        _collect_assigned!(set, expr.args[1])
        for spec in expr.args[2:end]
            _collect_gen_spec_names!(set, spec)
        end
    elseif h === :quote
        # Don't descend into quoted syntax.
    else
        for a in expr.args
            _collect_assigned!(set, a)
        end
    end
    return nothing
end

# Syntactic substitution of a Symbol->replacement map. Field names in `a.field` (the
# QuoteNode) are never variables, so they are preserved; call callees ARE substituted so a
# helper param used as a called function is handled.
_subst(expr, map) =
    if expr isa Symbol
        return get(map, expr, expr)
    elseif expr isa Expr
        if expr.head === :quote
            return expr
        elseif expr.head === :.
            return Expr(:., _subst(expr.args[1], map), expr.args[2])
        else
            return Expr(expr.head, Any[_subst(a, map) for a in expr.args]...)
        end
    else
        return expr
    end

# Precondition-recursion substitution: `evtsym.field` becomes the caller-side constructor
# argument for that field (so a caller passing its OWN `evt.f` yields a CLEAN FieldBinding,
# and passing a loop var yields a tainted/widened read); everything else via `symmap`
# (callee statesym -> caller state expr, callee locals -> gensyms).
function _subst_precond(expr, evtsym, fieldmap, symmap)
    if expr isa Symbol
        return get(symmap, expr, expr)
    elseif expr isa Expr
        if expr.head === :quote
            return expr
        elseif expr.head === :. && expr.args[1] === evtsym
            f = _fieldsym(expr.args[2])
            return haskey(fieldmap, f) ? fieldmap[f] : expr
        elseif expr.head === :.
            return Expr(:., _subst_precond(expr.args[1], evtsym, fieldmap, symmap), expr.args[2])
        else
            return Expr(
                expr.head, Any[_subst_precond(a, evtsym, fieldmap, symmap) for a in expr.args]...
            )
        end
    else
        return expr
    end
end

########################### Taint pass ###########################

# Abstract supertype so the write-side `@fire` walker (`_FireCtx`, in
# derive_effects.jl) can reuse the traversal by multiple dispatch instead of
# copy-paste. The read pass's `_TaintCtx` and the write pass's `_FireCtx` both
# subtype `_WalkCtx`; every traversal function is annotated `::_WalkCtx` so
# `_FireCtx` inherits it and overrides only `_walk_call!`/`_walk_assign!`.
abstract type _WalkCtx end

mutable struct _TaintCtx <: _WalkCtx
    statesym::Symbol
    evtsym::Symbol
    aliases::Dict{Symbol,Any}      # local -> resolved state access chain (rooted at statesym)
    evt_locals::Dict{Symbol,Any}   # local -> evt-pure expr it was bound to
    reads::Vector{ReadSpec}
    notes::Vector{String}
    iterated::Vector{Vector{Any}}  # matchstrs of iterated containers (cover whole-container reads)
    whole_reads::Vector{Tuple{Any,String}}  # (container Member, source) needing a covering trigger
    mod::Union{Module,Nothing}     # expanding module, for registry lookups (nothing -> no inlining)
    depth::Int                     # current inlining depth (bounded by _INLINE_DEPTH_LIMIT)
    stack::Vector{String}          # inlined-frame names, for cycle detection
end

function _TaintCtx(statesym, evtsym, mod=nothing)
    _TaintCtx(
        statesym,
        evtsym,
        Dict{Symbol,Any}(),
        Dict{Symbol,Any}(),
        ReadSpec[],
        String[],
        Vector{Any}[],
        Tuple{Any,String}[],
        mod,
        0,
        String[],
    )
end

# Whitelisted read-transparent Base functions; comparison/arith/bool operators.
const _ARITH_BOOL_OPS = Set{Symbol}([
    :(==),
    :(!=),
    :≠,
    :<,
    :(<=),
    :≤,
    :>,
    :(>=),
    :≥,
    :+,
    :-,
    :*,
    :/,
    :÷,
    :%,
    :^,
    :!,
    :xor,
    :⊻,
    :&,
    :|,
    :~,
    :min,
    :max,
    :abs,
    :mod,
    :div,
])
const _WHITELIST = Set{Symbol}([
    :length,
    :eachindex,
    :isempty,
    :keys,
    :values,
    :pairs,
    :haskey,
    :get,
    :get!,
    :in,
    :∈,
    :lastindex,
    :firstindex,
    :axes,
])

function _callee_name(callee)
    callee isa Symbol && return callee
    if callee isa Expr && callee.head === :. && callee.args[2] isa QuoteNode
        return callee.args[2].value
    end
    return nothing
end

function _is_evt_pure(x, ctx::_WalkCtx)
    _is_literal(x) && return true
    if x isa Symbol
        return haskey(ctx.evt_locals, x)
    end
    if x isa Expr
        if x.head === :. && x.args[1] === ctx.evtsym
            return true
        elseif x.head === :. || x.head === :ref
            return false
        elseif x.head === :call
            # Skip the callee symbol; an evt-pure index is an operator applied to
            # evt fields/literals (e.g. evt.floor + 1).
            return all(a -> _is_evt_pure(a, ctx), x.args[2:end])
        else
            return all(a -> _is_evt_pure(a, ctx), x.args)
        end
    end
    return false
end

# True if `expr`, after alias resolution, exposes the state symbol, a state alias,
# or any state access chain (leaf or compound). Passing such a thing to an opaque
# function hides reads -> out of fragment.
function _has_state_access(e, statesym)
    e === statesym && return true
    if e isa Expr
        if (e.head === :. || e.head === :ref) && _access_root(e) === statesym
            return true
        end
        return any(x -> _has_state_access(x, statesym), e.args)
    end
    return false
end

_contains_state(a, ctx::_WalkCtx) = _has_state_access(_resolve(a, ctx.aliases), ctx.statesym)

function _classify_index(ctx::_WalkCtx, idx)
    idx === _TAINT && return TaintedIndex()
    if idx isa Expr && idx.head === :tuple
        return TupleIndex(Any[_classify_index(ctx, c) for c in idx.args])
    end
    _is_literal(idx) && return LiteralIndex(_literal_value(idx))
    if idx isa Expr && idx.head === :. && idx.args[1] === ctx.evtsym
        return FieldBinding(_fieldsym(idx.args[2]))
    end
    if idx isa Symbol && haskey(ctx.evt_locals, idx)
        b = ctx.evt_locals[idx]
        if b isa Expr && b.head === :. && b.args[1] === ctx.evtsym
            return FieldBinding(_fieldsym(b.args[2]))
        end
        push!(ctx.notes, "index `$idx` is an evt-derived value, not a bare field; widened")
        return TaintedIndex()
    end
    if _is_evt_pure(idx, ctx)
        push!(ctx.notes, "affine/complex evt index `$idx` widened (exact inversion is future work)")
        return TaintedIndex()
    end
    return TaintedIndex()
end

# Matchstr for a container access chain (may strip to a bare Symbol, which
# access_to_searchkey does not accept).
function _container_matchstr(chain, statesym)
    stripped = _strip_state_head(chain, statesym)
    return stripped isa Symbol ? Any[Member(stripped)] : access_to_searchkey(stripped)
end

function _record_read!(ctx::_WalkCtx, resolved_access, source)
    stripped = _strip_state_head(resolved_access, ctx.statesym)
    if stripped isa Symbol
        # A top-level scalar field of the physical state is a place with no
        # index components: the runtime notifies (Member(field),) for it, so
        # the trigger pattern is that single component. It binds no event
        # fields, so it generates over the event's full field domains, like a
        # widened trigger but with a clean (empty) binding set.
        push!(ctx.reads, ReadSpec(Any[Member(stripped)], Any[], source))
        return nothing
    end
    matchstr = access_to_searchkey(stripped)
    argnames = access_to_argnames(stripped)
    indices = Any[_classify_index(ctx, idx) for idx in argnames]
    push!(ctx.reads, ReadSpec(matchstr, indices, source))
    return nothing
end

# Record `container[key]` as a read (haskey/get/get!/∈ per-key form).
function _record_key_read!(ctx::_WalkCtx, container, key, source)
    resolved = Expr(:ref, _resolve(container, ctx.aliases), key)
    _record_read!(ctx, resolved, source)
    return nothing
end

function _walk!(ctx::_WalkCtx, expr)
    if expr isa Symbol
        haskey(ctx.aliases, expr) && _record_read!(ctx, ctx.aliases[expr], string(expr))
        return nothing
    end
    expr isa Expr || return nothing
    h = expr.head
    if h === :. || h === :ref
        r = _access_root(expr)
        if r === ctx.statesym || (r isa Symbol && haskey(ctx.aliases, r))
            _record_read!(ctx, _resolve(expr, ctx.aliases), string(expr))
            for idx in _index_subexprs(expr)
                _walk!(ctx, idx)
            end
        else
            for a in expr.args
                _walk!(ctx, a)
            end
        end
        return nothing
    elseif h === :call
        _walk_call!(ctx, expr)
        return nothing
    elseif h === :(=)
        _walk_assign!(ctx, expr)
        return nothing
    elseif h === :for
        _walk_for!(ctx, expr)
        return nothing
    elseif h === :while
        _walk!(ctx, expr.args[1])
        _scoped_block!(ctx, expr.args[2])
        return nothing
    elseif h === :if || h === :elseif
        _walk_if!(ctx, expr)
        return nothing
    elseif h === :block
        _scoped_block!(ctx, expr)
        return nothing
    elseif h === :comprehension
        _walk_generator!(ctx, expr.args[1])
        return nothing
    elseif h === :generator
        _walk_generator!(ctx, expr)
        return nothing
    else
        for a in expr.args
            _walk!(ctx, a)
        end
        return nothing
    end
end

function _walk_call!(ctx::_WalkCtx, expr)
    callee = expr.args[1]
    args = expr.args[2:end]
    name = _callee_name(callee)
    if name !== nothing && name in _ARITH_BOOL_OPS
        for a in args
            _walk!(ctx, a)
        end
        return nothing
    end
    if name !== nothing && name in _WHITELIST
        _walk_whitelisted!(ctx, name, args, expr)
        return nothing
    end
    # Reducer over a generator/comprehension: the generator body is fully visible syntax,
    # so walk it. A bare state-container arg (e.g. `any(f, container)`) is NOT a generator,
    # so it falls through to the opaque check below and still errors (f hides its reads).
    if name !== nothing &&
        name in _REDUCERS &&
        all(a -> _is_gen_arg(a) || !_contains_state(a, ctx), args)
        for a in args
            if a isa Expr && a.head === :generator
                _walk_generator!(ctx, a)
            elseif a isa Expr && a.head === :comprehension
                _walk_generator!(ctx, a.args[1])
            else
                _walk!(ctx, a)
            end
        end
        return nothing
    end
    # Precondition-recursion inlining: `precondition(EvtType(cargs...), state)`.
    if name === :precondition && ctx.mod !== nothing && _try_inline_precondition!(ctx, expr, args)
        return nothing
    end
    # Registered @fragment helper: inline its body (substituting caller args) instead of
    # treating it as opaque. This is the opt-in that makes a state-argument call derivable.
    if name !== nothing && ctx.mod !== nothing && _try_inline_fragment!(ctx, name, args)
        return nothing
    end
    # Opaque user function: a state-derived argument hides reads -> out of fragment.
    for a in args
        if _contains_state(a, ctx)
            error(_fragment_error(ctx, expr, a))
        end
    end
    for a in args
        _walk!(ctx, a)
    end
    return nothing
end

_is_gen_arg(a) = a isa Expr && (a.head === :generator || a.head === :comprehension)

# Inline a registered @fragment helper call `name(args...)`. Returns false (no-op) when no
# helper of that (module, name, arity) is registered, so the caller falls through.
function _try_inline_fragment!(ctx::_WalkCtx, name::Symbol, args)
    key = (ctx.mod, name, length(args))
    haskey(_FRAGMENT_REGISTRY, key) || return false
    params, body = _FRAGMENT_REGISTRY[key]
    submap = Dict{Symbol,Any}()
    # α-rename every helper local first; then bind params to the ACTUAL caller argument
    # expressions (a param that is never reassigned is not in `locals`, so this wins).
    locals = Set{Symbol}()
    _collect_assigned!(locals, body)
    for l in locals
        submap[l] = gensym(l)
    end
    for (p, a) in zip(params, args)
        p in locals || (submap[p] = a)
    end
    newbody = _subst(body, submap)
    _inline_walk!(ctx, string(name), newbody)
    return true
end

# Inline a precondition-recursion call. Returns false when the call does not match the
# `precondition(EvtType(cargs...), caller_state)` shape (so the caller falls through);
# errors when the shape matches but the callee is undefined / unregistered / wrong arity.
function _try_inline_precondition!(ctx::_WalkCtx, expr, args)
    length(args) == 2 || return false
    ctor = args[1]
    (ctor isa Expr && ctor.head === :call) || return false
    evtname = _callee_name(ctor.args[1])
    evtname === nothing && return false
    # The second argument must be the caller's own state (the recursion threads it through).
    _access_root(_resolve(args[2], ctx.aliases)) === ctx.statesym || return false
    cargs = ctor.args[2:end]
    if !isdefined(ctx.mod, evtname)
        error(
            "@precondition: cannot inline `precondition($evtname(...), ...)`: event type " *
            "`$evtname` is not defined in $(ctx.mod). Define it before the calling precondition.",
        )
    end
    key = (ctx.mod, :precondition, evtname)
    haskey(_PRECOND_REGISTRY, key) || error(
        "@precondition: cannot inline `precondition($evtname(...), ...)`: no @precondition is " *
        "registered for `$evtname`. Define `@precondition precondition(evt::$evtname, state)` " *
        "before the precondition that calls it.",
    )
    T = getfield(ctx.mod, evtname)
    fnames = fieldnames(T)
    if length(cargs) != length(fnames)
        error(
            "@precondition: recursion `precondition($evtname(...), ...)` passes $(length(cargs)) " *
            "constructor argument(s) but `$evtname` has $(length(fnames)) field(s) $(fnames). " *
            "Only the default positional constructor is supported.",
        )
    end
    evtsym_c, statesym_c, body = _PRECOND_REGISTRY[key]
    fieldmap = Dict{Symbol,Any}()
    for (f, ca) in zip(fnames, cargs)
        fieldmap[f] = ca
    end
    symmap = Dict{Symbol,Any}(statesym_c => args[2])
    locals = Set{Symbol}()
    _collect_assigned!(locals, body)
    for l in locals
        symmap[l] = gensym(l)
    end
    newbody = _subst_precond(body, evtsym_c, fieldmap, symmap)
    _inline_walk!(ctx, "precondition($evtname)", newbody)
    return true
end

# Walk an inlined (already substituted + α-renamed) body in a nested scope, enforcing the
# depth bound and cycle detection. Helper locals do not leak; caller aliases stay visible
# so substituted arguments referencing them still resolve as state reads.
function _inline_walk!(ctx::_WalkCtx, framename::String, body)
    if framename in ctx.stack
        error(
            "recursive @fragment inlining: " *
            join(vcat(ctx.stack, framename), " -> ") *
            ". A precondition cannot inline itself (directly or through a cycle).",
        )
    end
    ctx.depth < _INLINE_DEPTH_LIMIT || error(
        "$(_walker_macro_name(ctx)): inlining exceeded depth $(_INLINE_DEPTH_LIMIT) " *
        "(stack: $(join(vcat(ctx.stack, framename), " -> "))).",
    )
    push!(ctx.stack, framename)
    ctx.depth += 1
    _scoped_block!(ctx, body)
    ctx.depth -= 1
    pop!(ctx.stack)
    return nothing
end

# A state access chain rooted (via alias) at the state symbol, else nothing.
function _state_chain(expr, ctx::_WalkCtx)
    r = _access_root(expr)
    if r === ctx.statesym || (r isa Symbol && haskey(ctx.aliases, r))
        return _resolve(expr, ctx.aliases)
    end
    return nothing
end

function _walk_whitelisted!(ctx::_WalkCtx, name::Symbol, args, expr)
    if name in (:haskey, :get, :get!)
        container = args[1]
        key = length(args) >= 2 ? args[2] : nothing
        chain = _state_chain(container, ctx)
        if chain !== nothing && key !== nothing
            _record_key_read!(ctx, container, key, string(expr))
            _walk!(ctx, key)
        else
            for a in args
                _walk!(ctx, a)
            end
        end
        # `get`/`get!` default argument
        length(args) >= 3 && _walk!(ctx, args[3])
        return nothing
    elseif name in (:in, :∈)
        x = args[1]
        coll = args[2]
        if coll isa Expr &&
            coll.head === :call &&
            _callee_name(coll.args[1]) === :keys &&
            _state_chain(coll.args[2], ctx) !== nothing
            # `x ∈ keys(state.dict)` is a per-key read, same as haskey.
            _record_key_read!(ctx, coll.args[2], x, string(expr))
            _walk!(ctx, x)
        else
            chain = _state_chain(coll, ctx)
            if chain !== nothing
                # `x ∈ state.c.leaf_set` (or a state container): read that address.
                _record_read!(ctx, chain, string(coll))
                _walk!(ctx, x)
            else
                _walk!(ctx, x)
                _walk!(ctx, coll)
            end
        end
        return nothing
    elseif name in (:length, :isempty, :keys, :values, :pairs)
        # Whole-container read outside a loop range: allowed only if a tainted
        # trigger covers the container (see the covering check below).
        container = args[1]
        chain = _state_chain(container, ctx)
        if chain !== nothing
            ms = _container_matchstr(chain, ctx.statesym)
            push!(ctx.whole_reads, (ms[1], string(expr)))
        else
            for a in args
                _walk!(ctx, a)
            end
        end
        return nothing
    elseif name in (:eachindex, :lastindex, :firstindex, :axes)
        # Extent read on a fixed-extent container: sound, no ReadSpec. Still walk
        # non-state arguments for nested reads.
        for a in args
            _state_chain(a, ctx) === nothing && _walk!(ctx, a)
        end
        return nothing
    end
    for a in args
        _walk!(ctx, a)
    end
    return nothing
end

# Range forms in a `for` header. Returns (:index, container_chain) for a
# fixed-extent index loop, (:container, container_chain) for direct iteration of a
# state container, or (:opaque, nothing).
function _range_kind(range, ctx::_WalkCtx)
    if range isa Expr && range.head === :call
        nm = _callee_name(range.args[1])
        if nm === :eachindex && length(range.args) >= 2
            chain = _state_chain(range.args[2], ctx)
            chain !== nothing && return (:index, chain)
        elseif nm === :(:) && length(range.args) == 3
            # `1:length(state.c)` extent index loop.
            hi = range.args[3]
            if hi isa Expr &&
                hi.head === :call &&
                _callee_name(hi.args[1]) === :length &&
                _state_chain(hi.args[2], ctx) !== nothing
                return (:index, _state_chain(hi.args[2], ctx))
            end
        end
    end
    chain = _state_chain(range, ctx)
    chain !== nothing && return (:container, chain)
    return (:opaque, nothing)
end

# Destructured loop variables that alias/derive from an iterated container become
# tainted: the value var aliases an element at an unknown key; key parts are
# opaque locals (tainted when used as indices). Scope is restored by the caller's
# snapshot, so these just mutate ctx in place.
function _bind_container_vars!(ctx::_WalkCtx, var, chain)
    tainted_el = Expr(:ref, chain, _TAINT)
    if var isa Symbol
        ctx.aliases[var] = tainted_el
        delete!(ctx.evt_locals, var)
    elseif var isa Expr && var.head === :tuple && length(var.args) == 2
        # (key, value) dict iteration: value aliases the element; key is opaque.
        val = var.args[2]
        if val isa Symbol
            ctx.aliases[val] = tainted_el
            delete!(ctx.evt_locals, val)
        end
        _forget_var!(ctx, var.args[1])
    else
        _forget_var!(ctx, var)
    end
    return nothing
end

function _forget_var!(ctx::_WalkCtx, var)
    if var isa Symbol
        delete!(ctx.aliases, var)
        delete!(ctx.evt_locals, var)
    elseif var isa Expr && var.head === :tuple
        for v in var.args
            _forget_var!(ctx, v)
        end
    end
    return nothing
end

# Scope snapshot/restore, overridable so `_FireCtx` also saves its stochastic/
# `when` local sets. The read-pass `_TaintCtx` saves aliases + evt_locals only.
_scope_snapshot(ctx::_WalkCtx) = (copy(ctx.aliases), copy(ctx.evt_locals))
function _scope_restore!(ctx::_WalkCtx, snap)
    (ctx.aliases, ctx.evt_locals) = snap
    return nothing
end

# Macro name used in walker error strings, so `@fire`'s messages don't claim to
# be `@precondition`. Overridden by `_FireCtx`.
_walker_macro_name(::_WalkCtx) = "@precondition"

# Run `block` in a nested scope: local aliases/evt-locals created inside do not
# leak out (a straight-line alias assigned inside a loop or branch is valid only
# within it, and reads through it are tracked there — tainted when the alias index
# is loop-derived).
function _scoped_block!(ctx::_WalkCtx, block)
    snap = _scope_snapshot(ctx)
    _walk_block!(ctx, block)
    _scope_restore!(ctx, snap)
    return nothing
end

function _walk_if!(ctx::_WalkCtx, expr)
    _walk!(ctx, expr.args[1])            # condition
    _scoped_block!(ctx, expr.args[2])    # then-branch
    if length(expr.args) >= 3
        els = expr.args[3]
        if els isa Expr && (els.head === :elseif || els.head === :if)
            _walk_if!(ctx, els)
        else
            _scoped_block!(ctx, els)
        end
    end
    return nothing
end

function _walk_for!(ctx::_WalkCtx, expr)
    header = expr.args[1]
    body = expr.args[2]
    (header isa Expr && header.head === :(=)) || (
        for a in expr.args
            ;
            _walk!(ctx, a);
        end;
        return nothing
    )
    var = header.args[1]
    range = header.args[2]
    kind, chain = _range_kind(range, ctx)
    snap = _scope_snapshot(ctx)
    if kind === :index
        _forget_var!(ctx, var)           # index var is opaque -> tainted when used
    elseif kind === :container
        push!(ctx.iterated, _container_matchstr(chain, ctx.statesym))
        _bind_container_vars!(ctx, var, chain)
    else
        _walk!(ctx, range)
        _forget_var!(ctx, var)
    end
    _walk_block!(ctx, body)
    _scope_restore!(ctx, snap)
    return nothing
end

function _walk_generator!(ctx::_WalkCtx, gen)
    # gen: Expr(:generator, body, iterspec...) where iterspec is `var = range` or
    # Expr(:filter, cond, var=range...).
    gen isa Expr || (_walk!(ctx, gen); return nothing)
    body = gen.args[1]
    iterspecs = gen.args[2:end]
    snap = _scope_snapshot(ctx)
    conds = Any[]
    for spec in iterspecs
        if spec isa Expr && spec.head === :filter
            append!(conds, spec.args[1:(end - 1)])
            _bind_iter!(ctx, spec.args[end])
        else
            _bind_iter!(ctx, spec)
        end
    end
    for c in conds
        _walk!(ctx, c)
    end
    _walk!(ctx, body)
    _scope_restore!(ctx, snap)
    return nothing
end

function _bind_iter!(ctx::_WalkCtx, spec)
    (spec isa Expr && spec.head === :(=)) || return _walk!(ctx, spec)
    var = spec.args[1]
    range = spec.args[2]
    kind, chain = _range_kind(range, ctx)
    if kind === :index
        _forget_var!(ctx, var)
    elseif kind === :container
        push!(ctx.iterated, _container_matchstr(chain, ctx.statesym))
        _bind_container_vars!(ctx, var, chain)
    else
        _walk!(ctx, range)
        _forget_var!(ctx, var)
    end
    return nothing
end

# Statement sequence. An assignment binds a scoped local: a state-access RHS makes
# a (possibly tainted) alias, an evt-pure RHS makes an evt-local, else the local is
# opaque. Alias scope is bounded by the enclosing loop/branch (see _scoped_block!).
function _walk_block!(ctx::_WalkCtx, block)
    stmts = block isa Expr && block.head === :block ? block.args : Any[block]
    for stmt in stmts
        stmt isa LineNumberNode && continue
        if stmt isa Expr && stmt.head === :(=)
            _walk_assign!(ctx, stmt)
        else
            _walk!(ctx, stmt)
        end
    end
    return nothing
end

function _walk_assign!(ctx::_WalkCtx, stmt)
    lhs = stmt.args[1]
    rhs = stmt.args[2]
    if !(lhs isa Symbol)
        # Tuple destructuring / field assignment: walk RHS, make bare LHS names opaque.
        _walk!(ctx, rhs)
        _forget_var!(ctx, lhs)
        return nothing
    end
    resolved = _resolve(rhs, ctx.aliases)
    if _access_root(resolved) === ctx.statesym
        ctx.aliases[lhs] = resolved
        delete!(ctx.evt_locals, lhs)
        for idx in _index_subexprs(rhs)
            _walk!(ctx, idx)
        end
    elseif _is_evt_pure(rhs, ctx)
        ctx.evt_locals[lhs] = rhs
        delete!(ctx.aliases, lhs)
    else
        _walk!(ctx, rhs)
        delete!(ctx.aliases, lhs)
        delete!(ctx.evt_locals, lhs)
    end
    return nothing
end

function _fragment_error(ctx::_WalkCtx, callexpr, arg)
    return """
    $(_walker_macro_name(ctx)): cannot derive generators — the call `$(callexpr)` passes state
    (`$(arg)`) to an opaque function, which hides the reads it performs. Inline the
    helper into the precondition, or write generators by hand with @conditionsfor.
    """
end

"""
    _derive_readspecs(body, statesym, evtsym) -> (specs, notes)

Run the taint pass over a precondition body and return the derived `ReadSpec`s.
Throws (macro-time) on out-of-fragment constructs, uncovered whole-container
reads, and zero-read preconditions.
"""
function _derive_readspecs(body, statesym::Symbol, evtsym::Symbol, mod=nothing)
    ctx = _TaintCtx(statesym, evtsym, mod)
    _walk_block!(ctx, body)
    for (cmember, src) in ctx.whole_reads
        covered =
            any(
                s -> !spec_clean(s) && !isempty(s.matchstr) && s.matchstr[1] == cmember, ctx.reads
            ) || any(m -> !isempty(m) && m[1] == cmember, ctx.iterated)
        covered || error("""
            @precondition: whole-container read `$src` of `$(cmember)` has no covering
            trigger. A dict length/keys/values read is only sound when some element of
            the same container is also read with a widened (tainted) key. Use manual
            @conditionsfor instead.
            """)
    end
    isempty(ctx.reads) && error("""
        @precondition: this precondition reads no physical state, so no generators can
        be derived (e.g. a purely fired-triggered event). Write generators by hand with
        @conditionsfor.
        """)
    return ctx.reads, ctx.notes
end

########################### Trigger planning (dedup/merge) ###########################

struct _TriggerPlan
    matchstr::Vector{Any}
    widened::Bool
    reason::String
    bindsets::Vector{Any}    # clean only: list of distinct `indices` vectors
    sources::Vector{String}
end

function _plan_triggers(specs)
    plans = _TriggerPlan[]
    order = Vector{Any}[]
    groups = Dict{Int,Vector{ReadSpec}}()
    for s in specs
        gi = findfirst(m -> _matchstr_equal(m, s.matchstr), order)
        if gi === nothing
            push!(order, s.matchstr)
            groups[length(order)] = ReadSpec[s]
        else
            push!(groups[gi], s)
        end
    end
    for (i, matchstr) in enumerate(order)
        group = groups[i]
        sources = String[s.source for s in group]
        tainted = findfirst(s -> !spec_clean(s), group)
        if tainted !== nothing
            reason = "tainted index in read `$(group[tainted].source)`"
            push!(plans, _TriggerPlan(matchstr, true, reason, Any[], sources))
        else
            distinct = Any[]
            for s in group
                any(bs -> _indices_equal(bs, s.indices), distinct) || push!(distinct, s.indices)
            end
            push!(plans, _TriggerPlan(matchstr, false, "", distinct, sources))
        end
    end
    return plans
end

_collect_bound!(out, ix::FieldBinding) = (push!(out, ix.field); nothing)
function _collect_bound!(out, ix::TupleIndex)
    (foreach(c -> _collect_bound!(out, c), ix.components); nothing)
end
_collect_bound!(out, ::Any) = nothing

function _bound_fields(indices)
    out = Symbol[]
    for ix in indices
        _collect_bound!(out, ix)
    end
    return out
end

########################### Closure construction (setup time) ###########################

function derived_domain end

function derived_domain_exists(::Type{T}, field::Symbol) where {T}
    hasmethod(derived_domain, Tuple{Type{T},Val{field},Any})
end

# For each index position build guard checks (k, m, value) and field bindings
# (field, k, m). m == 0 reads inds[k]; m >= 1 reads inds[k][m] (tuple index).
function _compile_index!(guards, bindings, k, m, ix::FieldBinding)
    push!(bindings, (ix.field, k, m))
    return nothing
end
function _compile_index!(guards, bindings, k, m, ix::LiteralIndex)
    push!(guards, (k, m, ix.value))
    return nothing
end
_compile_index!(guards, bindings, k, m, ::TaintedIndex) = nothing
function _compile_index!(guards, bindings, k, m, ix::TupleIndex)
    for (mm, c) in enumerate(ix.components)
        _compile_index!(guards, bindings, k, mm, c)
    end
    return nothing
end

function _compile_bindset(indices)
    guards = Tuple{Int,Int,Any}[]
    bindings = Tuple{Symbol,Int,Int}[]
    for (k, ix) in enumerate(indices)
        _compile_index!(guards, bindings, k, 0, ix)
    end
    return (guards, bindings)
end

# Enumerate free fields' domains and generate one event per combination. The
# `domains` dict maps each field that can be free to a resolver closure over
# `physical`, resolved once at setup time (see `derived_generators`) rather than
# dispatched here at loop time. A zero-field event yields exactly one event: the
# `isempty(free)` branch builds `T()` directly (mirroring the empty product of
# zero domains, which yields one empty combination).
function _emit(generate, physical, ::Type{T}, fnames, bound::Dict{Symbol,Any}, domains) where {T}
    free = Symbol[f for f in fnames if !haskey(bound, f)]
    if isempty(free)
        generate(T((bound[f] for f in fnames)...))
    else
        resolved = Tuple(domains[f](physical) for f in free)
        for combo in Iterators.product(resolved...)
            args = map(fnames) do f
                haskey(bound, f) ? bound[f] : combo[findfirst(==(f), free)]
            end
            generate(T(args...))
        end
    end
    return nothing
end

function _make_generator(::Type{T}, fnames, plan::_TriggerPlan, domains) where {T}
    if plan.widened
        return function (generate, physical, inds...)
            _emit(generate, physical, T, fnames, Dict{Symbol,Any}(), domains)
            return nothing
        end
    end
    compiled = [_compile_bindset(bs) for bs in plan.bindsets]
    return function (generate, physical, inds...)
        for (guards, bindings) in compiled
            ok = true
            for (k, m, v) in guards
                got = m == 0 ? inds[k] : inds[k][m]
                if got != v
                    ok = false
                    break
                end
            end
            ok || continue
            bound = Dict{Symbol,Any}()
            for (f, k, m) in bindings
                bound[f] = m == 0 ? inds[k] : inds[k][m]
            end
            _emit(generate, physical, T, fnames, bound, domains)
        end
        return nothing
    end
end

function _needed_domains(fnames, plans)
    needed = Symbol[]
    for p in plans
        if p.widened
            for f in fnames
                f in needed || push!(needed, f)
            end
        else
            for bs in p.bindsets
                bound = _bound_fields(bs)
                for f in fnames
                    (f in bound || f in needed) || push!(needed, f)
                end
            end
        end
    end
    return needed
end

########################### Domain inference (setup time) ###########################

# The MEMBERINDEX position `k` in `indices` corresponds to a `Member` prefix in
# `matchstr` (the path to the container). Container-key inference needs that prefix
# to be a PURE Member path (no intervening MEMBERINDEX): an intervening index means
# the container is itself an element of another container, which is not resolvable
# by a plain getproperty chain against `physical`.

# Does `ix` bind `field`? Return 0 for a whole-key FieldBinding, the 1-based tuple
# component for a TupleIndex component, or `nothing` if `field` is not bound here.
_fieldbinding_component(ix::FieldBinding, field) = ix.field === field ? 0 : nothing
function _fieldbinding_component(ix::TupleIndex, field)
    for (m, c) in enumerate(ix.components)
        c isa FieldBinding && c.field === field && return m
    end
    return nothing
end
_fieldbinding_component(::Any, field) = nothing

# First (spec order, then index-position order, then tuple-component order) clean
# read whose container prefix is a pure Member path and that binds `field`. Returns
# (path::Vector{Symbol}, component) where component == 0 is whole-key, else the
# tuple component index. Deterministic choice rule: earliest in spec order wins.
function _container_key_source(specs, field)
    for s in specs
        spec_clean(s) || continue
        mi_positions = findall(x -> x === MEMBERINDEX, s.matchstr)
        for (k, ix) in enumerate(s.indices)
            m = _fieldbinding_component(ix, field)
            m === nothing && continue
            prefix = @view s.matchstr[1:(mi_positions[k] - 1)]
            all(x -> x isa Member && x !== MEMBERINDEX, prefix) || continue
            return (Symbol[x.name for x in prefix], m)
        end
    end
    return nothing
end

function _resolve_container(physical, path)
    c = physical
    for p in path
        c = getproperty(c, p)
    end
    return c
end

# Whole-key domain: dict keys, or array positions.
_whole_key_domain(c::AbstractDict) = keys(c)
_whole_key_domain(c::AbstractArray) = eachindex(c)
# Tuple-component domain: distinct component `m` of a dict's tuple keys, or the
# axis `m` of an N-D array's index. Dict projection is deduplicated (many keys
# share a component value) to avoid enumerating the same field value repeatedly.
_component_key_domain(c::AbstractDict, m) = unique(k[m] for k in keys(c))
_component_key_domain(c::AbstractArray, m) = axes(c, m)

function _container_key_domain(path, component::Int)
    return function (physical)
        c = _resolve_container(physical, path)
        return component == 0 ? _whole_key_domain(c) : _component_key_domain(c, component)
    end
end

_path_str(path) = isempty(path) ? "physical" : "physical." * join(path, ".")

# Resolve one field's domain by precedence: explicit @domain > container-key
# inference > finite fieldtype. Returns (resolver_or_nothing, provenance_string);
# a `nothing` resolver means MISSING (report the three failed attempts).
function _resolve_field_domain(::Type{T}, field, specs) where {T}
    if derived_domain_exists(T, field)
        return (physical -> derived_domain(T, Val(field), physical), "explicit")
    end
    src = _container_key_source(specs, field)
    if src !== nothing
        path, component = src
        return (_container_key_domain(path, component), "container-key($(_path_str(path)))")
    end
    FT = fieldtype(T, field)
    if FT <: Enum
        return (physical -> instances(FT), "finite-type($FT)")
    elseif FT === Bool
        return (physical -> (false, true), "finite-type(Bool)")
    end
    return (nothing, "MISSING")
end

function _missing_domain_error(::Type{T}, missing_fields, specs) where {T}
    io = IOBuffer()
    println(
        io,
        "derived_generators($(nameof(T))): cannot resolve a domain for field(s) " *
        "$(Tuple(missing_fields)). Each is enumerated when a widened trigger fires but " *
        "none could be inferred:",
    )
    for f in missing_fields
        FT = fieldtype(T, f)
        println(io, "  field `$f`:")
        println(io, "    - no @domain method: derived_domain($(nameof(T)), Val(:$f), ...)")
        println(io, "    - not container-keyed: no clean FieldBinding(:$f) in any read")
        println(io, "    - fieldtype $FT not finite (not <: Enum, not Bool)")
        println(io, "    fix: @domain $(nameof(T)).$f = <expr over physical>")
    end
    return String(take!(io))
end

"""
    derived_generators(EvtType, specs) -> Vector{EventGenerator}

Build place-triggered `EventGenerator`s from the read specs. Called at setup time
(the first `generators()` call). Errors here name the event, the field, and the
exact `@domain` line to add when a free field lacks a domain.
"""
function derived_generators(::Type{T}, specs::Vector{ReadSpec}) where {T}
    plans = _plan_triggers(specs)
    fnames = fieldnames(T)
    # Resolve every field that can be free ONCE here, so the runtime loop dispatches
    # nothing: each resolver is a closure over `physical` (domains may depend on live
    # state size) passed into the generator-building path.
    domains = Dict{Symbol,Function}()
    missing_fields = Symbol[]
    for f in _needed_domains(fnames, plans)
        resolver, _prov = _resolve_field_domain(T, f, specs)
        if resolver === nothing
            push!(missing_fields, f)
        else
            domains[f] = resolver
        end
    end
    isempty(missing_fields) || error(_missing_domain_error(T, missing_fields, specs))
    gens = EventGenerator[]
    for p in plans
        push!(gens, EventGenerator(ToPlace, p.matchstr, _make_generator(T, fnames, p, domains)))
    end
    return gens
end

########################### Macros ###########################

"""
    @precondition function precondition(evt::EvtType, state)
        <body>
    end

Emit the precondition verbatim plus a derived `generators(::Type{EvtType})` method
built by a syntactic taint pass over the body. Out-of-fragment constructs (helper
calls with state arguments, uncovered whole-container dict reads, zero state reads)
error at macro time with an actionable message.
"""
macro precondition(fdef)
    sig, body = _split_funcdef(fdef)
    (sig isa Expr && sig.head === :call) ||
        error("@precondition expects `function precondition(evt::EvtType, state) ... end`")
    length(sig.args) == 3 || error("@precondition: precondition must take (evt::EvtType, state)")
    evt_arg = sig.args[2]
    (evt_arg isa Expr && evt_arg.head === :(::)) ||
        error("@precondition: first argument must be `evt::EventType`")
    evtsym = evt_arg.args[1]::Symbol
    EvtType = evt_arg.args[2]
    state_arg = sig.args[3]
    statesym = state_arg isa Expr && state_arg.head === :(::) ? state_arg.args[1] : state_arg
    statesym isa Symbol || error("@precondition: state argument must be a plain name")

    # Register this precondition BEFORE deriving so a direct self-call is caught as a cycle
    # (not "undefined"), and so later preconditions can inline it via precondition-recursion.
    _PRECOND_REGISTRY[(__module__, :precondition, _evt_name(EvtType))] = (evtsym, statesym, body)

    specs, _notes = _derive_readspecs(body, statesym, evtsym, __module__)

    return Expr(
        :block,
        esc(fdef),
        :(function $(esc(:generators))(::Type{$(esc(EvtType))})
            ChronoSim.derived_generators($(esc(EvtType)), $specs)
        end),
        :(ChronoSim.derivation_spec(::Type{$(esc(EvtType))}) = $specs),
        :(ChronoSim.precondition_ast(::Type{$(esc(EvtType))}) =
            ($(QuoteNode(evtsym)), $(QuoteNode(statesym)), $(QuoteNode(body)))),
    )
end

function _split_funcdef(fdef)
    if fdef isa Expr && fdef.head === :function
        return fdef.args[1], fdef.args[2]
    elseif fdef isa Expr &&
        fdef.head === :(=) &&
        fdef.args[1] isa Expr &&
        fdef.args[1].head === :call
        return fdef.args[1], fdef.args[2]
    else
        error("@precondition expects a function definition")
    end
end

"""
    @fragment function helper(args...)
        <body>
    end

Emit the helper VERBATIM (behavior identical to unmarked) and register its body so a
`@precondition` may CALL it: at derivation time the call is inlined (arguments substituted,
locals α-renamed) instead of treated as opaque, letting the helper's state reads be seen.
Only single-method, positional helpers are supported — type annotations are stripped
(`x::T` -> `x`); varargs, keyword arguments, and default values error here.
"""
macro fragment(fdef)
    sig, _body = _split_funcdef(fdef)
    (sig isa Expr && sig.head === :call) || error(
        "@fragment expects `function name(args...) ... end` (a plain, single-method function)"
    )
    name = sig.args[1]
    name isa Symbol || error("@fragment: helper name must be a plain symbol, got `$name`")
    params = Symbol[_fragment_param(a) for a in sig.args[2:end]]
    body = _body
    _FRAGMENT_REGISTRY[(__module__, name, length(params))] = (params, body)
    return Expr(:block,
        # @__doc__ keeps a preceding docstring attached to the helper now that
        # the expansion is a block rather than the bare function definition.
        :(Base.@__doc__ $(esc(fdef))),
        :(ChronoSim._is_registered_fragment(::typeof($(esc(name)))) = true),
        # Baked accessor for the un-inlined helper source (Phase 4). The
        # compile-time _FRAGMENT_REGISTRY is empty after precompilation.
        :(ChronoSim.fragment_ast(::typeof($(esc(name)))) =
            ($params, $(QuoteNode(body)))),
    )
end

# Extract the bare parameter name, rejecting forms whose inlining semantics are unsupported.
function _fragment_param(a)
    a isa Symbol && return a
    if a isa Expr
        if a.head === :(::)
            length(a.args) == 2 && a.args[1] isa Symbol && return a.args[1]
            error("@fragment: parameter `$a` must be a named argument (`x::T`), not anonymous")
        elseif a.head === :...
            error("@fragment: varargs parameters are not supported (`$a`)")
        elseif a.head === :kw
            error("@fragment: default parameter values are not supported (`$a`)")
        elseif a.head === :parameters
            error("@fragment: keyword arguments are not supported")
        end
    end
    return error("@fragment: unsupported parameter `$a`")
end

"""
    @domain EvtType.field = <expr over `physical`>

Supply the enumeration domain for an event field that a widened trigger cannot
bind. Emits a `derived_domain(::Type{EvtType}, ::Val{:field}, physical)` method.
"""
macro domain(assignment)
    (assignment isa Expr && assignment.head === :(=)) ||
        error("@domain expects `EvtType.field = expr`")
    lhs = assignment.args[1]
    rhs = assignment.args[2]
    (lhs isa Expr && lhs.head === :.) || error("@domain expects `EvtType.field = expr`")
    EvtType = lhs.args[1]
    field = _fieldsym(lhs.args[2])
    return Expr(:block,
        :(
            function ChronoSim.derived_domain(
                ::Type{$(esc(EvtType))}, ::Val{$(QuoteNode(field))}, $(esc(:physical))
            )
                $(esc(rhs))
            end
        ),
        # Baked accessor for the un-inlined domain rhs (Phase 4 / diagnostics).
        :(ChronoSim.domain_ast(::Type{$(esc(EvtType))}, ::Val{$(QuoteNode(field))}) =
            $(QuoteNode(rhs))),
    )
end

########################### Diagnostics report ###########################

_matchstr_str(ms) = "[" * join((x === MEMBERINDEX ? "ℤ" : string(x) for x in ms), ", ") * "]"

function _guards_str(indices)
    parts = String[]
    for (k, ix) in enumerate(indices)
        _guard_str!(parts, k, 0, ix)
    end
    return isempty(parts) ? "none" : join(parts, ", ")
end
function _guard_str!(parts, k, m, ix::LiteralIndex)
    push!(parts, "inds[$k]$(m == 0 ? "" : "[$m]") == $(ix.value)")
end
function _guard_str!(parts, k, m, ix::TupleIndex)
    foreach(((mm, c),) -> _guard_str!(parts, k, mm, c), enumerate(ix.components))
end
_guard_str!(parts, k, m, ::Any) = nothing

"""
    derivation_report([io], EvtType)

Human-readable dump of the derived triggers: each trigger's matchstr, whether it
is CLEAN (with the fields it binds and any literal guards) or WIDENED (with the
reason), plus per-field domain accounting.
"""
function derivation_report(io::IO, ::Type{T}) where {T}
    fnames = fieldnames(T)
    println(io, "Derivation report for $(nameof(T))")
    println(io, "  event fields: $(isempty(fnames) ? "()" : join(fnames, ", "))")
    # Read side (`@precondition`). Hand-written events have no `derivation_spec`;
    # print a note rather than crash so the report also serves `@fire`-only events.
    if hasmethod(derivation_spec, Tuple{Type{T}})
        specs = derivation_spec(T)
        plans = _plan_triggers(specs)
        for p in plans
            if p.widened
                println(io, "  TRIGGER $(_matchstr_str(p.matchstr))  WIDENED")
                println(io, "    reason: $(p.reason)")
                println(
                    io,
                    "    enumerates domains for: $(isempty(fnames) ? "()" : join(fnames, ", "))",
                )
            else
                println(io, "  TRIGGER $(_matchstr_str(p.matchstr))  CLEAN")
                for bs in p.bindsets
                    bound = _bound_fields(bs)
                    free = Symbol[f for f in fnames if !(f in bound)]
                    println(io, "    binds: $(isempty(bound) ? "()" : join(bound, ", "))")
                    println(io, "    guards: $(_guards_str(bs))")
                    isempty(free) || println(io, "    free (enumerated): $(join(free, ", "))")
                end
            end
        end
        needed = _needed_domains(fnames, plans)
        if isempty(needed)
            println(io, "  domains required: none (every field bound by a clean read)")
        else
            for f in needed
                _resolver, prov = _resolve_field_domain(T, f, specs)
                println(io, "  domain $(nameof(T)).$(f): $prov")
            end
        end
    else
        println(io, "  triggers: none derived (hand-written generators)")
    end
    # Write side (`@fire`). Present only for `@fire`-annotated events.
    if hasmethod(effect_spec, Tuple{Type{T}})
        _writes_report(io, effect_spec(T))
    end
    return nothing
end

# The WRITES section of `derivation_report`, driven by the `EffectSpec` that
# `@fire` derived. `es` is `effect_spec(T)`. Reports each write site's mask,
# index cleanliness (CLEAN/WIDENED, with the widened-write count as the
# over-approximation counter), operation, and rhs classification, then the rhs
# mix and (bounded) walker notes.
function _writes_report(io::IO, es)
    println(io, "  WRITES ($(length(es.writes)) sites, $(es.widened_writes) widened)")
    mix = Dict{Symbol,Int}()
    for w in es.writes
        mix[w.rhs] = get(mix, w.rhs, 0) + 1
        ms = _matchstr_str(w.matchstr) * (w.subtree ? ".*" : "")
        if spec_clean(w)
            bound = _bound_fields(w.indices)
            bindstr = isempty(bound) ? "" : "  binds: $(join(bound, ", "))"
            println(io, "    WRITE $(ms)  CLEAN$(bindstr)  op: $(w.op)  rhs: $(w.rhs)")
        else
            println(
                io,
                "    WRITE $(ms)  WIDENED (tainted index in `$(w.source)`)" *
                "  op: $(w.op)  rhs: $(w.rhs)",
            )
        end
    end
    println(
        io,
        "  rhs mix: evt_pure $(get(mix, :evt_pure, 0)), state_expr $(get(mix, :state_expr, 0)), " *
        "stochastic $(get(mix, :stochastic, 0)), opaque $(get(mix, :opaque, 0))",
    )
    if !isempty(es.notes)
        shown = Iterators.take(es.notes, 5)
        println(io, "  notes: $(join(shown, "; "))" *
            (length(es.notes) > 5 ? " (+$(length(es.notes) - 5) more)" : ""))
    end
    return nothing
end

derivation_report(::Type{T}) where {T} = derivation_report(stdout, T)
