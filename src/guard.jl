########## Guard-clause evaluator (Phase 1c)
#
# `guard_clauses` evaluates a `@precondition` body clause by clause against
# live state, without `eval`. It is the ingredient 1e's `whynot` needs to say
# WHICH conjunct rejected a proposed event and why. The interpreter is one
# recursive function (`_geval`) plus three constant Symbol->function tables
# built once at module load. It walks the same syntactic fragment the derive.jl
# walker accepts, with two deliberate deltas: `@fragment` helpers and
# `precondition(...)` recursion are executed as real registered calls (their
# bodies never reach the interpreter), so `push!`/array-literals/accumulate
# loops are out of scope. The body comes from the baked `precondition_ast`
# method and helpers are recognized via `_is_registered_fragment` (both emitted
# at macro time; the macro-time registries are empty after precompilation).
# No `eval`; the one whitelisted mutator, `get!`, is refused — guard evaluation
# is read-only.
#
# Known, documented divergences from real-Julia evaluation, all reachable only
# for preconditions that are already broken or outside the derive corpus:
# a non-Bool condition in `if`/`&&`/generator filters is treated as false where
# Julia would throw a TypeError; multi-iterspec `for a in A, b in B` loops are
# refused :unsupported_node although the derive walker tolerates them; and a
# walker-tolerated opaque call with state-free arguments (e.g. `sqrt(2.0)`) is
# refused :unsupported_call.

export guard_clauses, GuardEvalError

"""
    GuardEvalError

Structured failure from [`guard_clauses`](@ref). `kind` is one of
`:no_precondition` (event not registered via `@precondition`),
`:unsupported_call` / `:unsupported_node` / `:early_return` /
`:mutating_call` / `:unknown_symbol` (construct outside the interpreter's
fragment — the payload names it), or `:prelude_threw` (a statement before the
precondition's returned expression raised `cause`).
"""
struct GuardEvalError <: Exception
    event_type::Type
    kind::Symbol            # :no_precondition | :unsupported_call | :unsupported_node
                            # | :early_return | :mutating_call | :unknown_symbol
                            # | :prelude_threw
    construct::String       # offending name/source fragment ("" for :no_precondition)
    message::String
    cause::Union{Nothing,Exception}   # set for :prelude_threw
end
GuardEvalError(T, kind, construct, message) = GuardEvalError(T, kind, construct, message, nothing)

function Base.showerror(io::IO, e::GuardEvalError)
    println(io, "GuardEvalError for ", nameof(e.event_type), " (", e.kind, ")")
    isempty(e.construct) || println(io, "  construct: ", e.construct)
    println(io, "  ", e.message)
    if e.cause !== nothing
        print(io, "  caused by: ")
        showerror(io, e.cause)
    end
end

# Symbol -> function tables, built once at module load. No eval anywhere:
# these are references to already-defined Base functions.
const _GC_OPS = Dict{Symbol,Function}(
    :(==) => (==), :(!=) => (!=), :≠ => (!=), :< => (<), :(<=) => (<=), :≤ => (<=),
    :> => (>), :(>=) => (>=), :≥ => (>=), :+ => (+), :- => (-), :* => (*), :/ => (/),
    :÷ => (÷), :% => (%), :^ => (^), :! => (!), :xor => xor, :⊻ => xor, :& => (&),
    :| => (|), :~ => (~), :min => min, :max => max, :abs => abs, :mod => mod, :div => div,
    # `:` (range construction) appears in `1:length(c)` loop ranges.
    :(:) => (:),
)
const _GC_WHITELIST = Dict{Symbol,Function}(
    # derive.jl's _WHITELIST minus get! (refused: it mutates)
    :length => length, :eachindex => eachindex, :isempty => isempty, :keys => keys,
    :values => values, :pairs => pairs, :haskey => haskey, :get => get,
    :in => in, :∈ => in, :lastindex => lastindex, :firstindex => firstindex, :axes => axes,
)
const _GC_REDUCERS = Dict{Symbol,Function}(
    :any => any, :all => all, :count => count, :sum => sum, :prod => prod,
    :minimum => minimum, :maximum => maximum,
)

