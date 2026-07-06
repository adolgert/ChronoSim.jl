# The Quint compiler — the pure-expression printer, loop classifier, and prelude.
#
# `_qprint(ctx, expr) -> String` lowers a pure Julia expression (already
# alias-resolved by the caller) to Quint text. It mirrors the guard.jl interpreter
# grammar (src/guard.jl) construct-for-construct; anything outside the fragment is
# a gathered refusal. Four callers: guard bodies, `@fragment` bodies, `@invariant`
# bodies, and every pure-expression position inside effect lowering. No `eval`.

########################### Emit context ###########################

# A refusal that aborts the current body; caught at the event/invariant boundary
# so `compile_quint` can gather refusals across subjects.
struct _BodyAbort <: Exception end

const _RefusalNT = NamedTuple{(:subject, :category, :construct, :source, :hint),
                              Tuple{Symbol,Symbol,String,String,String}}
const _WideningNT = NamedTuple{(:event, :reason, :source),Tuple{Symbol,String,String}}

mutable struct _EmitCtx
    schema::_QuintSchema
    mod::Module
    statesym::Symbol                 # state parameter name in the current body
    evtsym::Symbol                   # event parameter name (:__none__ for fragments/invariants)
    varenv::Dict{Symbol,String}      # physical field -> current Quint expr (mutated by effects)
    subst::Dict{Symbol,String}       # value locals / loop vars -> Quint expr
    aliases::Dict{Symbol,Any}        # local -> resolved Julia state chain
    types::Dict{Symbol,Any}          # local -> best-effort Julia type
    preludes::Set{Symbol}            # used prelude helper defs (_jabs, _jmod, ...)
    fragments::Set{Symbol}           # emitted @fragment def names (helper calls -> defs)
    preconds::Set{Symbol}            # event names whose precond_ def is needed
    globals::Set{Symbol}             # top-level Quint names (vars/consts/types/defs) to avoid
    evtfieldtypes::Dict{Symbol,Any}  # event field -> Julia type (for inference)
    fragsigs::Dict{Symbol,Vector{String}}  # fragment -> param Quint types (shared, accumulated)
    nondets::Vector{String}          # lifted rand/nondet lines (effects)
    ssa::Dict{Symbol,Int}            # rebind counters for SSA renaming
    # refusals / diagnostics
    subject::Symbol
    refusals::Vector{_RefusalNT}
    widenings::Vector{_WideningNT}
    # mutation hook (D16)
    mutation::Union{Nothing,NamedTuple}
    mut_count::Int
end

function _EmitCtx(schema, mod, statesym, evtsym; subject=:__body__, globals=Set{Symbol}(),
                  evtfieldtypes=Dict{Symbol,Any}(), fragsigs=Dict{Symbol,Vector{String}}(),
                  refusals=_RefusalNT[], widenings=_WideningNT[], mutation=nothing)
    varenv = Dict{Symbol,String}()
    for f in schema.fields
        if f.kind in (:scalar, :array1, :arrayN, :dict, :set, :const)
            varenv[f.name] = string(f.emit)
        end
    end
    _EmitCtx(schema, mod, statesym, evtsym, varenv, Dict{Symbol,String}(),
        Dict{Symbol,Any}(), Dict{Symbol,Any}(), Set{Symbol}(), Set{Symbol}(),
        Set{Symbol}(), Set{Symbol}(globals), evtfieldtypes, fragsigs,
        String[], Dict{Symbol,Int}(), subject, refusals, widenings, mutation, 0)
end

# A lambda/loop variable name that avoids colliding with a top-level Quint name.
_gsan(ctx::_EmitCtx, base::Symbol) =
    (s = _sanitize(base); s in ctx.globals ? Symbol(string(s), "_l") : s)

# An event-field parameter name, renamed on collision with a top-level Quint name.
_evtparam(globals, field::Symbol) =
    (s = _sanitize(field); s in globals ? Symbol(string(s), "_p") : s)

function _refuse!(ctx::_EmitCtx, category::Symbol, construct::AbstractString,
                  source::AbstractString, hint::AbstractString)
    push!(ctx.refusals, (subject=ctx.subject, category=category, construct=String(construct),
        source=String(source), hint=String(hint)))
    throw(_BodyAbort())
end

# NOTE (v1 ruling): every case the design allowed to WIDEN (dict-key argmin
# tie-breaks, non-uniform draw supports) REFUSES instead — stricter than the plan
# requires, and no silent over-approximation. `ctx.widenings`/`report.widenings`
# stay as the reserved surface (always empty in v1); the reconciliation test pins
# `// WIDENED` marker count == length(report.widenings) == 0.

_src(ex) = replace(string(ex isa Expr ? Base.remove_linenums!(copy(ex)) : ex), r"\s+" => " ")

########################### Type inference (best effort) ###########################

# Infer the Julia type of a lowered expression (for collapse `.field` and tuple
# `k[i]` decisions). Returns a Type or `nothing`.
function _infer_type(ctx::_EmitCtx, ex)
    if ex isa Symbol
        haskey(ctx.types, ex) && return ctx.types[ex]
        return nothing
    elseif ex isa Expr
        if ex.head === :.
            a = ex.args[1]
            if a === ctx.statesym
                return nothing   # container types come via _infer_type_container
            elseif a === ctx.evtsym
                return get(ctx.evtfieldtypes, _fieldsym(ex.args[2]), nothing)
            else
                at = _infer_type(ctx, a)
                if at !== nothing && _is_record_type(at)
                    fn = _fieldsym(ex.args[2])
                    fn in fieldnames(at) && return fieldtype(at, fn)
                end
                return nothing
            end
        elseif ex.head === :ref
            a = ex.args[1]
            at = _infer_type_container(ctx, a)
            return at
        elseif ex.head === :call
            nm = _callee_name(ex.args[1])
            if nm !== nothing && _is_fragment_call(ctx, nm)
                return _infer_frag_ret(ctx.mod, nm)
            end
        elseif ex.head === :if || ex.head === :elseif
            t = _infer_type(ctx, ex.args[2])
            return t !== nothing ? t : (length(ex.args) >= 3 ? _infer_type(ctx, ex.args[3]) : nothing)
        end
    end
    return nothing
end

# Best-effort return type of a @fragment helper (for typing its callers' locals).
function _infer_frag_ret(mod::Module, fname::Symbol)
    isdefined(mod, fname) || return nothing
    f = getfield(mod, fname)
    hasmethod(fragment_ast, Tuple{typeof(f)}) || return nothing
    (_params, body) = fragment_ast(f)
    _, ret = _split_body(body)
    return _guess_ret_type(mod, ret)
end

