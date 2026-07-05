# Deriving event EFFECTS (writes) from `fire!` source — the write-side mirror of
# derive.jl's `@precondition` read pass.
#
# `@fire` emits the `fire!` method verbatim (analysis-only: byte-identical runtime
# behavior) and runs a syntactic taint pass over the body — reusing derive.jl's
# `_WalkCtx` traversal by dispatch — to produce `WriteSpec`s. The derived
# `EffectSpec` is exposed as a baked `effect_spec(EvtType)` method (the compile-time
# `_FIRE_REGISTRY` is empty at runtime for precompiled packages, Amendment 1), and
# checked at runtime by the `CheckEffects` policy (effect_coverage.jl). `@fire` also
# bakes `fire_ast(EvtType)` with the ORIGINAL un-inlined body for Phase 4.
#
# See .claude/design/phase2_design.md for the authoritative design.

export @fire, effect_spec

public can_stop_change, StopWriteAnalysis, WriteSpec, EffectSpec, fire_ast

########################### Write-spec data model ###########################

"""
    WriteSpec

One static write site derived from a `@fire` body. Mirrors [`ReadSpec`](@ref) with
the effect payload Phases 3 (interference lints) and 4 (Quint effect lowering)
consume.

Fields: `matchstr`/`indices` use the same alphabet as `ReadSpec` (`Member`,
`MEMBERINDEX`; `FieldBinding`/`LiteralIndex`/`TaintedIndex`/`TupleIndex`);
`subtree` is `true` for whole-element ops (a compound `setindex!`/`@obswrite`
container write) that cover this address and every descendant; `op` is the
mutation kind; `rhs` is the value classification
(`:evt_pure | :state_expr | :stochastic | :opaque`); `rhs_ast` is the always-kept
alias-resolved rhs (or the mutator call) for Phase 4; `source` is the statement
text for diagnostics.
"""
struct WriteSpec
    matchstr::Vector{Any}
    indices::Vector{Any}
    subtree::Bool
    op::Symbol
    rhs::Symbol
    rhs_ast::Any
    source::String
end

write_mask(w::WriteSpec) = placekey_mask_index(w.matchstr)
spec_clean(w::WriteSpec) = all(index_clean, w.indices)

"""
    EffectSpec

Everything `@fire` derived for one event type. `writes` are the static write
sites; `reads` are the body's state reads (free information — no covering-trigger
or zero-read discipline applies to them); `widened_writes` counts writes with any
`TaintedIndex` (the over-approximation counter); `notes` records widening reasons,
opaque-call sightings, `when`-demotions, and alias-staleness demotions.
"""
struct EffectSpec
    writes::Vector{WriteSpec}
    reads::Vector{ReadSpec}
    widened_writes::Int
    notes::Vector{String}
end

"""
    effect_spec(::Type{EvtType}) -> EffectSpec

The static effect specification derived by [`@fire`](@ref). Defined only for
`@fire`-annotated event types (consumers `hasmethod`-gate).
"""
function effect_spec end

"""
    fire_ast(::Type{EvtType}) -> (evtsym, statesym, whensym, rngsym, body)

The ORIGINAL un-inlined `fire!` body (a `QuoteNode` literal at macro time) plus
its argument names, baked as a runtime method (the compile-time `_FIRE_REGISTRY`
is empty after precompilation). Phase 4's effect lowering consumes it.
"""
function fire_ast end

# (module, :fire, EvtName) -> (evtsym, statesym, whensym, rngsym, body). Populated
# at macro-expansion time (module-keyed, overwrite-on-reregister, Revise-friendly);
# consumed by fire!-recursion inlining during the walk of a later `@fire` body.
const _FIRE_REGISTRY = Dict{Tuple{Module,Symbol,Symbol},NTuple{5,Any}}()

# Structural equality for dedup/merge (mirrors _idx_equal/_indices_equal): two
# writes merge when all fields except source agree — INCLUDING rhs_ast, since
# Phase 4's contract is that every distinct rhs AST is preserved (e.g. Travel's
# `cnt -= 1` and `cnt += 1` share a mask but must both survive).
function _write_equal(a::WriteSpec, b::WriteSpec)
    return _matchstr_equal(a.matchstr, b.matchstr) &&
           _indices_equal(a.indices, b.indices) &&
           a.subtree == b.subtree && a.op == b.op && a.rhs == b.rhs &&
           a.rhs_ast == b.rhs_ast
end

function _dedup_writes(writes)
    out = WriteSpec[]
    for w in writes
        j = findfirst(o -> _write_equal(o, w), out)
        if j === nothing
            push!(out, w)
        else
            o = out[j]
            newsrc = o.source == w.source ? o.source : string(o.source, " | ", w.source)
            out[j] = WriteSpec(o.matchstr, o.indices, o.subtree, o.op, o.rhs, o.rhs_ast, newsrc)
        end
    end
    return out
end

########################### The write walker: _FireCtx ###########################

