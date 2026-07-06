# The Quint compiler — effect (fire!) lowering.
#
# Walks a baked `fire_ast(T)` body once with a symbolic environment `varenv`
# (physical field -> current Quint expression). Local aliases to state chains and
# value locals ride in `ctx.aliases`/`ctx.subst`. At the end every schema var gets
# `v' = varenv[v]` (unwritten -> `v' = v`), the no-implicit-frame rule. `rand`
# draws lift to top-level `nondet` lines (D9); `if`/`for` merge/fold per var.

########################### Entry point ###########################

# Lower a fire! body. Returns (nondet_lines::Vector{String}, assigns::Dict{Symbol,String}).
function _qeffect!(ctx::_EmitCtx, body)
    stmts = body isa Expr && body.head === :block ? body.args : Any[body]
    for st in stmts
        _estmt!(ctx, st)
    end
    assigns = Dict{Symbol,String}()
    for f in ctx.schema.fields
        f.kind in (:scalar, :array1, :arrayN, :dict, :set) || continue
        assigns[f.emit] = get(ctx.varenv, f.name, string(f.emit))
    end
    return (copy(ctx.nondets), assigns)
end

########################### Statement dispatch ###########################

function _estmt!(ctx::_EmitCtx, st)
    st isa LineNumberNode && return
    if st isa Expr
        h = st.head
        if h === :(=)
            return _eassign!(ctx, st.args[1], st.args[2])
        elseif haskey(_EFF_OPASSIGN, h)
            lhs = st.args[1]
            return _eassign!(ctx, lhs, Expr(:call, _EFF_OPASSIGN[h], lhs, st.args[2]))
        elseif h === :if || h === :elseif
            return _ebranch!(ctx, st)
        elseif h === :for
            return _eloop!(ctx, st)
        elseif h === :call
            return _ecall!(ctx, st)
        elseif h === :macrocall
            return _emacrocall!(ctx, st)
        elseif h === :block
            for s in st.args
                _estmt!(ctx, s)
            end
            return
        elseif h === :break || h === :continue || h === :return
            return   # @assert-implied returns / control flow: dropped at statement level
        end
    end
    # bare expression (e.g. a call used for effect) — walk as a call/no-op
    return
end

const _EFF_OPASSIGN = Dict{Symbol,Symbol}(
    :(+=) => :+, :(-=) => :-, :(*=) => :*, :(÷=) => :÷, :(%=) => :%, :(^=) => :^,
    :(|=) => :|, :(&=) => :&, :(⊻=) => :⊻,
)

########################### Assignment ###########################

function _eassign!(ctx::_EmitCtx, lhs, rhs)
    if lhs isa Symbol
        return _ebind_local!(ctx, lhs, rhs)
    end
    resolved = _resolve(lhs, ctx.aliases)
    if _access_root(resolved) === ctx.statesym
        return _ewrite_state!(ctx, resolved, rhs)
    end
    # write to a non-state ref/dot (a local container element): unsupported for now
    _refuse!(ctx, :unsupported_node, "assignment `$(_src(Expr(:(=), lhs, rhs)))`",
        _src(lhs), "assignments must target state or a plain local")
end

# `x = rhs` local: alias, lifted rand, or value local.
function _ebind_local!(ctx::_EmitCtx, x::Symbol, rhs)
    resolved = _resolve(rhs, ctx.aliases)
    if _access_root(resolved) === ctx.statesym
        ctx.aliases[x] = resolved
        ctx.types[x] = _infer_type(ctx, resolved)
        return
    end
    lifted = _maybe_rand(ctx, rhs)
    if lifted !== nothing
        ctx.subst[x] = lifted
        ctx.types[x] = nothing
        return
    end
    # value local; may be a local-collection tracked for later mutation
    ctx.subst[x] = _qprint(ctx, resolved)
    ctx.types[x] = _infer_type(ctx, rhs)
    return
end