# Update-assignment heads (`x += y`) -> the underlying binary operator.
const _GC_UPDATE_OPS = Dict{Symbol,Function}(
    :(+=) => (+), :(-=) => (-), :(*=) => (*), :(/=) => (/), :(÷=) => (÷),
    :(%=) => (%), :(^=) => (^), :(|=) => (|), :(&=) => (&), :(⊻=) => xor,
    :(<<=) => (<<), :(>>=) => (>>),
)

# Control-flow sentinels returned by _geval for break/continue; caught by the
# innermost loop (rows 22/23). A block stops and propagates a sentinel upward.
struct _GCBreak end
struct _GCContinue end
const _GC_BREAK = _GCBreak()
const _GC_CONTINUE = _GCContinue()
_is_gc_signal(v) = v === _GC_BREAK || v === _GC_CONTINUE

"""
    guard_clauses(EvtType, evt, physical; mod=parentmodule(EvtType))
        -> Vector{Tuple{String,Any}}

Evaluate the registered `@precondition` body of `EvtType` clause by clause
against live state, without calling `eval`. Returns one `(source_text, value)`
pair per top-level `&&` conjunct of the precondition's returned expression, in
source order. A top-level `||` expression is a single clause. Local
bindings and loops before the `return` are executed first; each clause is then
evaluated independently, so every clause gets a value even when an earlier one
is `false`. A clause whose evaluation throws (e.g. a key lookup that an
earlier `haskey` clause guards) reports the exception object as its value.

The real precondition's verdict is the first non-`true` value in order:
`false` means rejected there; all `true` means accepted; an exception before
any `false` means the precondition itself would throw.

Requires an `@precondition`-registered event (`mod` must be the module where
`@precondition` was expanded — by default the event type's module). Events
with hand-written `@conditionsfor` generators are not registered and raise a
[`GuardEvalError`](@ref); so does any construct outside the interpreter's
fragment (the error names the construct and its source text).
"""
function guard_clauses(::Type{T}, evt, physical; mod::Module=parentmodule(T)) where {T}
    # The body comes from the baked `precondition_ast(T)` method (emitted by
    # @precondition, survives precompilation), not from the compile-time-only
    # `_PRECOND_REGISTRY`. `mod` still resolves the interpreter's module-level
    # references (enum values, @fragment helpers, event constructors).
    hasmethod(precondition_ast, Tuple{Type{T}}) || throw(GuardEvalError(T, :no_precondition, "",
        "no @precondition is registered for $(nameof(T)). guard_clauses " *
        "requires @precondition events; hand-written @conditionsfor events are not " *
        "registered."))
    (evtsym, statesym, body) = precondition_ast(T)
    prelude, retexpr = _split_guard_body(body, T)
    env = Dict{Symbol,Any}(evtsym => evt, statesym => physical)
    for stmt in prelude
        try
            _geval(stmt, env, mod, T)
        catch e
            e isa GuardEvalError && rethrow()
            throw(GuardEvalError(T, :prelude_threw, _clause_source(stmt),
                "a statement before the precondition's returned expression threw; " *
                "the real precondition throws on this state too.", e))
        end
    end
    out = Tuple{String,Any}[]
    for clause in _split_conjuncts(retexpr)
        value = try
            _geval(clause, copy(env), mod, T)   # fresh env copy: clauses independent
        catch e
            e isa GuardEvalError && rethrow()   # interpreter gaps are never values
            e
        end
        push!(out, (_clause_source(clause), value))
    end
    return out
end
guard_clauses(evt::SimEvent, physical) = guard_clauses(typeof(evt), evt, physical)

########## Body splitting

# The registered body is the function's block. The returned expression is the
# argument of the FIRST top-level `return`; statements before it are the
# prelude. With no top-level `return`, the last non-LineNumberNode statement is
# the returned expression. A `return` nested below top level is refused
# (:early_return) via _geval — none exists in the corpus.
function _split_guard_body(body, T)
    stmts = body isa Expr && body.head === :block ? body.args : Any[body]
    prelude = Any[]
    for (i, s) in enumerate(stmts)
        s isa LineNumberNode && continue
        if s isa Expr && s.head === :return
            return (prelude, s.args[1])
        end
        rest = any(x -> !(x isa LineNumberNode), stmts[(i + 1):end])
        rest ? push!(prelude, s) : return (prelude, s)
    end
    throw(GuardEvalError(T, :unsupported_node, "",
        "the registered precondition body has no returned expression"))
