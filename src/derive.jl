# Deriving event generators from precondition source.
#
# `@precondition` runs a syntactic taint pass over a precondition body at macro
# time, producing `ReadSpec` literals. At setup time (first `generators()` call)
# `derived_generators` turns those specs into `EventGenerator` closures that are
# drop-in equivalents of hand-written `@conditionsfor`/`@reactto` generators, so
# the runtime (GeneratorSearch, over_generated_events) is untouched.
#
# See scratchpad/phase3_design.md for the authoritative design.

export @precondition, @domain, derivation_report

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

########################### Taint pass ###########################

mutable struct _TaintCtx
    statesym::Symbol
    evtsym::Symbol
    aliases::Dict{Symbol,Any}      # local -> resolved state access chain (rooted at statesym)
    evt_locals::Dict{Symbol,Any}   # local -> evt-pure expr it was bound to
    reads::Vector{ReadSpec}
    notes::Vector{String}
    iterated::Vector{Vector{Any}}  # matchstrs of iterated containers (cover whole-container reads)
    whole_reads::Vector{Tuple{Any,String}}  # (container Member, source) needing a covering trigger
end

function _TaintCtx(statesym, evtsym)
    _TaintCtx(
        statesym,
        evtsym,
        Dict{Symbol,Any}(),
        Dict{Symbol,Any}(),
        ReadSpec[],
        String[],
        Vector{Any}[],
        Tuple{Any,String}[],
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

function _is_evt_pure(x, ctx::_TaintCtx)
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

_contains_state(a, ctx::_TaintCtx) = _has_state_access(_resolve(a, ctx.aliases), ctx.statesym)

function _classify_index(ctx::_TaintCtx, idx)
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

function _record_read!(ctx::_TaintCtx, resolved_access, source)
    stripped = _strip_state_head(resolved_access, ctx.statesym)
    matchstr = access_to_searchkey(stripped)
    argnames = access_to_argnames(stripped)
    indices = Any[_classify_index(ctx, idx) for idx in argnames]
    push!(ctx.reads, ReadSpec(matchstr, indices, source))
    return nothing
end

# Record `container[key]` as a read (haskey/get/get!/∈ per-key form).
function _record_key_read!(ctx::_TaintCtx, container, key, source)
    resolved = Expr(:ref, _resolve(container, ctx.aliases), key)
    _record_read!(ctx, resolved, source)
    return nothing
end

function _walk!(ctx::_TaintCtx, expr)
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

function _walk_call!(ctx::_TaintCtx, expr)
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
    # Opaque user function: a state-derived argument hides reads -> out of fragment.
    for a in args
        if _contains_state(a, ctx)
            error(_fragment_error(expr, a))
        end
    end
    for a in args
        _walk!(ctx, a)
    end
    return nothing
end

# A state access chain rooted (via alias) at the state symbol, else nothing.
function _state_chain(expr, ctx::_TaintCtx)
    r = _access_root(expr)
    if r === ctx.statesym || (r isa Symbol && haskey(ctx.aliases, r))
        return _resolve(expr, ctx.aliases)
    end
    return nothing
end

function _walk_whitelisted!(ctx::_TaintCtx, name::Symbol, args, expr)
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
function _range_kind(range, ctx::_TaintCtx)
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
function _bind_container_vars!(ctx::_TaintCtx, var, chain)
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

function _forget_var!(ctx::_TaintCtx, var)
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

# Run `block` in a nested scope: local aliases/evt-locals created inside do not
# leak out (a straight-line alias assigned inside a loop or branch is valid only
# within it, and reads through it are tracked there — tainted when the alias index
# is loop-derived).
function _scoped_block!(ctx::_TaintCtx, block)
    saved_aliases = copy(ctx.aliases)
    saved_evt = copy(ctx.evt_locals)
    _walk_block!(ctx, block)
    ctx.aliases = saved_aliases
    ctx.evt_locals = saved_evt
    return nothing
end

function _walk_if!(ctx::_TaintCtx, expr)
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

function _walk_for!(ctx::_TaintCtx, expr)
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
    saved_aliases = copy(ctx.aliases)
    saved_evt = copy(ctx.evt_locals)
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
    ctx.aliases = saved_aliases
    ctx.evt_locals = saved_evt
    return nothing
end

function _walk_generator!(ctx::_TaintCtx, gen)
    # gen: Expr(:generator, body, iterspec...) where iterspec is `var = range` or
    # Expr(:filter, cond, var=range...).
    gen isa Expr || (_walk!(ctx, gen); return nothing)
    body = gen.args[1]
    iterspecs = gen.args[2:end]
    saved_aliases = copy(ctx.aliases)
    saved_evt = copy(ctx.evt_locals)
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
    ctx.aliases = saved_aliases
    ctx.evt_locals = saved_evt
    return nothing
end

function _bind_iter!(ctx::_TaintCtx, spec)
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
function _walk_block!(ctx::_TaintCtx, block)
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

function _walk_assign!(ctx::_TaintCtx, stmt)
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

function _fragment_error(callexpr, arg)
    return """
    @precondition: cannot derive generators — the call `$(callexpr)` passes state
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
function _derive_readspecs(body, statesym::Symbol, evtsym::Symbol)
    ctx = _TaintCtx(statesym, evtsym)
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

# Enumerate free fields' domains and generate one event per combination.
function _emit(generate, physical, ::Type{T}, fnames, bound::Dict{Symbol,Any}) where {T}
    free = Symbol[f for f in fnames if !haskey(bound, f)]
    if isempty(free)
        generate(T((bound[f] for f in fnames)...))
    else
        domains = Tuple(derived_domain(T, Val(f), physical) for f in free)
        for combo in Iterators.product(domains...)
            args = map(fnames) do f
                haskey(bound, f) ? bound[f] : combo[findfirst(==(f), free)]
            end
            generate(T(args...))
        end
    end
    return nothing
end

function _make_generator(::Type{T}, fnames, plan::_TriggerPlan) where {T}
    if plan.widened
        return function (generate, physical, inds...)
            _emit(generate, physical, T, fnames, Dict{Symbol,Any}())
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
            _emit(generate, physical, T, fnames, bound)
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

"""
    derived_generators(EvtType, specs) -> Vector{EventGenerator}

Build place-triggered `EventGenerator`s from the read specs. Called at setup time
(the first `generators()` call). Errors here name the event, the field, and the
exact `@domain` line to add when a free field lacks a domain.
"""
function derived_generators(::Type{T}, specs::Vector{ReadSpec}) where {T}
    plans = _plan_triggers(specs)
    fnames = fieldnames(T)
    missing_domains = Symbol[
        f for f in _needed_domains(fnames, plans) if !derived_domain_exists(T, f)
    ]
    if !isempty(missing_domains)
        lines = join(
            ["  @domain $(nameof(T)).$(f) = <expr over physical>" for f in missing_domains], "\n"
        )
        error("""
            derived_generators($(nameof(T))): field(s) $(Tuple(missing_domains)) are not
            bound by any clean field-keyed read (they are enumerated when a widened trigger
            fires), so each needs a domain. Add:
            $lines
            """)
    end
    gens = EventGenerator[]
    for p in plans
        push!(gens, EventGenerator(ToPlace, p.matchstr, _make_generator(T, fnames, p)))
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

    specs, _notes = _derive_readspecs(body, statesym, evtsym)

    return Expr(
        :block,
        esc(fdef),
        :(
            function $(esc(:generators))(::Type{$(esc(EvtType))})
                ChronoSim.derived_generators($(esc(EvtType)), $specs)
            end
        ),
        :(ChronoSim.derivation_spec(::Type{$(esc(EvtType))}) = $specs),
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
    return :(
        function ChronoSim.derived_domain(
            ::Type{$(esc(EvtType))}, ::Val{$(QuoteNode(field))}, $(esc(:physical))
        )
            $(esc(rhs))
        end
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
    specs = derivation_spec(T)
    plans = _plan_triggers(specs)
    fnames = fieldnames(T)
    println(io, "Derivation report for $(nameof(T))")
    println(io, "  event fields: $(isempty(fnames) ? "()" : join(fnames, ", "))")
    for p in plans
        if p.widened
            println(io, "  TRIGGER $(_matchstr_str(p.matchstr))  WIDENED")
            println(io, "    reason: $(p.reason)")
            println(
                io, "    enumerates domains for: $(isempty(fnames) ? "()" : join(fnames, ", "))"
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
            mark = derived_domain_exists(T, f) ? "ok" : "MISSING"
            println(io, "  domain $(nameof(T)).$(f): $mark")
        end
    end
    return nothing
end

derivation_report(::Type{T}) where {T} = derivation_report(stdout, T)