# A leaf/element/scalar state write. `resolved` is a chain rooted at statesym.
function _ewrite_state!(ctx::_EmitCtx, resolved, rhs)
    parts = _chain_parts(resolved, ctx.statesym)
    parts === nothing && _refuse!(ctx, :unsupported_node, "state write `$(_src(resolved))`",
        _src(resolved), "unsupported write shape")
    (field, keyexprs, leaf) = parts
    fi = _field_by_name(ctx.schema, field)
    if fi !== nothing && fi.kind === :erased
        return   # writes to erased (float) fields are dropped (reported at schema time)
    end
    # a write to a dropped (float/unrepresentable) record leaf field is dropped too
    if leaf !== nothing && fi !== nothing && _is_record_type(fi.eltype)
        ri = get(ctx.schema.records, nameof(fi.eltype), nothing)
        ri !== nothing && leaf in ri.dropped && return
    end
    cur = get(ctx.varenv, field, string(_sanitize(field)))
    lifted = _maybe_rand(ctx, rhs)
    rstr = lifted !== nothing ? lifted : _qprint(ctx, _resolve(rhs, ctx.aliases))
    if keyexprs === nothing
        ctx.varenv[field] = rstr                       # scalar field
        return
    end
    key = _elower_key(ctx, keyexprs)
    if leaf === nothing
        ctx.varenv[field] = cur * ".set(" * key * ", " * rstr * ")"   # whole element
    else
        et = fi === nothing ? nothing : fi.eltype
        if _is_collapsed(ctx, et)
            ctx.varenv[field] = cur * ".set(" * key * ", " * rstr * ")"
        else
            ctx.varenv[field] = cur * ".set(" * key * ", " * cur * ".get(" * key *
                ").with(\"" * string(leaf) * "\", " * rstr * "))"
        end
    end
    return
end

# Lower a (possibly multi-component) container key.
function _elower_key(ctx::_EmitCtx, keyexprs)
    length(keyexprs) == 1 && return _qprint(ctx, _resolve(keyexprs[1], ctx.aliases))
    return "(" * join((_qprint(ctx, _resolve(k, ctx.aliases)) for k in keyexprs), ", ") * ")"
end

# Decompose a resolved state chain into (field::Symbol,
# keyexprs::Union{Nothing,Vector}, leaf::Union{Nothing,Symbol}).
# Shapes: state.f ; state.c[k] ; state.c[k].g.
function _chain_parts(resolved, statesym)
    if resolved isa Expr && resolved.head === :.
        a = resolved.args[1]
        leaf = _fieldsym(resolved.args[2])
        if a === statesym
            return (leaf, nothing, nothing)         # scalar state.f
        elseif a isa Expr && a.head === :ref
            c = a.args[1]
            if c isa Expr && c.head === :. && c.args[1] === statesym
                return (_fieldsym(c.args[2]), a.args[2:end], leaf)   # state.c[k].leaf
            end
        end
    elseif resolved isa Expr && resolved.head === :ref
        c = resolved.args[1]
        if c isa Expr && c.head === :. && c.args[1] === statesym
            return (_fieldsym(c.args[2]), resolved.args[2:end], nothing)   # state.c[k]
        end
    end
    return nothing
end

########################### rand lifting (D9) ###########################

# If `rhs` is a rand draw, return the lifted nondet reference; else nothing.
# `rand(rng, D)` (2-arg) lifts D to a top-level `nondet dN = ⟦D⟧.oneOf()`.
function _maybe_rand(ctx::_EmitCtx, rhs)
    (rhs isa Expr && rhs.head === :call) || return nothing
    nm = _callee_name(rhs.args[1])
    nm === nothing && return nothing
    if nm === :rand && length(rhs.args) == 3 && rhs.args[2] isa Symbol
        dom = rhs.args[3]
        if dom isa Expr && dom.head === :call &&
           _callee_name(dom.args[1]) in (:Categorical, :Weights, :pweights)
            _refuse!(ctx, :unsupported_call, "weighted rand `$(_src(rhs))`", _src(rhs),
                "a Categorical draw's support is not represented in the integer skeleton")
        end
        n = count(l -> occursin("nondet _d", l), ctx.nondets) + 1
        name = "_d" * string(n)
        push!(ctx.nondets, "    nondet " * name * " = " *
            _qprint(ctx, _resolve(dom, ctx.aliases)) * ".oneOf()")
        return name
    end
    nm in (:randn, :randexp, :sample) && _refuse!(ctx, :unsupported_call,
        "rand `$(_src(rhs))`", _src(rhs), "only `rand(rng, <finite domain>)` lifts to a nondet")
    return nothing
end

########################### Calls / mutators on state ###########################

function _ecall!(ctx::_EmitCtx, st::Expr)
    nm = _callee_name(st.args[1])
    args = st.args[2:end]
    if nm === :fire! && length(args) == 4
        return _einline_fire!(ctx, args)
    end
    if nm !== nothing && haskey(_STATE_MUTATORS, nm)
        return _emutate!(ctx, nm, args, st)
    end
    if nm in (:delete!, :push!, :union!, :filter!, :empty!, :setdiff!, :pop!)
        # a mutator on a LOCAL collection -> SSA rebind of the local's value
        return _elocal_mutate!(ctx, nm, args, st)
    end
    # a bare call with no state effect (e.g. @assert-like) -> ignore
    return