end

# && is right-associative; recursion flattens either shape.
_split_conjuncts(ex) =
    (ex isa Expr && ex.head === :&&) ?
        vcat(_split_conjuncts(ex.args[1]), _split_conjuncts(ex.args[2])) : Any[ex]

_clause_source(ex) =
    replace(string(ex isa Expr ? Base.remove_linenums!(copy(ex)) : ex), r"\s+" => " ")

########## The interpreter

# _geval(expr, env, mod, T) -> value. env::Dict{Symbol,Any} holds evtsym,
# statesym, and locals. mod resolves module constants (enum values), @fragment
# helpers, and event constructors. T is only for error payloads.
function _geval(expr, env::Dict{Symbol,Any}, mod::Module, T)
    if expr isa Symbol
        haskey(env, expr) && return env[expr]
        isdefined(mod, expr) && return getfield(mod, expr)
        throw(GuardEvalError(T, :unknown_symbol, string(expr),
            "symbol `$expr` is neither a local binding nor defined in $(mod)."))
    elseif expr isa QuoteNode
        return expr.value
    elseif !(expr isa Expr)
        return expr                          # Number, Bool, String, Char, nothing, ...
    end

    h = expr.head
    if h === :.                              # field access
        obj = _geval(expr.args[1], env, mod, T)
        field = expr.args[2]
        fsym = field isa QuoteNode ? field.value : _geval(field, env, mod, T)
        return getproperty(obj, fsym)
    elseif h === :ref                        # indexing
        container = _geval(expr.args[1], env, mod, T)
        idxs = Any[_geval(a, env, mod, T) for a in expr.args[2:end]]
        return getindex(container, idxs...)
    elseif h === :tuple
        return Tuple(_geval(a, env, mod, T) for a in expr.args)
    elseif h === :call
        return _geval_call(expr, env, mod, T)
    elseif h === :&&
        lv = _geval(expr.args[1], env, mod, T)
        lv === false && return false
        return _geval(expr.args[2], env, mod, T)
    elseif h === :||
        lv = _geval(expr.args[1], env, mod, T)
        lv === true && return true
        return _geval(expr.args[2], env, mod, T)
    elseif h === :comparison
        return _geval_comparison(expr, env, mod, T)
    elseif h === :if || h === :elseif        # includes ternary
        cond = _geval(expr.args[1], env, mod, T)
        if cond === true
            return _geval(expr.args[2], env, mod, T)
        elseif length(expr.args) >= 3
            return _geval(expr.args[3], env, mod, T)
        else
            return nothing
        end
    elseif h === :block
        return _geval_block(expr.args, env, mod, T)
    elseif h === :generator || h === :comprehension
        gen = h === :comprehension ? expr.args[1] : expr
        return _gen_collect(gen, env, mod, T)
    elseif h === :(=)
        val = _geval(expr.args[2], env, mod, T)
        _bind_pattern!(env, expr.args[1], val, mod, T)
        return val
    elseif haskey(_GC_UPDATE_OPS, h)         # x += y, x |= y, ...
        lhs = expr.args[1]
        lhs isa Symbol || throw(GuardEvalError(T, :unsupported_node, _clause_source(expr),
            "update-assignment target must be a plain local name."))
        cur = _geval(lhs, env, mod, T)
        rhs = _geval(expr.args[2], env, mod, T)
        newval = _GC_UPDATE_OPS[h](cur, rhs)
        env[lhs] = newval
        return newval
    elseif h === :for
        return _geval_for(expr, env, mod, T)
    elseif h === :while
        while _geval(expr.args[1], env, mod, T) === true
            r = _geval_block(expr.args[2].args, env, mod, T)
            r === _GC_BREAK && break
        end
        return nothing
    elseif h === :break
        return _GC_BREAK
    elseif h === :continue
        return _GC_CONTINUE
    elseif h === :return
        throw(GuardEvalError(T, :early_return, _clause_source(expr),
            "a `return` inside a branch or loop is not supported; the fragment " *
            "must be a straight-line prelude followed by one returned expression."))
    else
        throw(GuardEvalError(T, :unsupported_node, _clause_source(expr),
            "unsupported syntax node `$(h)`; outside the derivable precondition fragment."))
    end