mutable struct _FireCtx <: _WalkCtx
    # shared with _TaintCtx (same meaning, derive.jl)
    statesym::Symbol
    evtsym::Symbol
    aliases::Dict{Symbol,Any}
    evt_locals::Dict{Symbol,Any}
    reads::Vector{ReadSpec}
    notes::Vector{String}
    iterated::Vector{Vector{Any}}
    whole_reads::Vector{Tuple{Any,String}}   # collected but NOT enforced (no covering check)
    mod::Union{Module,Nothing}
    depth::Int
    stack::Vector{String}
    # fire-only
    whensym::Symbol
    rngsym::Symbol
    writes::Vector{WriteSpec}
    stoch_locals::Set{Symbol}      # locals bound to a :stochastic rhs
    when_locals::Set{Symbol}       # locals whose binding rhs contains `when`
    written_masks::Vector{Any}     # masks of state addresses written earlier (staleness)
end

function _FireCtx(statesym, evtsym, whensym, rngsym, mod=nothing)
    _FireCtx(
        statesym, evtsym, Dict{Symbol,Any}(), Dict{Symbol,Any}(), ReadSpec[], String[],
        Vector{Any}[], Tuple{Any,String}[], mod, 0, String[],
        whensym, rngsym, WriteSpec[], Set{Symbol}(), Set{Symbol}(), Any[],
    )
end

# Scope overrides: also save/restore the stochastic/when local sets. (written_masks
# is deliberately NOT scoped — a write under a branch is a may-write for the body.)
_scope_snapshot(ctx::_FireCtx) =
    (copy(ctx.aliases), copy(ctx.evt_locals), copy(ctx.stoch_locals), copy(ctx.when_locals))
function _scope_restore!(ctx::_FireCtx, snap)
    (ctx.aliases, ctx.evt_locals, ctx.stoch_locals, ctx.when_locals) = snap
    return nothing
end
_walker_macro_name(::_FireCtx) = "@fire"

_fire_error(msg) = error(msg)
_short(e) = (s = string(e); length(s) > 70 ? first(s, 70) * "…" : s)

########################### rhs classification ###########################

const _RAND_NAMES = Set{Symbol}([
    :rand, :randn, :randexp, :rand!, :randn!, :sample, :shuffle, :shuffle!,
    :randperm, :randsubseq, :randstring,
])

# Read-transparent calls allowed inside a :state_expr rhs (pure over state/literals).
const _RHS_PURE = union(
    _ARITH_BOOL_OPS, _WHITELIST,
    Set{Symbol}([
        :log, :exp, :sqrt, :floor, :ceil, :round, :trunc, :ifelse, :Set, :collect,
        :Tuple, :first, :last, :sort, :unique, :setdiff, :union, :intersect,
        :symdiff, :count, :sum, :minimum, :maximum, :(:),
    ]),
)

# A free Symbol that is a module-level const literal (enum instances like
# `Stationary`, `working`; numeric/string consts) counts as an evt-pure atom.
function _is_module_const(ctx::_FireCtx, s::Symbol)
    ctx.mod === nothing && return false
    isdefined(ctx.mod, s) || return false
    isconst(ctx.mod, s) || return false
    v = getfield(ctx.mod, s)
    return v isa Union{Number,Bool,Char,Symbol,String,Enum}
end

# _is_evt_pure extended with module-const values (used for rhs classification).
function _is_evt_pure_ext(x, ctx::_FireCtx)
    _is_literal(x) && return true
    if x isa Symbol
        haskey(ctx.evt_locals, x) && return true
        return _is_module_const(ctx, x)
    end
    if x isa Expr
        if x.head === :. && x.args[1] === ctx.evtsym
            return true
        elseif x.head === :. || x.head === :ref
            return false
        elseif x.head === :call
            return all(a -> _is_evt_pure_ext(a, ctx), x.args[2:end])
        else
            return all(a -> _is_evt_pure_ext(a, ctx), x.args)
        end
    end
    return false
end

# Purely syntactic scans (applied before anything else in classification order).
function _rhs_has_stoch(ctx::_FireCtx, e)
    e === ctx.rngsym && return true
    if e isa Symbol
        return e in ctx.stoch_locals
    elseif e isa Expr
        if e.head === :call
            nm = _callee_name(e.args[1])
            nm !== nothing && nm in _RAND_NAMES && return true
        end
        return any(a -> _rhs_has_stoch(ctx, a), e.args)
    end
    return false
end

function _rhs_has_when(ctx::_FireCtx, e)
    e === ctx.whensym && return true
    if e isa Symbol
        return e in ctx.when_locals
    elseif e isa Expr
        return any(a -> _rhs_has_when(ctx, a), e.args)
    end
    return false
end