end

const _STATE_MUTATORS = Dict{Symbol,Symbol}()   # populated below with checked forms

# Mutation of a state container (push!/delete!/union!/filter! on a state set/dict).
function _emutate!(ctx::_EmitCtx, nm::Symbol, args, st::Expr)
    _refuse!(ctx, :unsupported_call, "state mutator `$nm`", _src(st),
        "this state mutator form is not yet supported by the compiler")
end

# Mutate a LOCAL collection: rebind its value via the corresponding set op.
function _elocal_mutate!(ctx::_EmitCtx, nm::Symbol, args, st::Expr)
    c = args[1]
    (c isa Symbol && haskey(ctx.subst, c)) || return   # not a tracked local -> ignore
    cur = ctx.subst[c]
    if nm === :delete!
        ctx.subst[c] = cur * ".exclude(Set(" * _qprint(ctx, _resolve(args[2], ctx.aliases)) * "))"
    elseif nm === :push!
        ctx.subst[c] = cur * ".union(Set(" * _qprint(ctx, _resolve(args[2], ctx.aliases)) * "))"
    elseif nm === :union!
        ctx.subst[c] = cur * ".union(" * _qprint(ctx, _resolve(args[2], ctx.aliases)) * ")"
    elseif nm === :empty!
        ctx.subst[c] = "Set()"
    else
        _refuse!(ctx, :unsupported_call, "local mutator `$nm`", _src(st),
            "unsupported local-collection mutation")
    end
    return
end

########################### Branch merge ###########################

# Branch merge for state vars AND value locals: both branches lower from the
# pre-branch env; every var/local whose value differs merges to an if-expression.
# An alias rebound differently in a branch has no functional merge — refuse.
function _ebranch!(ctx::_EmitCtx, st::Expr)
    cond = _qprint(ctx, _resolve(st.args[1], ctx.aliases))
    before_env = copy(ctx.varenv)
    before_subst = copy(ctx.subst)
    before_alias = copy(ctx.aliases)
    before_types = copy(ctx.types)
    # then branch
    _estmt!(ctx, st.args[2])
    thenenv = copy(ctx.varenv); thensubst = copy(ctx.subst); thenalias = copy(ctx.aliases)
    # else branch (from the pre-branch env)
    elseenv = before_env; elsesubst = before_subst; elsealias = before_alias
    if length(st.args) >= 3
        ctx.varenv = copy(before_env); ctx.subst = copy(before_subst)
        ctx.aliases = copy(before_alias); ctx.types = copy(before_types)
        _estmt!(ctx, st.args[3])
        elseenv = copy(ctx.varenv); elsesubst = copy(ctx.subst); elsealias = copy(ctx.aliases)
    end
    for (k, v) in before_alias
        (get(thenalias, k, v) == v && get(elsealias, k, v) == v) ||
            _refuse!(ctx, :unsupported_node, "alias `$k` rebound inside a branch", _src(st),
                "a state alias rebound under a condition has no functional merge; " *
                "bind the alias once before the branch")
    end
    ctx.aliases = before_alias
    ctx.types = before_types
    # merge state vars
    ctx.varenv = copy(before_env)
    for f in ctx.schema.fields
        f.kind in (:scalar, :array1, :arrayN, :dict, :set) || continue
        v = f.name
        tv = get(thenenv, v, string(f.emit))
        ev = get(elseenv, v, string(f.emit))
        if tv != ev
            ctx.varenv[v] = "(if (" * cond * ") " * tv * " else " * ev * ")"
        end
    end
    # merge value locals that existed before the branch (branch-created locals drop)
    ctx.subst = copy(before_subst)
    for (k, pre) in before_subst
        tv = get(thensubst, k, pre)
        ev = get(elsesubst, k, pre)
        if tv != ev
            ctx.subst[k] = "(if (" * cond * ") " * tv * " else " * ev * ")"
        end
    end
    return
end

########################### Loops (folds) ###########################

# Names of state var fields written inside a body (top-level container fields).
# Loop-local aliases (`x = state.c[i]` inside the loop) are collected first so
# writes through them are seen.
function _loop_written_vars(ctx::_EmitCtx, body)
    aliases = copy(ctx.aliases)
    _collect_loop_aliases!(aliases, body, ctx.statesym)
    written = Symbol[]
    _scan_writes!(body, written, aliases, ctx.statesym)
    return unique(written)
end