function _guess_ret_type(mod::Module, ex)
    if ex isa Symbol && isdefined(mod, ex) && isconst(mod, ex)
        v = getfield(mod, ex)
        v isa Base.Enum && return typeof(v)
    elseif ex isa Bool
        return Bool
    elseif ex isa Expr
        if ex.head === :if || ex.head === :elseif
            t = _guess_ret_type(mod, ex.args[2])
            return t !== nothing ? t :
                (length(ex.args) >= 3 ? _guess_ret_type(mod, ex.args[3]) : nothing)
        elseif ex.head in (:&&, :||, :comparison) ||
               (ex.head === :call && _callee_name(ex.args[1]) in (:!, :(==), :(!=), :<, :(<=), :>, :(>=)))
            return Bool
        end
    end
    return nothing
end

# The element type produced by indexing `container[...]`.
function _infer_type_container(ctx::_EmitCtx, a)
    if a isa Expr && a.head === :. && a.args[1] === ctx.statesym
        f = _fieldsym(a.args[2])
        fi = _field_by_name(ctx.schema, f)
        fi === nothing && return nothing
        return fi.eltype
    end
    t = _infer_type(ctx, a)
    return t
end

_is_collapsed(ctx::_EmitCtx, T) =
    T !== nothing && _is_record_type(T) &&
    (ri = get(ctx.schema.records, nameof(T), nothing); ri !== nothing && ri.collapsed)

########################### Symbol lowering ###########################

function _qsym(ctx::_EmitCtx, s::Symbol)
    haskey(ctx.subst, s) && return ctx.subst[s]
    haskey(ctx.aliases, s) && return _qprint(ctx, ctx.aliases[s])
    if s === ctx.statesym
        _refuse!(ctx, :unsupported_node, "bare state reference `$s`", _src(s),
            "read a specific field of the state, not the whole state object")
    end
    # module const: enum instance or numeric/bool literal
    if isdefined(ctx.mod, s) && isconst(ctx.mod, s)
        v = getfield(ctx.mod, s)
        v isa Base.Enum && return String(Symbol(v))
        v isa Bool && return v ? "true" : "false"
        v isa Integer && return string(v)
    end
    _refuse!(ctx, :unsupported_node, "symbol `$s`", _src(s),
        "not a local binding, event field, enum value, or integer/bool constant")
end

########################### The printer ###########################

function _qprint(ctx::_EmitCtx, ex)
    if ex isa Bool
        return ex ? "true" : "false"
    elseif ex isa Integer
        return string(ex)
    elseif ex isa Symbol
        return _qsym(ctx, ex)
    elseif ex isa QuoteNode
        return _qprint(ctx, ex.value)
    elseif ex isa AbstractString || ex isa Char
        _refuse!(ctx, :unsupported_node, "string/char literal `$(repr(ex))`", _src(ex),
            "the compiled fragment has no string state")
    elseif ex isa AbstractFloat
        _refuse!(ctx, :float_read, "float literal `$ex`", _src(ex),
            "the compiled spec is integer-only")
    elseif ex isa Expr
        return _qexpr(ctx, ex)
    else
        _refuse!(ctx, :unsupported_node, "literal `$(repr(ex))`", _src(ex), "unsupported literal")
    end
end

function _qexpr(ctx::_EmitCtx, ex::Expr)
    h = ex.head
    if h === :.
        return _qdot(ctx, ex)
    elseif h === :ref
        return _qref(ctx, ex)
    elseif h === :call
        return _qcall(ctx, ex)
    elseif h === :&&
        return "(" * _qprint(ctx, ex.args[1]) * " and " * _qprint(ctx, ex.args[2]) * ")"
    elseif h === :||
        return "(" * _qprint(ctx, ex.args[1]) * " or " * _qprint(ctx, ex.args[2]) * ")"
    elseif h === :comparison
        return _qcomparison(ctx, ex)
    elseif h === :if || h === :elseif
        c = _qprint(ctx, ex.args[1])
        a = _qprint(ctx, ex.args[2])
        b = length(ex.args) >= 3 ? _qprint(ctx, ex.args[3]) : "true"
        return "(if (" * c * ") " * a * " else " * b * ")"
    elseif h === :tuple
        return "(" * join((_qprint(ctx, a) for a in ex.args), ", ") * ")"
    elseif h === :block
        return _qblock(ctx, ex)
    elseif h === :generator || h === :comprehension
        _refuse!(ctx, :unsupported_node, "bare comprehension", _src(ex),
            "comprehensions are only supported as a reducer argument (any/all/count/...)")
    elseif h === :vect
        # a set/vector literal used as a value (e.g. Set arg); lower elements
        return "Set(" * join((_qprint(ctx, a) for a in ex.args), ", ") * ")"
    elseif h === :while
        _refuse!(ctx, :while_loop, "while loop", _src(ex), "unbounded loops are unsupported")
    elseif h === :return
        _refuse!(ctx, :early_return, "return", _src(ex),
            "a body is a straight-line prelude plus one returned expression")
    else
        _refuse!(ctx, :unsupported_node, "node `$(h)`", _src(ex),
            "outside the compilable fragment")
    end
end

# A single-expression block (a `val x = e  rest` let chain, or a bare expr).
function _qblock(ctx::_EmitCtx, ex::Expr)
    stmts = Any[a for a in ex.args if !(a isa LineNumberNode)]
    length(stmts) == 1 && return _qprint(ctx, stmts[1])
    # let-chain: emit leading local bindings, then the final expression.
    lets = String[]
    saved = (copy(ctx.subst), copy(ctx.aliases), copy(ctx.types))
    for st in stmts[1:end-1]
        if st isa Expr && st.head === :(=) && st.args[1] isa Symbol
            _bind_local!(ctx, st.args[1], st.args[2], lets)
        else
            _refuse!(ctx, :unsupported_node, "block statement `$(_src(st))`", _src(st),
                "only local bindings may precede the value of a block")
        end
    end
    final = _qprint(ctx, stmts[end])
    (ctx.subst, ctx.aliases, ctx.types) = saved
    return isempty(lets) ? final : "(" * join(lets, "  ") * "  " * final * ")"
end

# `a.field`
function _qdot(ctx::_EmitCtx, ex::Expr)
    a = ex.args[1]
    field = _fieldsym(ex.args[2])
    if a === ctx.statesym
        return _qstate_field(ctx, field)
    elseif a === ctx.evtsym
        return string(_evtparam(ctx.globals, field))
    end
    at = _infer_type(ctx, a)
    if at !== nothing && _is_record_type(at) && field in fieldnames(at)
        _is_float_type(fieldtype(at, field)) && _refuse!(ctx, :float_read,
            "$(ctx.subject) reads `.$field` of type $(fieldtype(at, field))", _src(ex), _FLOAT_HINT)
        ri = get(ctx.schema.records, nameof(at), nothing)
        ri !== nothing && field in ri.dropped && _refuse!(ctx, :unsupported_state,
            "$(ctx.subject) reads erased field `.$field`", _src(ex),
            "this field's type is not represented in the spec (dropped from record $(nameof(at)))")
    end
    inner = _qprint(ctx, a)
    if _is_collapsed(ctx, at)
        return inner   # collapsed single-field record: the value IS the field
    end
    return inner * "." * string(_sanitize(field))