# Shape check for :state_expr: after alias resolution every leaf is a literal/
# const/evt-pure/state-chain atom and every call is in _RHS_PURE or a registered
# @fragment helper.
function _shape_ok(ctx::_FireCtx, e)
    _is_literal(e) && return true
    if e isa Symbol
        e === ctx.statesym && return true
        _is_module_const(ctx, e) && return true
        return haskey(ctx.evt_locals, e)
    end
    if e isa Expr
        if e.head === :. || e.head === :ref
            return _access_root(e) === ctx.statesym
        elseif e.head === :call
            nm = _callee_name(e.args[1])
            if nm !== nothing && (nm in _RHS_PURE || _is_fragment_name(ctx, nm))
                return all(a -> _shape_ok(ctx, a), e.args[2:end])
            end
            return false
        elseif e.head === :tuple || e.head === :vect
            return all(a -> _shape_ok(ctx, a), e.args)
        elseif e.head === :if || e.head === :elseif || e.head === :&& || e.head === :|| ||
               e.head === :comparison
            # ternary / short-circuit / chained comparison over pure operands
            return all(a -> a isa Symbol && a in keys(_GC_OPS_NEVER) ? true : _shape_ok(ctx, a),
                       e.args)
        elseif e.head === :block
            stmts = Any[a for a in e.args if !(a isa LineNumberNode)]
            return length(stmts) == 1 && _shape_ok(ctx, stmts[1])
        else
            return false
        end
    end
    return false
end

# Comparison-operator symbols that appear as bare args inside an `Expr(:comparison, ...)`
# (a op b op c); they are not operands and are always shape-ok.
const _GC_OPS_NEVER = Dict{Symbol,Bool}(op => true for op in _ARITH_BOOL_OPS)

_is_fragment_name(ctx::_FireCtx, nm::Symbol) =
    ctx.mod !== nothing && any(k -> k[1] === ctx.mod && k[2] === nm, keys(_FRAGMENT_REGISTRY))

# Chain -> masked address. `chain` is a state access chain rooted at statesym.
function _chain_mask(ctx::_FireCtx, chain)
    stripped = _strip_state_head(chain, ctx.statesym)
    ms = stripped isa Symbol ? Any[Member(stripped)] : access_to_searchkey(stripped)
    return placekey_mask_index(ms)
end

_mask_has_memberindex(m) = any(c -> c === MEMBERINDEX, m)

# Does the resolved rhs read a state address written earlier in this body? Only
# scalar (index-free) masks are compared: a mask with a MEMBERINDEX collides on
# the container/field but not the concrete element, so `locations[a].cnt` written
# then `locations[b].cnt` read is NOT staleness (decision 7 targets the exact
# next_strain_id-style scalar sequencing). Index-aware staleness is Phase 3.
function _reads_written_address(ctx::_FireCtx, e)
    isempty(ctx.written_masks) && return false
    if e isa Expr && (e.head === :. || e.head === :ref) && _access_root(e) === ctx.statesym
        m = _chain_mask(ctx, e)
        (!_mask_has_memberindex(m) && any(wm -> wm == m, ctx.written_masks)) && return true
        return any(sub -> _reads_written_address(ctx, sub), _index_subexprs(e))
    elseif e isa Expr
        return any(a -> _reads_written_address(ctx, a), e.args)
    end
    return false
end

"""
    _classify_rhs(ctx, rhs) -> Symbol

Classify an assignment rhs by the precedence `:stochastic` > `:opaque(when)` >
`:evt_pure` > `:state_expr` > `:opaque`. Appends a note for the `when` and
alias-staleness demotions.
"""
function _classify_rhs(ctx::_FireCtx, rhs)
    _rhs_has_stoch(ctx, rhs) && return :stochastic
    if _rhs_has_when(ctx, rhs)
        push!(ctx.notes, "time-dependent rhs `$(_short(rhs))` — `when` is not modeled; havoc for Phase 4")
        return :opaque
    end
    _is_evt_pure_ext(rhs, ctx) && return :evt_pure
    if _shape_ok(ctx, _resolve(rhs, ctx.aliases))
        if _reads_written_address(ctx, _resolve(rhs, ctx.aliases))
            push!(ctx.notes, "alias read-before-write: rhs `$(_short(rhs))` reads state written earlier; demoted to opaque")
            return :opaque
        end
        return :state_expr
    end
    return :opaque
end

# Worst-of classification over a mutator's value operands.
const _RHS_RANK = Dict{Symbol,Int}(:evt_pure => 0, :state_expr => 1, :opaque => 2, :stochastic => 3)
_worse(a::Symbol, b::Symbol) = _RHS_RANK[a] >= _RHS_RANK[b] ? a : b

_lambda_params(p::Symbol) = Symbol[p]
_lambda_params(p) = p isa Expr && p.head === :tuple ? Symbol[x for x in p.args if x isa Symbol] : Symbol[]

function _classify_operand(ctx::_FireCtx, v)
    if v isa Expr && v.head === :->
        # Filter/closure operand: classify the body with its params treated as
        # neutral (evt-pure) bound variables.
        params = _lambda_params(v.args[1])
        saved = copy(ctx.evt_locals)
        for p in params
            ctx.evt_locals[p] = true
        end
        c = _classify_rhs(ctx, _strip_block(v.args[2]))
        ctx.evt_locals = saved
        return c
    end
    return _classify_rhs(ctx, v)
end

# Unwrap a single-statement `:block` (a lambda body carries a LineNumberNode).
function _strip_block(e)
    if e isa Expr && e.head === :block
        stmts = Any[a for a in e.args if !(a isa LineNumberNode)]
        length(stmts) == 1 && return _strip_block(stmts[1])
    end
    return e
end