function _collect_loop_aliases!(aliases, ex, statesym)
    if ex isa Expr
        if ex.head === :(=) && ex.args[1] isa Symbol
            r = _resolve(ex.args[2], aliases)
            _access_root(r) === statesym && (aliases[ex.args[1]] = r)
        end
        for a in ex.args
            _collect_loop_aliases!(aliases, a, statesym)
        end
    end
    return
end

function _scan_writes!(ex, written, aliases, statesym)
    if ex isa Expr
        if ex.head === :(=) || haskey(_EFF_OPASSIGN, ex.head)
            lhs = ex.args[1]
            if !(lhs isa Symbol)
                p = _chain_parts(_resolve(lhs, aliases), statesym)
                p !== nothing && push!(written, p[1])
            end
        end
        for a in ex.args
            _scan_writes!(a, written, aliases, statesym)
        end
    end
    return
end

function _eloop!(ctx::_EmitCtx, st::Expr)
    _has_rand(ctx, st) && _refuse!(ctx, :rand_in_loop, "rand under a loop", _src(st),
        "a random draw inside a loop is a v1 refusal; hoist it or model it explicitly")
    header = st.args[1]
    (header isa Expr && header.head === :(=)) || _refuse!(ctx, :unclassified_loop,
        "loop header `$(_src(header))`", _src(st), "only `for v in range` loops are supported")
    var = header.args[1]
    written = _loop_written_vars(ctx, st.args[2])
    ml = _mutated_locals(ctx, st.args[2])
    hb = _has_break(st.args[2])
    if isempty(written) && !hb
        return _elocalfold!(ctx, st)          # min-by over locals (idiom 5, ordered)
    end
    if !isempty(ml) || hb
        # counter-capped / breaking ordered scan (idiom 5): one record foldl
        return _erecordfold!(ctx, st, var, written, ml, hb)
    end
    _check_loop_soundness!(ctx, st, var, written)
    dom, lam, saved = _enter_domain!(ctx, var, header.args[2])
    preloop_all = copy(ctx.varenv)          # cross-var reads use the pre-loop env
    folds = Dict{Symbol,String}()
    try
        for w in written
            ctx.varenv = copy(preloop_all)
            preloop = get(preloop_all, w, string(_field_by_name(ctx.schema, w).emit))
            ctx.varenv[w] = "acc"
            _estmt!(ctx, st.args[2])
            body_expr = get(ctx.varenv, w, "acc")
            folds[w] = dom * ".fold(" * preloop * ", (acc, " * lam * ") => " * body_expr * ")"
        end
    finally
        _exit_domain!(ctx, saved)
    end
    ctx.varenv = preloop_all
    for (w, f) in folds
        ctx.varenv[w] = f
    end
    return
end

# Value locals (already bound in subst) that the loop body reassigns.
function _mutated_locals(ctx::_EmitCtx, body)
    out = Symbol[]
    _scan_mutated_locals!(out, body, ctx)
    return unique(out)
end
function _scan_mutated_locals!(out, ex, ctx)
    if ex isa Expr
        if (ex.head === :(=) || haskey(_EFF_OPASSIGN, ex.head)) && ex.args[1] isa Symbol &&
           haskey(ctx.subst, ex.args[1])
            push!(out, ex.args[1])
        end
        for a in ex.args
            _scan_mutated_locals!(out, a, ctx)
        end
    end
    return
end

# A `break` belonging to THIS loop (nested for/while bodies own their breaks).
function _has_break(ex)
    ex isa Expr || return false
    ex.head === :break && return true
    (ex.head === :for || ex.head === :while) && return false
    return any(_has_break, ex.args)
end

# Replace this loop's `break`s with `<stopsym> = true` (not descending into nested loops).
function _replace_breaks(ex, stopsym::Symbol)
    ex isa Expr || return ex
    ex.head === :break && return Expr(:(=), stopsym, true)
    (ex.head === :for || ex.head === :while) && return ex
    return Expr(ex.head, (_replace_breaks(a, stopsym) for a in ex.args)...)
end

_has_rand(ctx, ex) = ex isa Expr &&
    (( ex.head === :call && _callee_name(ex.args[1]) === :rand ) ||
     any(a -> _has_rand(ctx, a), ex.args))

########################### Record foldl (idiom 5: capped/breaking scan) ###########################