end

function _geval_block(stmts, env::Dict{Symbol,Any}, mod::Module, T)
    val = nothing
    for s in stmts
        s isa LineNumberNode && continue
        val = _geval(s, env, mod, T)
        _is_gc_signal(val) && return val
    end
    return val
end

function _geval_comparison(expr, env::Dict{Symbol,Any}, mod::Module, T)
    args = expr.args
    left = _geval(args[1], env, mod, T)
    i = 2
    while i < length(args)
        opsym = args[i]
        haskey(_GC_OPS, opsym) || throw(GuardEvalError(T, :unsupported_call, string(opsym),
            "comparison operator `$opsym` is outside the arithmetic/boolean fragment."))
        right = _geval(args[i + 1], env, mod, T)
        _GC_OPS[opsym](left, right) || return false
        left = right
        i += 2
    end
    return true
end

function _geval_call(expr, env::Dict{Symbol,Any}, mod::Module, T)
    callee = expr.args[1]
    name = _callee_name(callee)
    cargs = expr.args[2:end]

    if name !== nothing && haskey(_GC_OPS, name)
        vals = Any[_geval(a, env, mod, T) for a in cargs]
        return _GC_OPS[name](vals...)
    end
    if name === :get!
        throw(GuardEvalError(T, :mutating_call, _clause_source(expr),
            "get! inserts a default into live state; guard evaluation is read-only."))
    end
    if name !== nothing && haskey(_GC_WHITELIST, name)
        vals = Any[_geval(a, env, mod, T) for a in cargs]
        return _GC_WHITELIST[name](vals...)
    end
    if name !== nothing && haskey(_GC_REDUCERS, name) &&
        length(cargs) == 1 && _is_gen_arg(cargs[1])
        return _geval_reducer_gen(name, cargs[1], env, mod, T)
    end
    if name !== nothing && haskey(_GC_REDUCERS, name)
        vals = Any[_geval(a, env, mod, T) for a in cargs]
        return _GC_REDUCERS[name](vals...)
    end
    if name === :precondition && length(cargs) == 2 &&
        cargs[1] isa Expr && cargs[1].head === :call
        ctor = cargs[1]
        evtname = _callee_name(ctor.args[1])
        if evtname !== nothing && isdefined(mod, evtname)
            ctor_args = Any[_geval(a, env, mod, T) for a in ctor.args[2:end]]
            evt2 = getfield(mod, evtname)(ctor_args...)
            stateval = _geval(cargs[2], env, mod, T)
            return precondition(evt2, stateval)
        end
    end
    if name !== nothing && isdefined(mod, name)
        f = getfield(mod, name)
        if f isa Function && _is_registered_fragment(f)   # runtime @fragment marker
            vals = Any[_geval(a, env, mod, T) for a in cargs]
            return f(vals...)
        end
    end
    throw(GuardEvalError(T, :unsupported_call, _clause_source(expr),
        "call to `$(name === nothing ? _clause_source(callee) : name)` is outside the " *
        "interpreter fragment (not an operator, whitelisted read, reducer, " *
        "@fragment helper, or precondition-recursion)."))
end

# `_is_gen_arg` is defined in derive.jl (same module) and reused here.

########## Loops, generators, destructuring

# Symbols bound by a loop/generator pattern (Symbol or nested tuple).
function _pattern_symbols!(acc::Vector{Symbol}, var)
    if var isa Symbol
        push!(acc, var)
    elseif var isa Expr && var.head === :tuple
        for v in var.args
            _pattern_symbols!(acc, v)
        end
    end
    return acc
end