function _classify_mutator_rhs(ctx::_FireCtx, valops)
    isempty(valops) && return :evt_pure
    worst = :evt_pure
    for v in valops
        worst = _worse(worst, _classify_operand(ctx, v))
    end
    return worst
end

########################### Write recording ###########################

function _write_matchstr_indices(ctx::_FireCtx, resolved_access)
    stripped = _strip_state_head(resolved_access, ctx.statesym)
    if stripped isa Symbol
        return (Any[Member(stripped)], Any[])
    end
    matchstr = access_to_searchkey(stripped)
    argnames = access_to_argnames(stripped)
    indices = Any[_classify_index(ctx, idx) for idx in argnames]
    return (matchstr, indices)
end

function _record_write!(ctx::_FireCtx, resolved_lhs, rhs, op::Symbol, subtree::Bool, source::String)
    matchstr, indices = _write_matchstr_indices(ctx, resolved_lhs)
    cls = _classify_rhs(ctx, rhs)
    push!(ctx.writes, WriteSpec(matchstr, indices, subtree, op, cls, _resolve(rhs, ctx.aliases), source))
    push!(ctx.written_masks, placekey_mask_index(matchstr))
    return nothing
end

########################### Walker overrides ###########################

const _OPASSIGN_OPS = Dict{Symbol,Symbol}(
    :(+=) => :+, :(-=) => :-, :(*=) => :*, :(/=) => :/, :(÷=) => :÷,
    :(%=) => :%, :(^=) => :^, :(|=) => :|, :(&=) => :&, :(⊻=) => :⊻,
)

# _walk! override: intercept op-assign, macrocall (@obswrite/@obsread), and
# broadcast-assign heads; everything else falls through to the shared _WalkCtx
# traversal (which re-dispatches _walk_call!/_walk_assign! back to _FireCtx).
function _walk!(ctx::_FireCtx, expr)
    if expr isa Expr
        h = expr.head
        if haskey(_OPASSIGN_OPS, h)
            _walk_opassign!(ctx, expr)
            return nothing
        elseif h === :macrocall
            _walk_macrocall!(ctx, expr)
            return nothing
        elseif h === :.=
            _walk_dotassign!(ctx, expr)
            return nothing
        end
    end
    invoke(_walk!, Tuple{_WalkCtx,Any}, ctx, expr)
    return nothing
end

function _walk_opassign!(ctx::_FireCtx, expr)
    op = _OPASSIGN_OPS[expr.head]
    lhs = expr.args[1]
    rhs = expr.args[2]
    _walk_assign!(ctx, Expr(:(=), lhs, Expr(:call, op, lhs, rhs)))
    return nothing
end

function _walk_dotassign!(ctx::_FireCtx, expr)
    lhs = expr.args[1]
    if lhs isa Expr && (lhs.head === :. || lhs.head === :ref) &&
        _access_root(_resolve(lhs, ctx.aliases)) === ctx.statesym
        _fire_error("@fire: broadcast assignment `$(expr)` to state is not a supported " *
            "mutation form. Write an explicit element assignment or a recognized mutator.")
    end
    for a in expr.args
        _walk!(ctx, a)
    end
    return nothing
end

function _macrocall_name(name)
    name isa Symbol && return name
    if name isa Expr && name.head === :. && name.args[2] isa QuoteNode
        return name.args[2].value
    end
    return nothing
end

function _walk_macrocall!(ctx::_FireCtx, expr)
    mname = _macrocall_name(expr.args[1])
    inner = expr.args[3:end]
    if mname === Symbol("@obswrite") && length(inner) == 1 &&
        inner[1] isa Expr && inner[1].head === :(=)
        _walk_assign!(ctx, inner[1])
        return nothing
    end
    # @obsread and every other macrocall (@assert, @debug, @info): args are reads.
    for a in inner
        _walk!(ctx, a)
    end
    return nothing
end

# _walk_assign! override: state writes, plus local-binding classification that also
# tracks stochastic/when locals.
function _walk_assign!(ctx::_FireCtx, stmt)
    lhs = stmt.args[1]
    rhs = stmt.args[2]
    if lhs isa Expr && (lhs.head === :. || lhs.head === :ref) &&
        _access_root(_resolve(lhs, ctx.aliases)) === ctx.statesym
        # STATE WRITE. `c[k] = v` (ref lhs) is a whole-element write (subtree);
        # `x.field = v` (dot lhs) is a leaf write.
        resolved_lhs = _resolve(lhs, ctx.aliases)
        op = lhs.head === :ref ? :setindex : :assign
        _record_write!(ctx, resolved_lhs, rhs, op, lhs.head === :ref, string(stmt))
        for idx in _index_subexprs(lhs)
            _walk!(ctx, idx)
        end
        _walk!(ctx, rhs)
    elseif lhs isa Symbol
        # LOCAL BINDING. A state access chain is an ALIAS even when its index is a
        # stochastic/when local — the value read from state is deterministic given
        # the index (the index's taint is handled by index classification, not the
        # value class). So the alias check precedes the stochastic/when checks.
        resolved = _resolve(rhs, ctx.aliases)
        if _access_root(resolved) === ctx.statesym
            ctx.aliases[lhs] = resolved
            _forget_local_sets!(ctx, lhs; keep=:alias)
            for idx in _index_subexprs(rhs)
                _walk!(ctx, idx)
            end
        elseif _rhs_has_stoch(ctx, rhs)
            push!(ctx.stoch_locals, lhs)
            _forget_local_sets!(ctx, lhs; keep=:stoch)
        elseif _rhs_has_when(ctx, rhs)
            push!(ctx.when_locals, lhs)
            _forget_local_sets!(ctx, lhs; keep=:when)
        elseif _is_evt_pure_ext(rhs, ctx)
            ctx.evt_locals[lhs] = rhs
            _forget_local_sets!(ctx, lhs; keep=:evt)
        else
            _forget_local_sets!(ctx, lhs; keep=:none)
        end
        _walk!(ctx, rhs)
    else
        # ref/dot on a NON-state root (local container) or tuple destructuring.
        _walk!(ctx, rhs)
        if lhs isa Expr
            for idx in _index_subexprs(lhs)
                _walk!(ctx, idx)
            end
        end
        _forget_var!(ctx, lhs)
    end
    return nothing