# A loop that mutates locals or breaks while (possibly) writing state lowers to ONE
# record `foldl` over an ORDERED domain — the design's counter-capped scan shape:
#   range(lo, hi+1).foldl({ v: ⟦v⟧, c: 0, _stop: false }, (acc, i) => {...})
# Sequential in-order accumulation makes every read through `acc` exact against
# Julia's ascending iteration; an unordered domain refuses (`:unordered_fold`).
function _erecordfold!(ctx::_EmitCtx, st::Expr, var, written, ml, hb)
    header = st.args[1]
    dom, lam, ordered = _ordered_domain(ctx, header.args[2])
    ordered || _refuse!(ctx, :unordered_fold,
        "capped/breaking loop over an unordered domain", _src(st),
        "a scan with a counter or break depends on iteration order; iterate an array " *
        "index range (v1 refuses rather than widening)")
    body = st.args[2]
    stopsym = :_stop
    if hb
        body = _replace_breaks(body, stopsym)
        body = Expr(:block, Expr(:if, Expr(:call, :!, stopsym), body))
    end
    saved = (copy(ctx.subst), copy(ctx.aliases), copy(ctx.types))
    preenv = copy(ctx.varenv)
    inits = String[]
    for w in written
        fi = _field_by_name(ctx.schema, w)
        push!(inits, string(fi.emit) * ": " * get(preenv, w, string(fi.emit)))
        ctx.varenv[w] = "acc." * string(fi.emit)
    end
    for l in ml
        push!(inits, string(l) * ": " * get(ctx.subst, l, "0"))
        ctx.subst[l] = "acc." * string(l)
    end
    if hb
        push!(inits, string(stopsym) * ": false")
        ctx.subst[stopsym] = "acc." * string(stopsym)
        ctx.types[stopsym] = Bool
    end
    if var isa Symbol
        ctx.subst[var] = lam
        ctx.types[var] = Int
    end
    _estmt!(ctx, body)
    upd = String[]
    for w in written
        fi = _field_by_name(ctx.schema, w)
        push!(upd, string(fi.emit) * ": " * get(ctx.varenv, w, "acc." * string(fi.emit)))
    end
    for l in ml
        push!(upd, string(l) * ": " * get(ctx.subst, l, "acc." * string(l)))
    end
    hb && push!(upd, string(stopsym) * ": " * get(ctx.subst, stopsym, "acc." * string(stopsym)))
    foldexpr = dom * ".foldl({ " * join(inits, ", ") * " }, (acc, " * lam * ") => { " *
        join(upd, ", ") * " })"
    (ctx.subst, ctx.aliases, ctx.types) = saved
    ctx.varenv = preenv
    for w in written
        fi = _field_by_name(ctx.schema, w)
        ctx.varenv[w] = "(" * foldexpr * ")." * string(fi.emit)
    end
    for l in ml
        ctx.subst[l] = "(" * foldexpr * ")." * string(l)
    end
    return
end

########################### Loop-soundness enforcement (design §Effects) ###########################

# For the per-var-fold path (independent folds per written var over a possibly
# unordered domain), the design's soundness conditions are enforced here; any
# violation refuses `:loop_read_write_overlap`:
#   * a read of the fold's OWN var (through `acc`) must be at a key the loop also
#     writes — reading v[i+1] while writing v[i] depends on fold order;
#   * a read of a DIFFERENT loop-written var uses the pre-loop env, sound only when
#     the read field is disjoint from that var's written fields, or both read and
#     writes are exactly at the loop variable (each key visited once);
#   * any read of a loop-written SCALAR is unsound (the reviewer's counter case:
#     Julia sees 10,11; independent folds would see 10,10).
function _check_loop_soundness!(ctx::_EmitCtx, st::Expr, var, written)
    aliases = copy(ctx.aliases)
    _collect_loop_aliases!(aliases, st.args[2], ctx.statesym)
    loopkey = var isa Symbol ? string(var) : nothing
    wkeys = Dict{Symbol,Set{String}}()
    wfields = Dict{Symbol,Set{Symbol}}()
    _collect_write_shapes!(st.args[2], aliases, ctx.statesym, wkeys, wfields)
    shared = Tuple{Symbol,Union{Nothing,String},Union{Nothing,Symbol}}[]
    perw = Dict{Symbol,Vector{Tuple{Symbol,Union{Nothing,String},Union{Nothing,Symbol}}}}(
        w => Tuple{Symbol,Union{Nothing,String},Union{Nothing,Symbol}}[] for w in written)
    _collect_loop_reads!(st.args[2], aliases, ctx.statesym, shared, perw)
    wset = Set(written)
    for w in written
        for (v, rk, rf) in Iterators.flatten((shared, perw[w]))
            v in wset || continue
            ks = get(wkeys, v, Set{String}())
            fs = get(wfields, v, Set{Symbol}())
            if v === w
                (rk === nothing && isempty(ks)) && continue   # scalar self-fold
                (rk !== nothing && rk in ks) && continue
                _refuse!(ctx, :loop_read_write_overlap,
                    "loop reads `$v` at key `$(rk)` while writing keys $(sort!(collect(ks)))",
                    _src(st),
                    "a read of a loop-written container must be at a key the loop writes " *
                    "in the same iteration; restructure the loop")
            else
                (rf !== nothing && !(rf in fs) && !(:__whole__ in fs)) && continue
                (loopkey !== nothing && rk == loopkey && ks == Set([loopkey])) && continue
                _refuse!(ctx, :loop_read_write_overlap,
                    "loop writes `$w` while also reading `$v`, which this loop writes " *
                    "($(rf === nothing ? "whole value" : "field `$rf`"))",
                    _src(st),
                    "independent per-variable folds cannot see each other's writes; make " *
                    "the read field-disjoint from the writes, index both at the loop " *
                    "variable, or use a local counter (compiled as one ordered foldl)")
            end
        end
    end
    return