end

# Reading a physical field `state.f`.
function _qstate_field(ctx::_EmitCtx, f::Symbol)
    fi = _field_by_name(ctx.schema, f)
    fi === nothing && _refuse!(ctx, :unsupported_state, "state field `$f`", string(f),
        "no such physical field")
    if fi.kind === :erased
        _is_float_type(fi.eltype) || _is_float_leaf(ctx.schema.records, fi.eltype) ?
            _refuse!(ctx, :float_read,
                "$(ctx.subject) reads `$(ctx.statesym).$f` of type $(fi.eltype)", string(f),
                _FLOAT_HINT) :
            _refuse!(ctx, :unsupported_state, "erased field `$f`", string(f),
                "this field is not represented in the spec")
    end
    return get(ctx.varenv, f, string(fi.emit))
end

const _FLOAT_HINT = """The compiled spec models the discrete jump skeleton of the GSMP: \
integer/Bool/enum/set state only. Continuous quantities (firing times, rates, ages) are \
erased: they parameterize WHEN events fire, never WHETHER a guard holds. If this float \
genuinely gates discrete behavior, model the gate as an integer/enum field; otherwise pass \
skip_events=[:<Event>] and record the skip."""

# `container[keys...]`
function _qref(ctx::_EmitCtx, ex::Expr)
    a = ex.args[1]
    keys = ex.args[2:end]
    at = _infer_type_container(ctx, a)
    ct = _infer_type(ctx, a)
    inner = _qprint(ctx, a)
    # tuple component access k[i]
    if ct !== nothing && ct <: Tuple && length(keys) == 1 && keys[1] isa Integer
        return inner * "._" * string(keys[1])
    end
    keystr = length(keys) == 1 ? _qprint(ctx, keys[1]) :
        "(" * join((_qprint(ctx, k) for k in keys), ", ") * ")"
    return inner * ".get(" * keystr * ")"
end

########################### Comparisons & operators ###########################

const _CMP_MAP = Dict{Symbol,String}(
    :(==) => "==", :(!=) => "!=", :≠ => "!=", :< => "<", :(<=) => "<=", :≤ => "<=",
    :> => ">", :(>=) => ">=", :≥ => ">=",
)
const _ARITH_MAP = Dict{Symbol,String}(:+ => "+", :- => "-", :* => "*", :^ => "^")

# Apply the mutation hook (D16) to a comparison operator symbol.
function _maybe_mutate(ctx::_EmitCtx, opsym::Symbol)
    m = ctx.mutation
    (m === nothing || ctx.subject !== m.event || opsym !== m.from) && return opsym
    ctx.mut_count += 1
    return ctx.mut_count == m.occurrence ? m.to : opsym
end

function _qcomparison(ctx::_EmitCtx, ex::Expr)
    args = ex.args
    parts = String[]
    i = 1
    while i + 2 <= length(args)
        op = _maybe_mutate(ctx, args[i+1])
        haskey(_CMP_MAP, op) || _refuse!(ctx, :unsupported_call, "comparison `$(args[i+1])`",
            _src(ex), "not an arithmetic comparison")
        push!(parts, _qprint(ctx, args[i]) * " " * _CMP_MAP[op] * " " * _qprint(ctx, args[i+2]))
        i += 2
    end
    return "(" * join(parts, " and ") * ")"
end

function _qcall(ctx::_EmitCtx, ex::Expr)
    callee = ex.args[1]
    name = _callee_name(callee)
    args = ex.args[2:end]
    name === nothing && _refuse!(ctx, :unsupported_call, "call `$(_src(callee))`", _src(ex),
        "the callee is not a plain name")

    # comparison / arithmetic / boolean operators
    if haskey(_CMP_MAP, name)
        op = _maybe_mutate(ctx, name)
        return "(" * _qprint(ctx, args[1]) * " " * _CMP_MAP[op] * " " * _qprint(ctx, args[2]) * ")"
    end
    if haskey(_ARITH_MAP, name)
        length(args) == 1 && name === :- && return "(-" * _qprint(ctx, args[1]) * ")"
        return "(" * join((_qprint(ctx, a) for a in args), " " * _ARITH_MAP[name] * " ") * ")"
    end
    r = _qcall_special(ctx, name, args, ex)
    r === nothing || return r
    # @fragment helper
    if _is_fragment_call(ctx, name)
        push!(ctx.fragments, name)
        haskey(ctx.fragsigs, name) ||
            (ctx.fragsigs[name] = String[_arg_quint_type(ctx, a) for a in args])
        return string(_sanitize(name)) * "(" * join((_qprint(ctx, a) for a in args), ", ") * ")"
    end
    _refuse!(ctx, :unsupported_call, "call to `$name`", _src(ex),
        "not an operator, whitelisted read, reducer, @fragment helper, or precondition-recursion")
end