end

# Clear a local from every classification set except the one it is being added to.
function _forget_local_sets!(ctx::_FireCtx, lhs::Symbol; keep::Symbol)
    keep === :alias || delete!(ctx.aliases, lhs)
    keep === :evt || delete!(ctx.evt_locals, lhs)
    keep === :stoch || delete!(ctx.stoch_locals, lhs)
    keep === :when || delete!(ctx.when_locals, lhs)
    return nothing
end

########################### _walk_call! override + mutator table ###########################

# name => (container_pos, op, subtree, key_pos). key_pos 0 => address is the
# container itself; else address is container[args[key_pos]].
const _MUTATORS = Dict{Symbol,NTuple{4,Any}}(
    :push!      => (1, :push, false, 0),
    :pushfirst! => (1, :push, false, 0),
    :append!    => (1, :append, false, 0),
    :pop!       => (1, :pop, false, 0),
    :popfirst!  => (1, :pop, false, 0),
    :empty!     => (1, :empty, false, 0),
    :resize!    => (1, :resize, false, 0),
    :sizehint!  => (1, :resize, false, 0),
    :delete!    => (1, :delete, false, 0),
    :union!     => (1, :union, false, 0),
    :intersect! => (1, :intersect, false, 0),
    :setdiff!   => (1, :setdiff, false, 0),
    :symdiff!   => (1, :symdiff, false, 0),
    :filter!    => (2, :filter, false, 0),
    :setindex!  => (1, :setindex, true, 3),
)

function _walk_call!(ctx::_FireCtx, expr)
    callee = expr.args[1]
    name = _callee_name(callee)
    args = expr.args[2:end]

    if name !== nothing && name in _ARITH_BOOL_OPS
        for a in args
            _walk!(ctx, a)
        end
        return nothing
    end
    # get! is in the read _WHITELIST, so it must be intercepted BEFORE that branch:
    # its miss path WRITES c[k] (observed_dict.jl get!). Falls through to the
    # whitelist (read-only handling) when the container is not state.
    if name === :get! && _walk_getbang!(ctx, args, expr)
        return nothing
    end
    if name !== nothing && name in _WHITELIST
        _walk_whitelisted!(ctx, name, args, expr)
        return nothing
    end
    if name !== nothing && name in _REDUCERS &&
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
    if name !== nothing && haskey(_MUTATORS, name)
        _walk_mutator!(ctx, name, args, expr)
        return nothing
    end
    if name === :fire! && ctx.mod !== nothing && _try_inline_fire!(ctx, expr, args)
        return nothing
    end
    if name !== nothing && ctx.mod !== nothing && _try_inline_fragment!(ctx, name, args)
        return nothing
    end
    # Unrecognized bang-named call receiving state: a macro-time error.
    if name !== nothing && endswith(string(name), "!") && any(a -> _contains_state(a, ctx), args)
        _fire_error("""
        @fire: `$(expr)` — `$(name)` is not a recognized state mutator. Recognized: \
        $(join(sort!(collect(String[string(k) for k in keys(_MUTATORS)])), ", ")). \
        Register the helper with @fragment, or rewrite the mutation with a recognized form.
        """)
    end
    # Everything else (non-bang unknown, constructors, opaque helpers): walk args as
    # reads; note when state flows in (hidden writes are the runtime oracle's job).
    stateful = false
    for a in args
        _contains_state(a, ctx) && (stateful = true)
        _walk!(ctx, a)
    end
    stateful && push!(ctx.notes,
        "opaque call `$(_short(expr))` receives state; hidden writes are checked at runtime")
    return nothing
end