end

# writes: var -> (set of syntactic key strings, set of written fields; :__whole__
# marks scalar/whole-element writes).
function _collect_write_shapes!(ex, aliases, statesym, wkeys, wfields)
    if ex isa Expr
        if ex.head === :(=) || haskey(_EFF_OPASSIGN, ex.head)
            lhs = ex.args[1]
            if !(lhs isa Symbol)
                p = _chain_parts(_resolve(lhs, aliases), statesym)
                if p !== nothing
                    (v, keyexprs, leaf) = p
                    kk = get!(wkeys, v, Set{String}())
                    ff = get!(wfields, v, Set{Symbol}())
                    keyexprs === nothing || push!(kk, _key_string(keyexprs, aliases))
                    push!(ff, leaf === nothing ? :__whole__ : leaf)
                end
            end
        end
        for a in ex.args
            _collect_write_shapes!(a, aliases, statesym, wkeys, wfields)
        end
    end
    return
end

_key_string(keyexprs, aliases) =
    join((string(_resolve(k, aliases)) for k in keyexprs), ",")

# State reads of an expression: (var, keystring-or-nothing, field-or-nothing).
# field === nothing on an element read means "whole element" (overlaps any field).
function _expr_state_reads!(out, ex, aliases, statesym)
    r = _resolve(ex, aliases)
    if r isa Expr && (r.head === :. || r.head === :ref) && _access_root(r) === statesym
        p = _chain_parts(r, statesym)
        if p !== nothing
            (v, keyexprs, leaf) = p
            push!(out, (v, keyexprs === nothing ? nothing : _key_string(keyexprs, aliases), leaf))
            if keyexprs !== nothing
                for k in keyexprs
                    _expr_state_reads!(out, k, aliases, statesym)
                end
            end
            return
        end
    end
    if ex isa Expr
        for a in ex.args
            _expr_state_reads!(out, a, aliases, statesym)
        end
    end
    return
end

# Route reads: conditions and local bindings are shared (every fold sees them);
# an assignment's keys and rhs belong to its target var's fold.
function _collect_loop_reads!(ex, aliases, statesym, shared, perw)
    ex isa Expr || return
    if ex.head === :block || ex.head === :for
        start = ex.head === :for ? 2 : 1
        for a in ex.args[start:end]
            _collect_loop_reads!(a, aliases, statesym, shared, perw)
        end
    elseif ex.head === :if || ex.head === :elseif
        _expr_state_reads!(shared, ex.args[1], aliases, statesym)
        for a in ex.args[2:end]
            _collect_loop_reads!(a, aliases, statesym, shared, perw)
        end
    elseif ex.head === :(=) || haskey(_EFF_OPASSIGN, ex.head)
        lhs = ex.args[1]
        if lhs isa Symbol
            # local binding/alias: index subexprs and value reads are shared
            _expr_state_reads!(shared, ex.args[2], aliases, statesym)
        else
            p = _chain_parts(_resolve(lhs, aliases), statesym)
            sink = p !== nothing && haskey(perw, p[1]) ? perw[p[1]] : shared
            if p !== nothing && p[2] !== nothing
                for k in p[2]
                    _expr_state_reads!(sink, k, aliases, statesym)
                end
            end
            _expr_state_reads!(sink, ex.args[2], aliases, statesym)
            # op-assign reads its own lhs
            haskey(_EFF_OPASSIGN, ex.head) && p !== nothing &&
                push!(sink, (p[1], p[2] === nothing ? nothing : _key_string(p[2], aliases), p[3]))
        end
    elseif ex.head === :macrocall
        return
    else
        _expr_state_reads!(shared, ex, aliases, statesym)
    end
    return