# Bind `var` (Symbol or nested tuple) to `val` in env, destructuring by iteration.
function _bind_pattern!(env::Dict{Symbol,Any}, var, val, mod::Module, T)
    if var isa Symbol
        env[var] = val
    elseif var isa Expr && var.head === :tuple
        next = iterate(val)
        for v in var.args
            next === nothing && throw(GuardEvalError(T, :unsupported_node,
                _clause_source(var), "destructuring ran out of values."))
            item, st = next
            _bind_pattern!(env, v, item, mod, T)
            next = iterate(val, st)
        end
    else
        throw(GuardEvalError(T, :unsupported_node, _clause_source(var),
            "unsupported assignment target."))
    end
    return nothing
end

function _geval_for(expr, env::Dict{Symbol,Any}, mod::Module, T)
    header = expr.args[1]
    (header isa Expr && header.head === :(=)) || throw(GuardEvalError(T, :unsupported_node,
        _clause_source(expr), "only single-variable `for var in range` loops are supported."))
    var = header.args[1]
    range = _geval(header.args[2], env, mod, T)
    body_stmts = expr.args[2].args
    # Shadow-and-restore the pattern variables around the loop.
    syms = _pattern_symbols!(Symbol[], var)
    saved = [(s, get(env, s, nothing), haskey(env, s)) for s in syms]
    for item in range
        _bind_pattern!(env, var, item, mod, T)
        r = _geval_block(body_stmts, env, mod, T)
        r === _GC_BREAK && break
        # _GC_CONTINUE simply proceeds to the next iteration.
    end
    for (s, v, present) in saved
        present ? (env[s] = v) : delete!(env, s)
    end
    return nothing
end

# Collect all body values of a generator, honoring filters and nested iterspecs.
function _gen_collect(gen, env::Dict{Symbol,Any}, mod::Module, T)
    result = Any[]
    _gen_foreach(gen.args[1], gen.args[2:end], env, mod, T) do val
        push!(result, val)
        false
    end
    return result
end

# Apply a reducer to a generator argument, with short-circuit for any/all.
function _geval_reducer_gen(name::Symbol, genarg, env::Dict{Symbol,Any}, mod::Module, T)
    gen = genarg.head === :comprehension ? genarg.args[1] : genarg
    body = gen.args[1]
    specs = gen.args[2:end]
    if name === :any
        found = false
        _gen_foreach(body, specs, env, mod, T) do val
            val === true ? (found = true; true) : false
        end
        return found
    elseif name === :all
        ok = true
        _gen_foreach(body, specs, env, mod, T) do val
            val === false ? (ok = false; true) : false
        end
        return ok
    else
        return _GC_REDUCERS[name](_gen_collect(gen, env, mod, T))
    end
end

# Iterate a generator's element space, calling f(body_value) for each element;
# f returns true to stop early (short-circuit). Handles filters and nested
# iteration specs (`for a in A for b in B`). Iteration variables shadow-restore.
function _gen_foreach(f, body, specs, env::Dict{Symbol,Any}, mod::Module, T)
    if isempty(specs)
        return f(_geval(body, env, mod, T))
    end
    spec = specs[1]
    rest = specs[2:end]
    if spec isa Expr && spec.head === :filter
        conds = spec.args[1:(end - 1)]
        iterspec = spec.args[end]
    else
        conds = ()
        iterspec = spec
    end
    (iterspec isa Expr && iterspec.head === :(=)) || throw(GuardEvalError(T,
        :unsupported_node, _clause_source(iterspec), "unsupported generator iteration spec."))
    var = iterspec.args[1]
    range = _geval(iterspec.args[2], env, mod, T)
    syms = _pattern_symbols!(Symbol[], var)
    saved = [(s, get(env, s, nothing), haskey(env, s)) for s in syms]
    stopped = false
    for item in range
        _bind_pattern!(env, var, item, mod, T)
        ok = true
        for c in conds
            if _geval(c, env, mod, T) !== true
                ok = false
                break
            end
        end
        ok || continue
        if _gen_foreach(f, body, rest, env, mod, T)
            stopped = true
            break
        end
    end
    for (s, v, present) in saved
        present ? (env[s] = v) : delete!(env, s)
    end
    return stopped
end