# Emit BOTH WriteSpecs for a keyed container mutation: the container leaf `(c,)`
# (an ObservedSet notifies the set's own address) AND `c[k]` with subtree=true
# (an ObservedDict notifies `(d, k)` for a primitive element and per-element-field
# for a compound one). Over-declaring is sound for the oracle (changed ⊆ specs)
# and errs toward :can_change for can_stop_change.
function _push_keyed_mutator_specs!(ctx::_FireCtx, chain, key, op::Symbol, cls::Symbol,
                                    rhs_ast, src::String)
    matchstr, indices = _write_matchstr_indices(ctx, chain)
    push!(ctx.writes, WriteSpec(matchstr, indices, false, op, cls, rhs_ast, src))
    push!(ctx.written_masks, placekey_mask_index(matchstr))
    keyed = Expr(:ref, chain, _resolve(key, ctx.aliases))
    kms, kidx = _write_matchstr_indices(ctx, keyed)
    push!(ctx.writes, WriteSpec(kms, kidx, true, op, cls, rhs_ast, src))
    push!(ctx.written_masks, placekey_mask_index(kms))
    return nothing
end

function _walk_mutator!(ctx::_FireCtx, name::Symbol, args, expr)
    (cpos, op, subtree, keypos) = _MUTATORS[name]
    container = cpos <= length(args) ? args[cpos] : nothing
    chain = container === nothing ? nothing : _state_chain(container, ctx)
    if chain === nothing
        # Container is a local (Set/Vector) or non-state: no write, walk args as reads.
        for a in args
            _walk!(ctx, a)
        end
        return nothing
    end
    valops = Any[args[i] for i in eachindex(args) if i != cpos && i != keypos]
    cls = _classify_mutator_rhs(ctx, valops)
    rhs_ast = Expr(:call, name,
        (i == cpos ? chain : _resolve(args[i], ctx.aliases) for i in eachindex(args))...)
    if name in (:delete!, :pop!) && length(args) >= 2
        # Keyed delete!/pop!: an ObservedDict notifies (d, key)/per-element-field,
        # an ObservedSet notifies (s,). Emit both shapes (over-declaration is sound).
        _push_keyed_mutator_specs!(ctx, chain, args[2], op, cls, rhs_ast, string(expr))
        # pop!(c, k, default)'s miss path is a per-key read.
        name === :pop! && length(args) >= 3 &&
            _record_key_read!(ctx, container, args[2], string(expr))
    else
        addr_chain = chain
        if keypos != 0 && keypos <= length(args)
            addr_chain = Expr(:ref, chain, _resolve(args[keypos], ctx.aliases))
        end
        matchstr, indices = _write_matchstr_indices(ctx, addr_chain)
        push!(ctx.writes, WriteSpec(matchstr, indices, subtree, op, cls, rhs_ast, string(expr)))
        push!(ctx.written_masks, placekey_mask_index(matchstr))
    end
    for i in eachindex(args)
        i == cpos && continue
        _walk!(ctx, args[i])
    end
    return nothing
end

# get!(c, k, v) / get!(f, c, k) with a state container: a write on miss
# (observed_dict.jl get!) plus a per-key read. Returns false (caller falls through
# to the read whitelist) when neither container position resolves to state.
function _walk_getbang!(ctx::_FireCtx, args, expr)
    length(args) >= 2 || return false
    local cpos, keypos, valpos
    if _state_chain(args[1], ctx) !== nothing
        cpos, keypos = 1, 2
        valpos = length(args) >= 3 ? 3 : 0
    elseif length(args) >= 3 && _state_chain(args[2], ctx) !== nothing
        cpos, keypos, valpos = 2, 3, 1
    else
        return false
    end
    container = args[cpos]
    chain = _state_chain(container, ctx)
    key = args[keypos]
    src = string(expr)
    valops = valpos == 0 ? Any[] : Any[args[valpos]]
    cls = _classify_mutator_rhs(ctx, valops)
    rhs_ast = Expr(:call, :get!,
        (i == cpos ? chain : _resolve(args[i], ctx.aliases) for i in eachindex(args))...)
    _push_keyed_mutator_specs!(ctx, chain, key, :get!, cls, rhs_ast, src)
    _record_key_read!(ctx, container, key, src)
    for i in eachindex(args)
        i == cpos && continue
        _walk!(ctx, args[i])
    end
    return true
end

# Inline a `fire!(EvtType(cargs...), state, when, rng)` recursion into another
# @fire body: substitute callee event fields <- constructor args, state/when/rng
# <- the caller's arguments, alpha-rename callee locals, and re-walk.
function _try_inline_fire!(ctx::_FireCtx, expr, args)
    length(args) == 4 || return false
    ctor = args[1]
    (ctor isa Expr && ctor.head === :call) || return false
    evtname = _callee_name(ctor.args[1])
    evtname === nothing && return false
    _access_root(_resolve(args[2], ctx.aliases)) === ctx.statesym || return false
    cargs = ctor.args[2:end]
    if !isdefined(ctx.mod, evtname)
        error("@fire: cannot inline `fire!($evtname(...), ...)`: event type `$evtname` is " *
            "not defined in $(ctx.mod). Define it before the calling fire!.")
    end
    key = (ctx.mod, :fire, evtname)
    haskey(_FIRE_REGISTRY, key) || error(
        "@fire: cannot inline `fire!($evtname(...), ...)`: no @fire is registered for " *
        "`$evtname`. Annotate `@fire function fire!(evt::$evtname, ...)` before the fire! " *
        "that calls it.")
    T = getfield(ctx.mod, evtname)
    fnames = fieldnames(T)
    if length(cargs) != length(fnames)
        error("@fire: recursion `fire!($evtname(...), ...)` passes $(length(cargs)) " *
            "constructor argument(s) but `$evtname` has $(length(fnames)) field(s) $(fnames).")
    end
    (evtsym_c, statesym_c, whensym_c, rngsym_c, body) = _FIRE_REGISTRY[key]
    fieldmap = Dict{Symbol,Any}()
    for (f, ca) in zip(fnames, cargs)
        fieldmap[f] = ca
    end
    symmap = Dict{Symbol,Any}(statesym_c => args[2], whensym_c => args[3], rngsym_c => args[4])
    locals = Set{Symbol}()
    _collect_assigned!(locals, body)
    for l in locals
        symmap[l] = gensym(l)
    end
    newbody = _subst_precond(body, evtsym_c, fieldmap, symmap)
    _inline_walk!(ctx, "fire!($evtname)", newbody)
    return true