end

########################### Local-accumulator fold (min-by / counter) ###########################

# A loop mutating only local accumulators: min-by argmin (D8) over an ordered
# range. Binds each accumulator local to a projection of a record `foldl`.
function _elocalfold!(ctx::_EmitCtx, st::Expr)
    header = st.args[1]
    var = header.args[1]
    body = Any[s for s in st.args[2].args if !(s isa LineNumberNode)]
    accs = _find_local_accs(ctx, body)
    isempty(accs) && return
    dom, lam, ordered = _ordered_domain(ctx, header.args[2])
    # D8 ruling: min-by over an unordered (dict-key/set) domain REFUSES in v1 —
    # `foldl` is List-only and the tie-break order is unspecified; no widening.
    ordered || _refuse!(ctx, :unordered_fold,
        "min-by/accumulator loop over an unordered domain", _src(st),
        "an ordered fold needs an array index range; a dict-key argmin has no " *
        "defined tie-break order (v1 refuses rather than widening)")
    inits = Dict{Symbol,String}(a => get(ctx.subst, a, "0") for a in accs)
    saved = (copy(ctx.subst), copy(ctx.aliases), copy(ctx.types))
    local update::String
    try
        for a in accs
            ctx.subst[a] = "acc." * string(a)
        end
        ctx.subst[var] = lam
        ctx.types[var] = Int
        update = _localfold_body(ctx, body, accs, var, lam)
    finally
        (ctx.subst, ctx.aliases, ctx.types) = saved
    end
    initrec = "{ " * join((string(a) * ": " * inits[a] for a in accs), ", ") * " }"
    fexpr = dom * ".foldl(" * initrec * ", (acc, " * lam * ") => " * update * ")"
    for a in accs
        ctx.subst[a] = "(" * fexpr * ")." * string(a)
        ctx.types[a] = nothing
    end
    return
end

# The accumulators mutated in the loop body (assigned inside AND known locals).
function _find_local_accs(ctx::_EmitCtx, body)
    accs = Symbol[]
    for st in body
        _find_accs!(accs, st, ctx)
    end
    return unique(accs)
end
function _find_accs!(accs, ex, ctx)
    if ex isa Expr
        if (ex.head === :(=) || haskey(_EFF_OPASSIGN, ex.head)) && ex.args[1] isa Symbol &&
           haskey(ctx.subst, ex.args[1])
            push!(accs, ex.args[1])
        end
        for a in ex.args
            _find_accs!(accs, a, ctx)
        end
    end
    return
end

# An ordered domain for a fold: array index range -> range(1, n+1); else keys()/set.
function _ordered_domain(ctx::_EmitCtx, range)
    if range isa Expr && range.head === :call
        nm = _callee_name(range.args[1])
        if nm === :eachindex && length(range.args) == 2
            c = range.args[2]
            if c isa Expr && c.head === :. && c.args[1] === ctx.statesym
                fi = _field_by_name(ctx.schema, _fieldsym(c.args[2]))
                if fi !== nothing && !isempty(fi.extent)
                    return ("range(1, " * string(fi.extent[1] + 1) * ")", "_i", true)
                end
                return (_qprint(ctx, c) * ".keys()", "_i", false)
            end
        elseif nm === :(:) && length(range.args) == 3
            lo = range.args[2]
            hi = range.args[3]
            # `1:length(state.c)` with a snapshot-known extent emits constant
            # bounds — Apalache requires a constant range (extent is fixed by
            # FixedExtentError, so this is sound).
            if hi isa Expr && hi.head === :call && _callee_name(hi.args[1]) === :length
                c = hi.args[2]
                if c isa Expr && c.head === :. && c.args[1] === ctx.statesym
                    fi = _field_by_name(ctx.schema, _fieldsym(c.args[2]))
                    if fi !== nothing && !isempty(fi.extent)
                        return ("range(" * _qprint(ctx, lo) * ", " *
                            string(fi.extent[1] + 1) * ")", "_i", true)
                    end
                end
            end
            return ("range(" * _qprint(ctx, lo) * ", (" * _qprint(ctx, hi) * ") + 1)",
                "_i", true)
        end
    end
    dom, kind, _ = _iter_domain(ctx, range)
    return (dom, "_i", false)
end