# Special-form calls; returns nothing to fall through.
function _qcall_special(ctx::_EmitCtx, name::Symbol, args, ex::Expr)
    if name === :÷ || name === :div
        return "(" * _qprint(ctx, args[1]) * " / " * _qprint(ctx, args[2]) * ")"
    elseif name === :/
        _refuse!(ctx, :float_read, "integer `/`", _src(ex), "use `÷` for integer division")
    elseif name === :%  || name === :rem
        return "(" * _qprint(ctx, args[1]) * " % " * _qprint(ctx, args[2]) * ")"
    elseif name === :mod
        push!(ctx.preludes, :_jmod)
        return "_jmod(" * _qprint(ctx, args[1]) * ", " * _qprint(ctx, args[2]) * ")"
    elseif name === :abs
        push!(ctx.preludes, :_jabs)
        return "_jabs(" * _qprint(ctx, args[1]) * ")"
    elseif name === :min
        push!(ctx.preludes, :_jmin)
        return "_jmin(" * _qprint(ctx, args[1]) * ", " * _qprint(ctx, args[2]) * ")"
    elseif name === :max
        push!(ctx.preludes, :_jmax)
        return "_jmax(" * _qprint(ctx, args[1]) * ", " * _qprint(ctx, args[2]) * ")"
    elseif name === :!
        return "not(" * _qprint(ctx, args[1]) * ")"
    elseif name === :& || name === :|
        _check_bool_bitop(ctx, name, args, ex)
        op = name === :& ? " and " : " or "
        return "(" * join((_qprint(ctx, a) for a in args), op) * ")"
    elseif name === :xor || name === :⊻
        _check_bool_bitop(ctx, name, args, ex)
        return "(" * _qprint(ctx, args[1]) * " != " * _qprint(ctx, args[2]) * ")"
    elseif name === :~
        t = _bitop_arg_type(ctx, args[1])
        t === Bool && return "not(" * _qprint(ctx, args[1]) * ")"
        _refuse!(ctx, :bitwise_int, "bitwise `~` on `$(_src(args[1]))`", _src(ex),
            "integer bit manipulation is outside the compiled fragment")
    elseif name === :length || name === :size
        return _qsize(ctx, args[1])
    elseif name === :isempty
        return "(" * _qsize(ctx, args[1]) * " == 0)"
    elseif name === :haskey
        return _qprint(ctx, args[1]) * ".keys().contains(" * _qprint(ctx, args[2]) * ")"
    elseif name === :in || name === :∈
        return _qin(ctx, args[1], args[2])
    elseif name === :get && length(args) == 3
        c = _qprint(ctx, args[1]); k = _qprint(ctx, args[2]); d = _qprint(ctx, args[3])
        return "(if (" * c * ".keys().contains(" * k * ")) " * c * ".get(" * k * ") else " * d * ")"
    elseif name === :keys
        return _qprint(ctx, args[1]) * ".keys()"
    elseif name === :Set
        return _qset(ctx, args)
    elseif name === :setdiff || name === :union || name === :intersect || name === :symdiff
        return _qsetop(ctx, name, args)
    elseif name === :(:) && length(args) == 2
        return _qprint(ctx, args[1]) * ".to(" * _qprint(ctx, args[2]) * ")"
    elseif name === :precondition && length(args) == 2 && args[1] isa Expr && args[1].head === :call
        return _qprecond_call(ctx, args)
    elseif name in _REDUCER_NAMES && length(args) == 1 &&
           (_is_gen_arg(args[1]) || (args[1] isa Expr && args[1].head === :flatten))
        return _qreducer(ctx, name, args[1], ex)
    elseif name === :get! || name === :collect
        name === :collect && return _qprint(ctx, args[1])   # identity in set context
        _refuse!(ctx, :unsupported_call, "get!", _src(ex), "get! mutates; not allowed in a pure position")
    end
    return nothing
end

const _REDUCER_NAMES = Set{Symbol}([:any, :all, :count, :sum, :prod, :minimum, :maximum])

# `& | ⊻ xor ~` lower to and/or/!=/not on Bool operands; a provably-Int operand
# is integer bit manipulation -> `:bitwise_int` (construct-table row).
function _bitop_arg_type(ctx::_EmitCtx, a)
    a isa Bool && return Bool
    a isa Integer && return Int
    t = _infer_type(ctx, a)
    t === nothing && a isa Expr && (a.head === :comparison || a.head === :&& ||
        a.head === :|| || (a.head === :call &&
        _callee_name(a.args[1]) in (:!, :(==), :(!=), :<, :(<=), :>, :(>=), :≠, :≤, :≥, :in, :∈, :haskey))) &&
        return Bool
    return t
end

function _check_bool_bitop(ctx::_EmitCtx, name::Symbol, args, ex::Expr)
    for a in args
        t = _bitop_arg_type(ctx, a)
        if t !== nothing && t !== Bool && t isa Type && t <: Integer
            _refuse!(ctx, :bitwise_int, "bitwise `$name` on integer `$(_src(a))`", _src(ex),
                "integer bit manipulation is outside the compiled fragment; " *
                "use Bool operands (lowered to and/or) or arithmetic")
        end
    end
    return nothing
end

# `.size()` for a container read; `.keys().size()` for maps.
function _qsize(ctx::_EmitCtx, c)
    t = _infer_type(ctx, c)
    inner = _qprint(ctx, c)
    # a state map field or a set?
    if c isa Expr && c.head === :. && c.args[1] === ctx.statesym
        fi = _field_by_name(ctx.schema, _fieldsym(c.args[2]))
        fi !== nothing && fi.kind in (:array1, :arrayN, :dict) && return inner * ".keys().size()"
        fi !== nothing && fi.kind === :set && return inner * ".size()"
    end
    # a local set or lowered set
    return inner * ".size()"
end

# `x in S`
function _qin(ctx::_EmitCtx, x, S)
    if S isa Expr && S.head === :call && _callee_name(S.args[1]) === :(:) && length(S.args) == 3
        xs = _qprint(ctx, x)
        return "(" * _qprint(ctx, S.args[2]) * " <= " * xs * " and " * xs * " <= " *
            _qprint(ctx, S.args[3]) * ")"
    end
    if S isa Expr && S.head === :call && _callee_name(S.args[1]) === :keys
        return _qprint(ctx, S.args[1]) * ".keys().contains(" * _qprint(ctx, x) * ")"
    end
    return _qprint(ctx, S) * ".contains(" * _qprint(ctx, x) * ")"
end

# `Set(...)`: `Set(a)` -> `Set(a)`; `Set(collect(a:b))` -> `a.to(b)`; `Set{T}()` -> `Set()`.
function _qset(ctx::_EmitCtx, args)
    isempty(args) && return "Set()"
    if length(args) == 1
        a = args[1]
        if a isa Expr && a.head === :call && _callee_name(a.args[1]) === :collect
            inner = a.args[2]
            if inner isa Expr && inner.head === :call && _callee_name(inner.args[1]) === :(:)
                return _qprint(ctx, inner.args[2]) * ".to(" * _qprint(ctx, inner.args[3]) * ")"
            end
            return _qprint(ctx, inner)
        end
        if a isa Expr && a.head === :call && _callee_name(a.args[1]) === :(:)
            return _qprint(ctx, a.args[2]) * ".to(" * _qprint(ctx, a.args[3]) * ")"
        end
    end
    return "Set(" * join((_qprint(ctx, a) for a in args), ", ") * ")"
end

# setdiff/union/intersect/symdiff, wrapping a scalar 2nd arg in Set(...).
function _qsetop(ctx::_EmitCtx, name::Symbol, args)
    a = _qprint(ctx, args[1])
    b = _qsetop_arg(ctx, args[2])
    if name === :union
        return a * ".union(" * b * ")"
    elseif name === :setdiff
        return a * ".exclude(" * b * ")"
    elseif name === :intersect
        return a * ".intersect(" * b * ")"
    else
        push!(ctx.preludes, :_jsymdiff)
        return "_jsymdiff(" * a * ", " * b * ")"
    end
end

# A set-op second operand: a set expression stays, a scalar is wrapped in Set(x)
# (Julia treats a number as iterable — MAPPING row 7).
function _qsetop_arg(ctx::_EmitCtx, a)
    t = _infer_type(ctx, a)
    if (t !== nothing && (t <: AbstractSet || t <: ObservedSet)) ||
       (a isa Expr && a.head === :call && _callee_name(a.args[1]) in (:Set, :union, :setdiff, :intersect)) ||
       (a isa Expr && a.head === :. && a.args[1] === ctx.statesym &&
        (fi = _field_by_name(ctx.schema, _fieldsym(a.args[2])); fi !== nothing && fi.kind === :set))
        return _qprint(ctx, a)
    end
    return "Set(" * _qprint(ctx, a) * ")"