end

########################### Derivation entry point ###########################

"""
    _derive_effectspecs(body, statesym, evtsym, whensym, rngsym, mod) -> EffectSpec

Run the write-side taint pass over a `fire!` body. Errors (macro time) only on the
zero-write case and on unrecognized bang-mutations of state; reads are collected
without any covering-trigger enforcement.
"""
function _derive_effectspecs(body, statesym::Symbol, evtsym::Symbol, whensym::Symbol,
                             rngsym::Symbol, mod=nothing)
    ctx = _FireCtx(statesym, evtsym, whensym, rngsym, mod)
    _walk_block!(ctx, body)
    isempty(ctx.writes) && error("""
        @fire: this fire! writes no physical state, so it has no effect to declare.
        A @fire method must mutate some tracked state — remove the @fire or fix the body.
        """)
    writes = _dedup_writes(ctx.writes)
    widened = count(w -> !spec_clean(w), writes)
    return EffectSpec(writes, ctx.reads, widened, ctx.notes)
end

########################### The @fire macro ###########################

_plainname(arg) = arg isa Expr && arg.head === :(::) ? arg.args[1] : arg

"""
    @fire function fire!(evt::EvtType, state, when, rng)
        <body>
    end

Emit the `fire!` method verbatim (analysis-only: runtime behavior is byte-identical
to the unannotated method) and derive its static effect specification by a syntactic
taint pass over the body — the write-side mirror of [`@precondition`](@ref). The
derived [`EffectSpec`](@ref) is exposed via [`effect_spec`](@ref)`(EvtType)` and
checked at runtime by [`CheckEffects`](@ref); the original body is baked as
[`fire_ast`](@ref)`(EvtType)` for Phase 4.

The walker understands assignment to state access chains (`x.field = rhs`,
`c[k] = rhs`, and the op-assign forms), the ObservedState mutation API (`push!`,
`filter!`, `delete!`, `union!`, `empty!`, …), `@obswrite`/`@obsread`, registered
`@fragment` helpers (inlined), and nested `fire!(EvtType(args...), state, when,
rng)` calls to other `@fire`d events (inlined). Loops and branches widen indices
exactly as the read pass does; a write under a branch is recorded unconditionally
(may-write).

Macro-time errors: a call whose name ends in `!` that receives state and is not a
recognized mutator; a `.=` broadcast assignment to state; a body that writes no
state at all.
"""
macro fire(fdef)
    sig, body = _split_funcdef(fdef)
    (sig isa Expr && sig.head === :call) ||
        error("@fire expects `function fire!(evt::EvtType, state, when, rng) ... end`")
    length(sig.args) == 5 ||
        error("@fire: fire! must take (evt::EvtType, state, when, rng)")
    evt_arg = sig.args[2]
    (evt_arg isa Expr && evt_arg.head === :(::)) ||
        error("@fire: first argument must be `evt::EventType`")
    evtsym = evt_arg.args[1]::Symbol
    EvtType = evt_arg.args[2]
    statesym = _plainname(sig.args[3])
    whensym = _plainname(sig.args[4])
    rngsym = _plainname(sig.args[5])
    all(x -> x isa Symbol, (statesym, whensym, rngsym)) ||
        error("@fire: state, when, and rng arguments must be plain names")

    # Register BEFORE deriving so a self fire!-recursion is caught as a cycle and so
    # later @fire bodies can inline this one.
    _FIRE_REGISTRY[(__module__, :fire, _evt_name(EvtType))] =
        (evtsym, statesym, whensym, rngsym, body)

    es = _derive_effectspecs(body, statesym, evtsym, whensym, rngsym, __module__)

    return Expr(:block,
        esc(fdef),
        :(ChronoSim.effect_spec(::Type{$(esc(EvtType))}) = $es),
        :(ChronoSim.fire_ast(::Type{$(esc(EvtType))}) =
            ($(QuoteNode(evtsym)), $(QuoteNode(statesym)), $(QuoteNode(whensym)),
             $(QuoteNode(rngsym)), $(QuoteNode(body)))),
    )
end

########################### can_stop_change (whyrunning) ###########################