# Build the fold-update expression: `if (path) {updated record} else acc`.
function _localfold_body(ctx, body, accs, var, lam)
    hits = Tuple{Vector{Any},Dict{Symbol,Any}}[]
    _collect_localfold!(ctx, body, Any[], accs, hits)
    isempty(hits) && return "acc"
    expr = "acc"
    for (pc, updates) in reverse(hits)
        cond = isempty(pc) ? "true" :
            "(" * join((_qprint(ctx, _resolve(c, ctx.aliases)) for c in pc), " and ") * ")"
        rec = "{ " * join((string(a) * ": " *
            (haskey(updates, a) ? _qprint(ctx, _resolve(updates[a], ctx.aliases)) :
             "acc." * string(a)) for a in accs), ", ") * " }"
        expr = "(if " * cond * " " * rec * " else " * expr * ")"
    end
    return expr
end

function _collect_localfold!(ctx, stmts, pc, accs, hits)
    p = copy(pc)
    updates = Dict{Symbol,Any}()
    for st in stmts
        st isa LineNumberNode && continue
        if st isa Expr && st.head === :if
            _collect_localfold!(ctx, _blockstmts(st.args[2]), vcat(p, Any[st.args[1]]), accs, hits)
            length(st.args) >= 3 &&
                _collect_localfold!(ctx, _blockstmts(st.args[3]),
                    vcat(p, Any[Expr(:call, :!, st.args[1])]), accs, hits)
        elseif st isa Expr && st.head === :(=) && st.args[1] isa Symbol && st.args[1] in accs
            updates[st.args[1]] = st.args[2]
        elseif st isa Expr && st.head === :(=) && st.args[1] isa Symbol
            _bind_local!(ctx, st.args[1], st.args[2], nothing)
        end
    end
    isempty(updates) || push!(hits, (p, updates))
    return
end

########################### fire! recursion inlining ###########################

function _einline_fire!(ctx::_EmitCtx, args)
    ctor = args[1]
    (ctor isa Expr && ctor.head === :call) || _refuse!(ctx, :unsupported_call,
        "fire! recursion", _src(Expr(:call, :fire!, args...)), "the fired event is not a constructor")
    evtname = _callee_name(ctor.args[1])
    (evtname !== nothing && isdefined(ctx.mod, evtname)) || _refuse!(ctx, :unsupported_call,
        "fire!($evtname)", _src(ctor), "the fired event type is not defined")
    T = getfield(ctx.mod, evtname)
    hasmethod(fire_ast, Tuple{Type{T}}) || _refuse!(ctx, :no_fire, "fire!($evtname)", _src(ctor),
        "the recursed event has no @fire; cannot inline its effect")
    (evtsym_c, statesym_c, whensym_c, rngsym_c, body) = fire_ast(T)
    fnames = fieldnames(T)
    cargs = ctor.args[2:end]
    length(cargs) == length(fnames) || _refuse!(ctx, :unsupported_call, "fire!($evtname)",
        _src(ctor), "constructor arity mismatch")
    # substitute event fields -> caller expressions, α-rename the callee's evt/state
    fieldmap = Dict{Symbol,Any}(f => c for (f, c) in zip(fnames, cargs))
    newbody = _subst_fire(body, evtsym_c, statesym_c, ctx.statesym, fieldmap)
    _estmt!(ctx, newbody)
    return
end

# Substitute an inlined callee body: evt.field -> caller arg; callee state -> caller state.
function _subst_fire(ex, evtsym_c, statesym_c, statesym_caller, fieldmap)
    if ex isa Expr
        if ex.head === :. && ex.args[1] === evtsym_c
            f = _fieldsym(ex.args[2])
            haskey(fieldmap, f) && return fieldmap[f]
        end
        if ex === statesym_c
            return statesym_caller
        end
        return Expr(ex.head,
            (a === statesym_c ? statesym_caller :
             _subst_fire(a, evtsym_c, statesym_c, statesym_caller, fieldmap) for a in ex.args)...)
    elseif ex === statesym_c
        return statesym_caller
    end
    return ex
end

########################### Macro calls ###########################

function _emacrocall!(ctx::_EmitCtx, st::Expr)
    mname = st.args[1]
    nm = mname isa Symbol ? mname :
        (mname isa Expr && mname.head === :. && mname.args[2] isa QuoteNode ? mname.args[2].value : nothing)
    inner = st.args[3:end]
    if nm === Symbol("@obswrite") && length(inner) == 1 && inner[1] isa Expr && inner[1].head === :(=)
        return _eassign!(ctx, inner[1].args[1], inner[1].args[2])
    end
    # @assert / @debug / @info / @obsread: dropped (their args have no effect)
    return
end