end

_is_fragment_call(ctx::_EmitCtx, name::Symbol) =
    isdefined(ctx.mod, name) && (f = getfield(ctx.mod, name);
        f isa Function && hasmethod(fragment_ast, Tuple{typeof(f)}))

# Best-effort Quint type of a call argument (for fragment param signatures).
function _arg_quint_type(ctx::_EmitCtx, a)
    if a isa Expr && a.head === :. && a.args[1] === ctx.statesym
        fi = _field_by_name(ctx.schema, _fieldsym(a.args[2]))
        fi !== nothing && fi.quinttype != "" && return fi.quinttype
    end
    # an aliased local pointing at a state container
    if a isa Symbol && haskey(ctx.aliases, a)
        r = ctx.aliases[a]
        if r isa Expr && r.head === :. && r.args[1] === ctx.statesym
            fi = _field_by_name(ctx.schema, _fieldsym(r.args[2]))
            fi !== nothing && fi.quinttype != "" && return fi.quinttype
        end
    end
    t = _infer_type(ctx, a)
    if t !== nothing
        try
            return _lower_value_type(ctx.schema, t)
        catch
        end
    end
    return "int"   # fallback; refined by Quint's own inference if wrong
end

########################### Precondition-recursion (D12) ###########################

# `precondition(Evt(cargs...), state)` -> `precond_Evt(<read vars>, <cargs>)`.
function _qprecond_call(ctx::_EmitCtx, args)
    ctor = args[1]
    evtname = _callee_name(ctor.args[1])
    evtname === nothing && _refuse!(ctx, :unsupported_call, "precondition(...)",
        _src(Expr(:call, :precondition, args...)), "the recursed event is not a plain constructor")
    push!(ctx.preconds, evtname)
    cargs = ctor.args[2:end]
    readvars = _precond_read_vars(ctx.schema, ctx.mod, evtname)
    varargs = String[get(ctx.varenv, v, string(_sanitize(v))) for v in readvars]
    fieldargs = String[_qprint(ctx, a) for a in cargs]
    return "precond_" * string(evtname) * "(" * join(vcat(varargs, fieldargs), ", ") * ")"
end

# Var fields (schema order) a precondition body transitively reads. Cached per model.
function _precond_read_vars(schema::_QuintSchema, mod::Module, evtname::Symbol)
    T = getfield(mod, evtname)
    hasmethod(precondition_ast, Tuple{Type{T}}) || return _var_fields(schema)
    (_evtsym, statesym, body) = precondition_ast(T)
    read = Set{Symbol}()
    _collect_state_reads!(read, body, statesym)
    # transitively include reads of any precondition-recursed callees
    _collect_recursed_reads!(read, body, statesym, mod, Set{Symbol}([evtname]))
    return Symbol[f for f in _var_fields(schema) if f in read]
end

function _collect_state_reads!(read::Set{Symbol}, ex, statesym::Symbol)
    if ex isa Expr
        if ex.head === :. && ex.args[1] === statesym
            push!(read, _fieldsym(ex.args[2]))
        elseif ex.head === :ref && ex.args[1] isa Expr && ex.args[1].head === :. &&
               ex.args[1].args[1] === statesym
            push!(read, _fieldsym(ex.args[1].args[2]))
        end
        for a in ex.args
            _collect_state_reads!(read, a, statesym)
        end
    end
    return read
end

function _collect_recursed_reads!(read, ex, statesym, mod, seen)
    if ex isa Expr
        if ex.head === :call && _callee_name(ex.args[1]) === :precondition &&
           length(ex.args) == 3 && ex.args[2] isa Expr && ex.args[2].head === :call
            en = _callee_name(ex.args[2].args[1])
            if en !== nothing && !(en in seen) && isdefined(mod, en)
                push!(seen, en)
                T = getfield(mod, en)
                if hasmethod(precondition_ast, Tuple{Type{T}})
                    (_e, ss, body) = precondition_ast(T)
                    _collect_state_reads!(read, body, ss)
                    _collect_recursed_reads!(read, body, ss, mod, seen)
                end
            end
        end
        for a in ex.args
            _collect_recursed_reads!(read, a, statesym, mod, seen)
        end
    end
    return read
end

########################### Reducers over generators ###########################

# `any/all/count/sum/... (body for v in R [if cond])` -> exists/forall/filter/fold.
# Normalize any generator (comprehension / multi-spec / :flatten) to (body, specs).
function _gen_body_specs(genarg)
    g = genarg.head === :comprehension ? genarg.args[1] : genarg
    specs = Any[]
    while g isa Expr && g.head === :flatten
        g = g.args[1]                 # a :generator (body-or-inner, outerspec)
        push!(specs, g.args[2])
        g = g.args[1]
    end
    if g isa Expr && g.head === :generator
        append!(specs, g.args[2:end])
        return (g.args[1], specs)
    end
    return (g, specs)
end

function _qreducer(ctx::_EmitCtx, name::Symbol, genarg, ex::Expr)
    body, specs = _gen_body_specs(genarg)
    if length(specs) > 1
        (name === :any || name === :all) || _refuse!(ctx, :unsupported_node,
            "multi-clause `$name` generator", _src(ex),
            "only any/all support multiple iteration clauses (nested quantifiers)")
        return _qnested_quant(ctx, name, body, specs, ex)
    end
    spec = specs[1]
    cond = nothing
    if spec isa Expr && spec.head === :filter
        cond = spec.args[1]
        spec = spec.args[end]
    end
    (spec isa Expr && spec.head === :(=)) || _refuse!(ctx, :unsupported_node,
        "generator spec `$(_src(spec))`", _src(ex), "unsupported iteration spec")
    var = spec.args[1]
    dom, lam, saved = _enter_domain!(ctx, var, spec.args[2])
    try
        if name === :any
            return dom * ".exists(" * lam * " => " * _qprint(ctx, _to_bool(body, cond)) * ")"
        elseif name === :all
            return dom * ".forall(" * lam * " => " * _qprint(ctx, _to_bool(body, cond)) * ")"
        elseif name === :count
            filt = cond === nothing ? body : cond
            return dom * ".filter(" * lam * " => " * _qprint(ctx, filt) * ").size()"
        elseif name === :sum
            inner = cond === nothing ? dom :
                dom * ".filter(" * lam * " => " * _qprint(ctx, cond) * ")"
            return inner * ".fold(0, (_acc, " * lam * ") => _acc + " * _qprint(ctx, body) * ")"
        else
            _refuse!(ctx, :unsupported_call, "reducer `$name`", _src(ex),
                "only any/all/count/sum are supported over generators")
        end
    finally
        _exit_domain!(ctx, saved)
    end
end