"""
    StopWriteAnalysis

Result of [`can_stop_change`](@ref): the `verdict`
(`:can_change | :cannot_change | :unknown`), the `hits` (each a
`(event, write, read)` mask triple), the `unanalyzed` event names lacking an
`effect_spec`, and — when `enabled_types` was given — the split of hitting event
names into `enabled_hits` and `disabled_hits`.
"""
struct StopWriteAnalysis
    verdict::Symbol
    hits::Vector{NamedTuple{(:event, :write, :read),Tuple{Symbol,Tuple,Tuple}}}
    unanalyzed::Vector{Symbol}
    enabled_hits::Vector{Symbol}
    disabled_hits::Vector{Symbol}
end

_v1_comp_match(a, b) = a == b || a === MEMBERINDEX || b === MEMBERINDEX
function _prefix_compatible(wm, rm)
    length(rm) >= length(wm) || return false
    return all(_v1_comp_match(wm[i], rm[i]) for i in eachindex(wm))
end
_v1_masks_intersect(wm, subtree::Bool, rm) =
    subtree ? _prefix_compatible(wm, rm) :
    (length(wm) == length(rm) && all(_v1_comp_match(a, b) for (a, b) in zip(wm, rm)))

"""
    can_stop_change(stop_reads, events; enabled_types=nothing) -> StopWriteAnalysis

Answer `whyrunning`'s unreachability question: can any event ever write an address
the stop predicate reads? `stop_reads` is the address iterable that
`capture_state_reads` returned for the stop-predicate evaluation; `events` is the
model's event-type vector. Every event type's `WriteSpec` masks are intersected
with the masked stop reads.

The verdict is `:cannot_change` only when every event type has an `effect_spec`
and no mask intersects; any type without a spec makes the verdict `:unknown` and
is listed in `unanalyzed`. With `enabled_types`, hits split into currently-enabled
and disabled events.

The v1 mask intersection ignores index constraints and treats `subtree` masks as
covering all descendants — it over-approximates toward `:can_change`, never toward
`:cannot_change`, so the unreachability claim stays sound. Phase 3's
`masks_intersect` replaces this primitive with index-aware unification.
"""
function can_stop_change(stop_reads, events::AbstractVector; enabled_types=nothing)
    HT = NamedTuple{(:event, :write, :read),Tuple{Symbol,Tuple,Tuple}}
    hits = HT[]
    unanalyzed = Symbol[]
    read_masks = unique(Tuple[placekey_mask_index(a) for a in stop_reads])
    for T in events
        if !hasmethod(effect_spec, Tuple{Type{T}})
            push!(unanalyzed, nameof(T))
            continue
        end
        for w in effect_spec(T).writes
            wm = write_mask(w)
            for rm in read_masks
                if _v1_masks_intersect(wm, w.subtree, rm)
                    push!(hits, (event=nameof(T), write=wm, read=rm))
                end
            end
        end
    end
    verdict = !isempty(hits) ? :can_change : (isempty(unanalyzed) ? :cannot_change : :unknown)
    enabled_hits = Symbol[]
    disabled_hits = Symbol[]
    if enabled_types !== nothing
        enset = Set{Symbol}(nameof(T) for T in enabled_types)
        for nm in unique(Symbol[h.event for h in hits])
            push!(nm in enset ? enabled_hits : disabled_hits, nm)
        end
    end
    return StopWriteAnalysis(verdict, hits, unique(unanalyzed), enabled_hits, disabled_hits)
end

function Base.show(io::IO, sw::StopWriteAnalysis)
    print(io, "StopWriteAnalysis(", sw.verdict, ", ", length(sw.hits), " hit(s))")
end

function Base.show(io::IO, ::MIME"text/plain", sw::StopWriteAnalysis)
    head = sw.verdict === :can_change ? "CAN CHANGE" :
           sw.verdict === :cannot_change ? "CANNOT CHANGE" : "UNKNOWN"
    println(io, "stop-write analysis: ", head)
    if sw.verdict === :cannot_change
        println(io, "  no event can ever write what the stop condition reads")
    else
        writers = unique(Symbol[h.event for h in sw.hits])
        if isempty(writers)
            println(io, "  events that can write the stop reads: none")
        else
            println(io, "  events that can write the stop reads:")
            for h in Iterators.take(sw.hits, 6)
                println(io, "    ", h.event, "  write ", h.write, " ∩ read ", h.read)
            end
            length(sw.hits) > 6 && println(io, "    ... and ", length(sw.hits) - 6, " more")
        end
    end
    if !isempty(sw.enabled_hits) || !isempty(sw.disabled_hits)
        if isempty(sw.enabled_hits)
            println(io, "  none of the currently-enabled events can; these disabled events could: ",
                join(sw.disabled_hits, ", "))
        else
            println(io, "  currently enabled that can: ", join(sw.enabled_hits, ", "))
        end
    end
    if !isempty(sw.unanalyzed)
        println(io, "  not analyzed (no @fire): ", join(sw.unanalyzed, ", "))
    end
    print(io, "  (index constraints not analyzed; subtree writes cover descendants — Phase 3)")
end