# any(P) with a filter is `exists(v => filtercond and P)`.
_to_bool(body, cond) = cond === nothing ? body : Expr(:&&, cond, body)

# Nested quantifiers for a multi-iterspec any/all generator.
function _qnested_quant(ctx::_EmitCtx, name::Symbol, body, specs, ex::Expr)
    if isempty(specs)
        return _qprint(ctx, body)
    end
    spec = specs[1]
    cond = nothing
    if spec isa Expr && spec.head === :filter
        cond = spec.args[1]
        spec = spec.args[end]
    end
    (spec isa Expr && spec.head === :(=)) || _refuse!(ctx, :unsupported_node,
        "generator spec `$(_src(spec))`", _src(ex), "unsupported iteration spec")
    var = spec.args[1]
    dom, lam, saved = _enter_domain!(ctx, var, spec.args[2])
    try
        inner = _qnested_quant(ctx, name, body, specs[2:end], ex)
        if cond !== nothing
            cstr = _qprint(ctx, cond)
            inner = name === :any ? "(" * cstr * " and " * inner * ")" :
                "(not(" * cstr * ") or " * inner * ")"
        end
        quant = name === :any ? "exists" : "forall"
        return dom * "." * quant * "(" * lam * " => " * inner * ")"
    finally
        _exit_domain!(ctx, saved)
    end
end

########################### Iteration domains ###########################

# Bind a loop/generator variable over its domain. Returns
# (domain_string, lambda_variable_string, saved_env).
function _enter_domain!(ctx::_EmitCtx, var, range)
    saved = (copy(ctx.subst), copy(ctx.aliases), copy(ctx.types))
    dom, kind, container = _iter_domain(ctx, range)
    if kind === :values && var isa Expr && var.head === :tuple
        # `for (k, v) in dict`: pair iteration
        lam = _bind_pair!(ctx, var, container)
        return (dom, lam, saved)
    elseif kind === :values
        # `for v in state.container`: iterate keys, bind v -> container.get(kv)
        et = _element_type(ctx, container)
        kv = string(var isa Symbol ? _sanitize(var) : :_k) * "k"
        ctx.subst[var] = _qprint(ctx, container) * ".get(" * kv * ")"
        ctx.types[var] = et
        return (dom, kv, saved)
    elseif kind === :pairs
        lam = _bind_pair!(ctx, var, container)
        return (dom, lam, saved)
    else
        lam = var isa Symbol ? string(_gsan(ctx, var)) : "_k"
        if var isa Symbol
            ctx.subst[var] = lam
            ctx.types[var] = kind === :indices ? Int : nothing
        end
        return (dom, lam, saved)
    end
end

_exit_domain!(ctx::_EmitCtx, saved) = ((ctx.subst, ctx.aliases, ctx.types) = saved; nothing)

function _element_type(ctx::_EmitCtx, container)
    container === nothing && return nothing
    if container isa Expr && container.head === :. && container.args[1] === ctx.statesym
        fi = _field_by_name(ctx.schema, _fieldsym(container.args[2]))
        return fi === nothing ? nothing : fi.eltype
    end
    return nothing
end

function _key_type(ctx::_EmitCtx, container)
    container === nothing && return nothing
    if container isa Expr && container.head === :. && container.args[1] === ctx.statesym
        fi = _field_by_name(ctx.schema, _fieldsym(container.args[2]))
        return fi === nothing ? nothing : fi.keytype
    end
    return nothing
end

# Determine the Quint domain of a Julia range/container expression.
function _iter_domain(ctx::_EmitCtx, range)
    if range isa Expr && range.head === :call
        nm = _callee_name(range.args[1])
        if nm === :eachindex && length(range.args) == 2
            return (_qprint(ctx, range.args[2]) * ".keys()", :indices, range.args[2])
        elseif nm === :(:) && length(range.args) == 3
            lo = range.args[2]; hi = range.args[3]
            if hi isa Expr && hi.head === :call && _callee_name(hi.args[1]) === :length
                return (_qprint(ctx, hi.args[2]) * ".keys()", :indices, hi.args[2])
            end
            return (_qprint(ctx, lo) * ".to(" * _qprint(ctx, hi) * ")", :ints, nothing)
        elseif nm === :keys && length(range.args) == 2
            return (_qprint(ctx, range.args[2]) * ".keys()", :keys, range.args[2])
        elseif nm === :values && length(range.args) == 2
            return (_qprint(ctx, range.args[2]) * ".keys()", :values, range.args[2])
        end
    end
    # a direct state container -> iterate its elements
    if range isa Expr && range.head === :. && range.args[1] === ctx.statesym
        fi = _field_by_name(ctx.schema, _fieldsym(range.args[2]))
        if fi !== nothing && fi.kind in (:array1, :arrayN, :dict)
            return (_qprint(ctx, range) * ".keys()", :values, range)
        elseif fi !== nothing && fi.kind === :set
            return (_qprint(ctx, range), :set, range)
        end
    end
    # a local set / lowered set
    t = _infer_type(ctx, range)
    if t !== nothing && (t <: AbstractSet || t <: ObservedSet)
        return (_qprint(ctx, range), :set, nothing)
    end
    return (_qprint(ctx, range), :set, nothing)
end

# `for ((k1,k2), v) in dict`: bind k-components and the value. Returns the key
# lambda-variable name.
function _bind_pair!(ctx::_EmitCtx, var, container)
    (var isa Expr && var.head === :tuple && length(var.args) == 2) ||
        _refuse!(ctx, :unsupported_node, "dict iteration pattern `$(_src(var))`", _src(var),
            "dict iteration binds ((keys...), value)")
    kpat = var.args[1]; vvar = var.args[2]
    kvname = "_k"
    kt = _key_type(ctx, container)
    if kpat isa Expr && kpat.head === :tuple
        for (i, comp) in enumerate(kpat.args)
            comp isa Symbol || continue
            ctx.subst[comp] = kvname * "._" * string(i)
            ctx.types[comp] = (kt !== nothing && kt <: Tuple && i <= length(kt.parameters)) ?
                kt.parameters[i] : nothing
        end
    elseif kpat isa Symbol
        ctx.subst[kpat] = kvname
        ctx.types[kpat] = kt
    end
    if vvar isa Symbol
        ctx.subst[vvar] = _qprint(ctx, container) * ".get(" * kvname * ")"
        ctx.types[vvar] = _element_type(ctx, container)
    end
    return kvname
end

########################### Local binding (prelude / let) ###########################

# Bind `x = rhs` as either a state alias or a value local; append a `val` line for
# value locals when `lets` is provided (nothing => inline via subst).
function _bind_local!(ctx::_EmitCtx, x::Symbol, rhs, lets)
    resolved = _resolve(rhs, ctx.aliases)
    if _access_root(resolved) === ctx.statesym
        ctx.aliases[x] = resolved
        ctx.types[x] = _infer_type(ctx, resolved)
    else
        expr = _qprint(ctx, _resolve(rhs, ctx.aliases))
        ctx.types[x] = _infer_type(ctx, rhs)
        if lets === nothing
            ctx.subst[x] = expr
        else
            ssaname = _ssa(ctx, x)
            push!(lets, "val " * string(ssaname) * " = " * expr)
            ctx.subst[x] = string(ssaname)
        end
    end
    return nothing
end

function _ssa(ctx::_EmitCtx, x::Symbol)
    n = get(ctx.ssa, x, 0) + 1
    ctx.ssa[x] = n
    base = _sanitize(x)
    return n == 1 ? base : Symbol(string(base), "_", n)
end

########################### Prelude helper defs ###########################

function _prelude_defs(used::Set{Symbol})
    out = String[]
    :_jabs in used && push!(out, "  pure def _jabs(x: int): int = if (x < 0) -x else x")
    :_jmin in used && push!(out, "  pure def _jmin(a: int, b: int): int = if (a < b) a else b")
    :_jmax in used && push!(out, "  pure def _jmax(a: int, b: int): int = if (a > b) a else b")
    :_jmod in used && push!(out,
        "  pure def _jmod(a: int, b: int): int = val r = a % b  if (r != 0 and (r < 0) != (b < 0)) r + b else r")
    :_jsymdiff in used && push!(out,
        "  pure def _jsymdiff(a: Set[int], b: Set[int]): Set[int] = a.union(b).exclude(a.intersect(b))")
    return out
end

########################### Body splitting ###########################

# Split a function body into (prelude statements, returned expression).
function _split_body(body)
    stmts = body isa Expr && body.head === :block ? body.args : Any[body]
    prelude = Any[]
    real = Any[s for s in stmts if !(s isa LineNumberNode)]
    for (i, s) in enumerate(real)
        if s isa Expr && s.head === :return
            return (prelude, s.args[1])
        end
        i == length(real) ? (return (prelude, s)) : push!(prelude, s)
    end
    return (prelude, true)
end

# && is right-associative; flatten top-level conjuncts.
_split_conj(ex) = (ex isa Expr && ex.head === :&&) ?
    vcat(_split_conj(ex.args[1]), _split_conj(ex.args[2])) : Any[ex]

########################### Accumulator init detection ###########################

# Classify an accumulator initializer; returns a kind or nothing.
function _acc_kind(e)
    e === false && return :flag_false
    e === true && return :flag_true
    e === 0 && return :count
    if e isa Expr && e.head === :call
        nm = _callee_name(e.args[1])
        nm === :Set && return :set
    end
    (e isa Expr && e.head === :ref && length(e.args) == 1) && return :list    # T[]
    (e isa Expr && e.head === :vect && isempty(e.args)) && return :list        # []
    return nothing
end

########################### Prelude processing ###########################

# Process guard/invariant prelude statements, mutating ctx. Loop accumulators are
# classified and their result inlined via `subst`. Returns nothing (all inlined).
function _process_prelude!(ctx::_EmitCtx, prelude, acckind::Dict{Symbol,Symbol})
    for st in prelude
        _process_stmt!(ctx, st, acckind)
    end
    return nothing
end

function _process_stmt!(ctx::_EmitCtx, st, acckind::Dict{Symbol,Symbol})
    if st isa LineNumberNode
        return
    elseif st isa Expr && st.head === :(=) && st.args[1] isa Symbol
        x = st.args[1]; e = st.args[2]
        k = _acc_kind(e)
        if k !== nothing
            acckind[x] = k
            # provisional value for the (rare) case the loop never fires
            ctx.subst[x] = k === :flag_false ? "false" : k === :flag_true ? "true" :
                k === :count ? "0" : "Set()"
            ctx.types[x] = nothing
        else
            _bind_local!(ctx, x, e, nothing)
        end
    elseif st isa Expr && st.head === :for
        acc, expr = _lower_loop_acc!(ctx, st, acckind)
        acc === nothing || (ctx.subst[acc] = expr)
    elseif st isa Expr && st.head === :while
        _refuse!(ctx, :while_loop, "while loop `$(_src(st))`", _src(st),
            "unbounded loops are outside the compilable fragment")
    elseif st isa Expr && (st.head === :macrocall)
        return   # @assert / @debug etc: dropped
    else
        _refuse!(ctx, :unsupported_node, "prelude statement `$(_src(st))`", _src(st),
            "only local bindings and accumulate loops may precede the returned expression")
    end
    return nothing
end

########################### Loop classifier (five idioms) ###########################

# Lower an accumulate `for` loop to a Quint expression for its accumulator.
# Returns (accname_or_nothing, quint_expr). Handles idioms 1-4 and nested loops.
function _lower_loop_acc!(ctx::_EmitCtx, forexpr::Expr, acckind::Dict{Symbol,Symbol})
    header = forexpr.args[1]
    (header isa Expr && header.head === :(=)) || _refuse!(ctx, :unclassified_loop,
        "loop header `$(_src(header))`", _src(forexpr), "only `for v in range` loops are supported")
    var = header.args[1]
    dom, lam, saved = _enter_domain!(ctx, var, header.args[2])
    try
        body = Any[s for s in forexpr.args[2].args if !(s isa LineNumberNode)]
        hits = Tuple{Vector{Any},Symbol,Any}[]   # (pathconds, mode, payload)
        accname = Ref{Union{Nothing,Symbol}}(nothing)
        _collect_hits!(ctx, body, Any[], acckind, hits, accname)
        acc = accname[]
        acc === nothing && _refuse!(ctx, :unclassified_loop, "loop with no recognized accumulator",
            _src(forexpr), "match one of the five idioms (filter/exists/forall/count/min-by)")
        kind = acckind[acc]
        expr = _assemble_idiom(ctx, kind, dom, lam, hits, var, forexpr)
        return (acc, expr)
    finally
        _exit_domain!(ctx, saved)
    end
end

# Walk a loop body collecting (pathcond, mode, payload) accumulator hits.
function _collect_hits!(ctx::_EmitCtx, stmts, pathconds::Vector{Any},
                        acckind::Dict{Symbol,Symbol}, hits, accname::Ref)
    pc = copy(pathconds)
    for st in stmts
        st isa LineNumberNode && continue
        if st isa Expr && st.head === :|| && _is_continue(st.args[2])
            push!(pc, st.args[1])                        # rest runs only when cond true
        elseif st isa Expr && st.head === :&& && _is_continue(st.args[2])
            push!(pc, Expr(:call, :!, st.args[1]))       # rest runs only when cond false
        elseif st isa Expr && st.head === :if
            cond = st.args[1]
            _collect_hits!(ctx, _blockstmts(st.args[2]), vcat(pc, Any[cond]), acckind, hits, accname)
            if length(st.args) >= 3
                _collect_hits!(ctx, _blockstmts(st.args[3]), vcat(pc, Any[Expr(:call, :!, cond)]),
                    acckind, hits, accname)
            end
        elseif st isa Expr && st.head === :for
            inacc, inexpr = _lower_loop_acc!(ctx, st, acckind)
            inacc === nothing || (ctx.subst[inacc] = inexpr)
        elseif _is_acc_mutation(st, acckind)
            _record_hit!(st, pc, acckind, hits, accname)
        elseif st isa Expr && st.head === :(=) && st.args[1] isa Symbol
            # a per-iteration local binding; an accumulator-init shape registers a
            # (possibly nested-loop-filled) accumulator.
            k = _acc_kind(st.args[2])
            if k !== nothing
                acckind[st.args[1]] = k
                ctx.subst[st.args[1]] = k === :flag_false ? "false" : k === :flag_true ? "true" :
                    k === :count ? "0" : "Set()"
                ctx.types[st.args[1]] = nothing
            else
                _bind_local!(ctx, st.args[1], st.args[2], nothing)
            end
        elseif st isa Expr && st.head === :macrocall
            continue
        elseif _is_continue(st) || (st isa Expr && st.head === :break)
            continue
        else
            _refuse!(ctx, :unclassified_loop, "loop statement `$(_src(st))`", _src(st),
                "not a recognized accumulate idiom")
        end
    end
    return nothing
end

_is_continue(e) = e isa Expr && e.head === :continue
_blockstmts(e) = e isa Expr && e.head === :block ? Any[s for s in e.args if !(s isa LineNumberNode)] : Any[e]

# Is `st` a mutation of a known accumulator?
function _is_acc_mutation(st, acckind)
    if st isa Expr
        if st.head === :(=) && st.args[1] isa Symbol
            return haskey(acckind, st.args[1])
        elseif st.head in (:|=, :&=, :+=) && st.args[1] isa Symbol
            return haskey(acckind, st.args[1])
        elseif st.head === :call && _callee_name(st.args[1]) === :push! &&
               length(st.args) == 3 && st.args[2] isa Symbol
            return haskey(acckind, st.args[2])
        end
    end
    return false
end

function _record_hit!(st, pc, acckind, hits, accname::Ref)
    if st.head === :call   # push!(acc, v)
        acc = st.args[2]
        accname[] = acc
        push!(hits, (copy(pc), :push, st.args[3]))
    elseif st.head === :|=
        accname[] = st.args[1]
        push!(hits, (copy(pc), :or, st.args[2]))
    elseif st.head === :&=
        accname[] = st.args[1]
        push!(hits, (copy(pc), :and, st.args[2]))
    elseif st.head === :+=
        accname[] = st.args[1]
        push!(hits, (copy(pc), :inc, st.args[2]))
    elseif st.head === :(=)
        acc = st.args[1]; rhs = st.args[2]
        accname[] = acc
        if rhs === true
            push!(hits, (copy(pc), :settrue, nothing))
        elseif rhs === false
            push!(hits, (copy(pc), :setfalse, nothing))
        elseif rhs isa Expr && rhs.head === :&& && rhs.args[1] === acc
            push!(hits, (copy(pc), :and, rhs.args[2]))
        elseif rhs isa Expr && rhs.head === :|| && rhs.args[1] === acc
            push!(hits, (copy(pc), :or, rhs.args[2]))
        else
            push!(hits, (copy(pc), :set, rhs))
        end
    end
    return nothing
end

# Combine pathconds into one Quint bool.
_pathcond(ctx::_EmitCtx, pc) = isempty(pc) ? "true" :
    (length(pc) == 1 ? _qprint(ctx, pc[1]) :
     "(" * join((_qprint(ctx, c) for c in pc), " and ") * ")")

function _assemble_idiom(ctx::_EmitCtx, kind::Symbol, dom, lam, hits, var, forexpr)
    if kind === :flag_false
        # existential: any element reaching a settrue/or hit
        disj = String[]
        for (pc, mode, payload) in hits
            base = _pathcond(ctx, pc)
            if mode === :settrue
                push!(disj, base)
            elseif mode === :or
                push!(disj, base == "true" ? _qprint(ctx, payload) :
                    "(" * base * " and " * _qprint(ctx, payload) * ")")
            end
        end
        isempty(disj) && _refuse!(ctx, :unclassified_loop, "existential loop with no hit",
            _src(forexpr), "flag never set true")
        pred = length(disj) == 1 ? disj[1] : "(" * join(disj, " or ") * ")"
        return dom * ".exists(" * lam * " => " * pred * ")"
    elseif kind === :flag_true
        conj = String[]
        for (pc, mode, payload) in hits
            base = _pathcond(ctx, pc)
            if mode === :setfalse
                push!(conj, "not(" * base * ")")
            elseif mode === :and
                push!(conj, base == "true" ? _qprint(ctx, payload) :
                    "(not(" * base * ") or " * _qprint(ctx, payload) * ")")
            end
        end
        isempty(conj) && _refuse!(ctx, :unclassified_loop, "universal loop with no hit",
            _src(forexpr), "flag never cleared")
        pred = length(conj) == 1 ? conj[1] : "(" * join(conj, " and ") * ")"
        return dom * ".forall(" * lam * " => " * pred * ")"
    elseif kind === :count
        length(hits) == 1 || _refuse!(ctx, :unclassified_loop, "count loop with multiple hits",
            _src(forexpr), "a count loop has one increment site")
        (pc, mode, payload) = hits[1]
        base = _pathcond(ctx, pc)
        return dom * ".filter(" * lam * " => " * base * ").size()"
    elseif kind === :list
        length(hits) == 1 || _refuse!(ctx, :unclassified_loop, "filter loop with multiple pushes",
            _src(forexpr), "a filter loop has one push site")
        (pc, mode, payload) = hits[1]
        base = _pathcond(ctx, pc)
        if payload === var
            return dom * ".filter(" * lam * " => " * base * ")"
        else
            return dom * ".filter(" * lam * " => " * base * ").map(" * lam * " => " *
                _qprint(ctx, payload) * ")"
        end
    else
        _refuse!(ctx, :unclassified_loop, "unsupported accumulator kind $kind", _src(forexpr),
            "match one of the five idioms")
    end
end

########################### Body drivers ###########################

# A guard/fragment/invariant body -> one Quint boolean expression.
function _qbody_expr(ctx::_EmitCtx, body)
    prelude, ret = _split_body(body)
    _process_prelude!(ctx, prelude, Dict{Symbol,Symbol}())
    return _qprint(ctx, ret)
end

# A guard body -> (prelude value lines [empty; all inlined], conjunct strings).
function _qguard_conjuncts(ctx::_EmitCtx, body)
    prelude, ret = _split_body(body)
    _process_prelude!(ctx, prelude, Dict{Symbol,Symbol}())
    conjuncts = String[_qprint(ctx, c) for c in _split_conj(ret)]
    return conjuncts
end
