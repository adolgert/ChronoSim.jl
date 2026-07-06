# The Quint compiler — module assembly (`compile_quint`).
#
# Ties schema reflection, the pure printer, and effect lowering into one emitted
# Quint module: enum/record type decls, consts, vars, prelude helpers, `@fragment`
# defs, precondition-recursion defs (D12), `init` (from the snapshot), per-event
# two-layer actions (D5), `step`, and the `@invariant` defs — plus the
# `QuintCompilationReport`. Gathers all refusals and throws one `QuintCompileError`.

########################### Global-name set ###########################

function _global_names(schema::_QuintSchema, events, model::Module)
    g = Set{Symbol}()
    for f in schema.fields
        f.kind === :erased || push!(g, f.emit)
    end
    for (nm, _) in schema.enums
        push!(g, nm)
    end
    for (nm, _) in schema.records
        push!(g, nm)
    end
    return g
end

########################### compile_quint ###########################

"""
    compile_quint(model::Module, events::AbstractVector, physical;
                  name::String=lowercase(String(nameof(model))),
                  skip_events::Vector{Symbol}=Symbol[],
                  assume_true_guards::Vector{Symbol}=Symbol[],
                  invariants::Module=model,
                  mutate_for_test=nothing) -> QuintModel

Compile a ChronoSim model to a Quint module. Inputs are the model module (source
of enum/const/type bindings and, by default, of `@invariant`s), the event-type
vector (the same list passed to `SimulationFSM`), and a live physical state (the
`init` snapshot, array extents, and `Param` constants). `invariants` names the
module whose [`@invariant`](@ref)s are compiled when they live apart from the
events (e.g. a hand-written twin module).

Every event must carry `@precondition` (guard AST via `precondition_ast`) and
`@fire` (effect AST via `fire_ast`), except: an event named in
`assume_true_guards` compiles with guard `true` (for hand-written-generator
events whose `precondition` literally returns `true`); an event named in
`skip_events` is omitted and the module is marked `// PARTIAL`. Any other gap,
any out-of-fragment construct, and any float read in a lowered expression is a
[`QuintCompileError`](@ref) — all problems are gathered and reported in one
throw, each naming the event (or invariant/helper), the construct, and its
source. Where the design allowed widening (dict-key argmin tie-breaks,
non-uniform draw supports), v1 refuses instead — never a silent
over-approximation.

The result carries the module text, the [`QuintCompilationReport`](@ref)
(clean/assumed/skipped per event; erased fields; promoted constants; collapsed
records), and the metadata [`validate_trace`](@ref) needs. Compilation is pure
(no `eval`, no I/O, no toolchain requirement).

`mutate_for_test = (event=:MoveElevator, from=:<, to=:<=, occurrence=1)` mis-emits
one guard comparison operator — test-only, proves trace validation can fail. The
mutation applies to the named event's GUARD only and is recorded in
`report.mutated` only when the occurrence was actually reached.
"""
function compile_quint(model::Module, events::AbstractVector, physical;
                       name::String=lowercase(String(nameof(model))),
                       skip_events::Vector{Symbol}=Symbol[],
                       assume_true_guards::Vector{Symbol}=Symbol[],
                       invariants::Module=model,
                       mutate_for_test=nothing)
    schema = try
        _build_schema(model, physical, events)
    catch e
        if e isa _EnumCollision
            throw(QuintCompileError(nameof(model), [(subject=:schema,
                category=:enum_collision,
                construct="enum value `$(e.value)` belongs to both `$(e.a)` and `$(e.b)`",
                source="",
                hint="Quint sum-type constructors are bare names; rename one enum value")]))
        elseif e isa _FloatTypeError
            throw(QuintCompileError(nameof(model), [(subject=:schema,
                category=:float_read,
                construct="state schema contains an unerased $(e.T)", source="",
                hint="floats are erased from the compiled state; report this as a compiler bug")]))
        end
        rethrow()
    end
    globals = _global_names(schema, events, model)
    refusals = NamedTuple{(:subject, :category, :construct, :source, :hint),
                          Tuple{Symbol,Symbol,String,String,String}}[]
    widenings = NamedTuple{(:event, :reason, :source),Tuple{Symbol,String,String}}[]
    fragsigs = Dict{Symbol,Vector{String}}()
    allfrags = Set{Symbol}()
    allpreconds = Set{Symbol}()
    allpreludes = Set{Symbol}()

    report_events = NamedTuple{(:name, :status, :widenings, :reason),
                               Tuple{Symbol,Symbol,Int,String}}[]
    actions = Dict{Symbol,Symbol}()
    action_texts = String[]
    wrapper_names = String[]
    partial = false
    mut_desc = ""

    for T in events
        nm = nameof(T)
        if nm in skip_events
            partial = true
            push!(report_events, (name=nm, status=:skipped, widenings=0,
                reason="skip_events"))
            continue
        end
        assume = nm in assume_true_guards
        wbefore = length(widenings)
        res = _lower_event(schema, model, T, globals, fragsigs, refusals, widenings,
            mutate_for_test, assume)
        union!(allfrags, res.frags); union!(allpreconds, res.preconds); union!(allpreludes, res.preludes)
        if res.status === :refused
            push!(report_events, (name=nm, status=:refused, widenings=0, reason=res.reason))
            continue
        end
        push!(action_texts, res.par_text)
        push!(action_texts, res.wrapper_text)
        push!(wrapper_names, res.wrapper_name)
        actions[nm] = Symbol(res.par_name)
        nw = length(widenings) - wbefore
        status = assume ? :assumed_true_guard : (nw > 0 ? :widened : :clean)
        reason = nw > 0 ? widenings[wbefore+1].reason : ""
        push!(report_events, (name=nm, status=status, widenings=nw, reason=reason))
        res.mutated == "" || (mut_desc = res.mutated)
    end

    # invariants (may live in a different module than the events)
    inv_defs, inv_report = _lower_invariants(schema, invariants, globals, fragsigs, allfrags,
        allpreludes, widenings)

    # precondition-recursion and @fragment defs are lowered BEFORE the refusal
    # gate so their refusals gather like every other subject (a while-loop helper
    # must throw a QuintCompileError naming the helper, not escape raw).
    precond_defs = _emit_precond_defs(schema, model, allpreconds, globals, fragsigs,
        allfrags, allpreludes, widenings, refusals)
    frag_defs = _emit_fragment_defs_fixpoint(schema, model, allfrags, fragsigs, globals,
        allpreludes, widenings, refusals)

    if !isempty(refusals)
        throw(QuintCompileError(nameof(model), refusals))
    end

    # assemble the module text
    skipped_names = Symbol[e.name for e in report_events if e.status === :skipped]
    text = _assemble_text(name, schema, allpreludes, frag_defs, precond_defs,
        physical, action_texts, wrapper_names, inv_defs, skipped_names)

    erased = String[f.note for f in schema.fields if f.kind === :erased]
    for (nm, ri) in sort(collect(schema.records); by=first), df in ri.dropped
        ft = try string(fieldtype(getfield(model, nm), df)) catch; "?" end
        push!(erased, "$(nm).$(df)::$(ft)")
    end
    report = QuintCompilationReport(nameof(model), report_events, widenings,
        Symbol[f.emit for f in schema.fields if f.promoted],
        Pair{Symbol,Symbol}[ri.name => ri.collapsed_field for ri in values(schema.records) if ri.collapsed],
        erased, inv_report, copy(schema.renames), mut_desc)

    return QuintModel(name, text, report, _var_fields(schema), actions, schema, partial)
end

########################### Event lowering ###########################

function _lower_event(schema, model, T, globals, fragsigs, refusals, widenings, mutation, assume)
    nm = nameof(T)
    fields = fieldnames(T)
    evtfieldtypes = Dict{Symbol,Any}(f => fieldtype(T, f) for f in fields)
    parname = "ev_" * string(nm) * "_par"
    frags = Set{Symbol}(); preconds = Set{Symbol}(); preludes = Set{Symbol}()
    mutated = ""
    try
        # guard
        if assume
            conjuncts = String["true"]
        else
            hasmethod(precondition_ast, Tuple{Type{T}}) || _push_refuse!(refusals, nm,
                :no_precondition, "no @precondition for $nm", "",
                "annotate `@precondition function precondition(evt::$nm, state) ... end`, " *
                "or pass assume_true_guards=[:$nm] / skip_events=[:$nm]")
            (esym, ssym, gbody) = precondition_ast(T)
            gctx = _EmitCtx(schema, model, ssym, esym; subject=nm, globals=globals,
                evtfieldtypes=evtfieldtypes, fragsigs=fragsigs, refusals=refusals,
                widenings=widenings, mutation=mutation)
            conjuncts = _qguard_conjuncts(gctx, gbody)
            union!(frags, gctx.fragments); union!(preconds, gctx.preconds); union!(preludes, gctx.preludes)
            # record the mutation only when the k-th occurrence was actually
            # consumed (the swap happened), never merely because `from` appeared
            if mutation !== nothing && mutation.event === nm &&
               gctx.mut_count >= mutation.occurrence
                mutated = "$(nm) guard occurrence $(mutation.occurrence) " *
                    "($(mutation.from) -> $(mutation.to))"
            end
        end
        # effect (D16: the mutation hook applies to the GUARD only)
        hasmethod(fire_ast, Tuple{Type{T}}) || _push_refuse!(refusals, nm, :no_fire,
            "no @fire for $nm", "", "annotate `@fire function fire!(evt::$nm, state, when, rng) ... end`")
        (efsym, fssym, wsym, rsym, fbody) = fire_ast(T)
        ectx = _EmitCtx(schema, model, fssym, efsym; subject=nm, globals=globals,
            evtfieldtypes=evtfieldtypes, fragsigs=fragsigs, refusals=refusals,
            widenings=widenings, mutation=nothing)
        (nondets, assigns) = _qeffect!(ectx, fbody)
        union!(frags, ectx.fragments); union!(preconds, ectx.preconds); union!(preludes, ectx.preludes)

        par_text = _emit_par(schema, nm, parname, fields, evtfieldtypes, globals, nondets, conjuncts, assigns)
        wrap_text, wrap_name = _emit_wrapper(schema, model, T, nm, parname, fields, globals, refusals)
        return (status=:ok, par_text=par_text, wrapper_text=wrap_text, wrapper_name=wrap_name,
            par_name=parname, frags=frags, preconds=preconds, preludes=preludes,
            reason="", mutated=mutated)
    catch e
        if e isa _FloatTypeError
            push!(refusals, (subject=nm, category=:float_read,
                construct="event `$nm` carries a field of type $(e.T)", source="",
                hint="event fields must be Int/Bool/enum/tuple-of-those; floats have " *
                     "no Quint representation — pass skip_events=[:$nm]"))
        elseif !(e isa _BodyAbort)
            rethrow()
        end
        return (status=:refused, par_text="", wrapper_text="", wrapper_name="",
            par_name=parname, frags=frags, preconds=preconds, preludes=preludes,
            reason=isempty(refusals) ? "refused" : refusals[end].category |> string, mutated=mutated)
    end
end

function _push_refuse!(refusals, subject, category, construct, source, hint)
    push!(refusals, (subject=subject, category=category, construct=String(construct),
        source=String(source), hint=String(hint)))
    throw(_BodyAbort())
end

# `action ev_T_par(p: t, ...) = <nondets> all { guards..., assigns... }`
function _emit_par(schema, nm, parname, fields, evtfieldtypes, globals, nondets, conjuncts, assigns)
    io = IOBuffer()
    if isempty(fields)
        println(io, "  action ", parname, " =")
    else
        params = join(("$(_evtparam(globals, f)): $(_lower_value_type(schema, evtfieldtypes[f]))"
            for f in fields), ", ")
        println(io, "  action ", parname, "(", params, "): bool =")
    end
    for nd in nondets
        println(io, nd)
    end
    println(io, "    all {")
    members = String[]
    append!(members, conjuncts)
    for f in schema.fields
        f.kind in (:scalar, :array1, :arrayN, :dict, :set) || continue
        push!(members, string(f.emit) * "' = " * get(assigns, f.emit, string(f.emit)))
    end
    for (i, m) in enumerate(members)
        println(io, "      ", m, i < length(members) ? "," : ",")
    end
    print(io, "    }")
    return String(take!(io))
end

########################### Wrapper + domains ###########################

function _emit_wrapper(schema, model, T, nm, parname, fields, globals, refusals)
    wrapname = "ev_" * string(nm)
    if isempty(fields)
        return ("  action " * wrapname * " = " * parname, wrapname)
    end
    specs = hasmethod(derivation_spec, Tuple{Type{T}}) ? derivation_spec(T) : ReadSpec[]
    draws, args = _field_draws(schema, T, fields, specs, globals, refusals, nm)
    io = IOBuffer()
    println(io, "  action ", wrapname, " =")
    for d in draws
        println(io, "    ", d)
    end
    print(io, "    ", parname, "(", join(args, ", "), ")")
    return (String(take!(io)), wrapname)
end

# Nondet draws + call args for an event's fields, from container-key / finite-type.
function _field_draws(schema, T, fields, specs, globals, refusals, nm)
    draws = String[]
    args = String[]
    # group container-key fields sharing a path with tuple components
    grouped = Dict{Vector{Symbol},Vector{Tuple{Symbol,Int}}}()
    order = Vector{Symbol}[]
    info = Dict{Symbol,Any}()
    for f in fields
        src = _safe_key_source(specs, f)
        if src !== nothing
            path, comp = src
            info[f] = (:key, path, comp)
            if comp > 0
                haskey(grouped, path) || (grouped[path] = Tuple{Symbol,Int}[]; push!(order, path))
                push!(grouped[path], (f, comp))
            end
        else
            FT = fieldtype(T, f)
            if _is_enum_type(FT)
                info[f] = (:enum, FT)
            elseif FT === Bool
                info[f] = (:bool,)
            else
                info[f] = (:missing,)
            end
        end
    end
    counter = Ref(0)
    tuplevar = Dict{Vector{Symbol},String}()
    for path in order
        counter[] += 1
        kv = "_k" * string(counter[])
        tuplevar[path] = kv
        push!(draws, "nondet " * kv * " = " * _container_domain(schema, path) * ".oneOf()")
    end
    for f in fields
        d = info[f]
        pn = string(_evtparam(globals, f))
        if d[1] === :key && d[3] == 0
            push!(draws, "nondet " * pn * " = " * _container_domain(schema, d[2]) * ".oneOf()")
            push!(args, pn)
        elseif d[1] === :key
            push!(args, tuplevar[d[2]] * "._" * string(d[3]))
        elseif d[1] === :enum
            push!(draws, "nondet " * pn * " = " * _enum_set(schema, d[2]) * ".oneOf()")
            push!(args, pn)
        elseif d[1] === :bool
            push!(draws, "nondet " * pn * " = Set(false, true).oneOf()")
            push!(args, pn)
        else
            _push_refuse!(refusals, nm, :unsupported_call,
                "cannot resolve a domain for field `$f`", "",
                "add `@domain $(nm).$f = <expr over physical>` or pass skip_events=[:$nm]")
        end
    end
    return (draws, args)
end

_safe_key_source(specs, f) = isempty(specs) ? nothing : _container_key_source(specs, f)

function _container_domain(schema, path)
    fi = _field_by_name(schema, path[end])
    return string(fi === nothing ? path[end] : fi.emit) * ".keys()"
end

_enum_set(schema, FT) = "Set(" * join(String.(Symbol.(instances(FT))), ", ") * ")"

########################### Precondition-recursion defs (D12) ###########################

function _emit_precond_defs(schema, model, preconds, globals, fragsigs, frags, preludes, widenings, refusals)
    out = String[]
    for evtname in sort(collect(preconds))
        T = getfield(model, evtname)
        readvars = _precond_read_vars(schema, model, evtname)
        fields = fieldnames(T)
        evtfieldtypes = Dict{Symbol,Any}(f => fieldtype(T, f) for f in fields)
        params = String[]
        for v in readvars
            fi = _field_by_name(schema, v)
            push!(params, string(fi.emit) * ": " * fi.quinttype)
        end
        for f in fields
            push!(params, string(_evtparam(globals, f)) * ": " * _field_quinttype2(schema, T, f))
        end
        if hasmethod(precondition_ast, Tuple{Type{T}})
            (esym, ssym, body) = precondition_ast(T)
            ctx = _EmitCtx(schema, model, ssym, esym; subject=evtname, globals=globals,
                evtfieldtypes=evtfieldtypes, fragsigs=fragsigs, refusals=refusals, widenings=widenings)
            expr = try
                _qbody_expr(ctx, body)
            catch e
                e isa _BodyAbort || rethrow()
                continue          # refusal recorded under this event's name
            end
            union!(frags, ctx.fragments); union!(preludes, ctx.preludes)
            # (transitively-needed preconds already included by the caller's scan)
        else
            expr = "true"
        end
        push!(out, "  pure def precond_" * string(evtname) * "(" * join(params, ", ") * "): bool =\n    " * expr)
    end
    return out
end

_field_quinttype2(schema, T, f) = _lower_value_type(schema, fieldtype(T, f))

########################### Fragment defs ###########################

function _emit_fragment_defs(schema, model, frags, fragsigs, globals, morefrags, preludes, widenings, refusals)
    out = String[]
    for fname in sort(collect(frags))
        f = getfield(model, fname)
        hasmethod(fragment_ast, Tuple{typeof(f)}) || continue
        (params, body) = fragment_ast(f)
        sig = get(fragsigs, fname, String[])
        # if no recorded signature, default to int (best-effort)
        ptypes = length(sig) == length(params) ? sig : String[isempty(sig) ? "int" : sig[min(i, length(sig))] for i in eachindex(params)]
        ctx = _EmitCtx(schema, model, :__none__, :__none__; subject=fname, globals=globals,
            fragsigs=fragsigs, refusals=refusals, widenings=widenings)
        for (p, t) in zip(params, ptypes)
            ctx.subst[p] = string(_sanitize(p))
            ctx.types[p] = _julia_from_quint(schema, t)
        end
        expr = try
            _qbody_expr(ctx, body)
        catch e
            e isa _BodyAbort || rethrow()
            continue              # refusal recorded under the helper's name
        end
        union!(morefrags, ctx.fragments); union!(preludes, ctx.preludes)
        paramstr = join(("$(_sanitize(p)): $t" for (p, t) in zip(params, ptypes)), ", ")
        rett = _frag_ret_type(model, schema, body, Dict(zip(params, ptypes)))
        push!(out, "  pure def " * string(_sanitize(fname)) * "(" * paramstr * "): " * rett *
            " =\n    " * expr)
    end
    return out
end

# Emit fragment defs to a fixpoint (a helper may call further helpers); the final
# list is sorted for deterministic emission.
function _emit_fragment_defs_fixpoint(schema, model, frags, fragsigs, globals, preludes,
                                      widenings, refusals)
    defs = String[]
    done = Set{Symbol}()
    while true
        pending = setdiff(frags, done)
        isempty(pending) && break
        more = Set{Symbol}()
        append!(defs, _emit_fragment_defs(schema, model, pending, fragsigs, globals,
            more, preludes, widenings, refusals))
        union!(done, pending)
        union!(frags, more)
    end
    return sort!(defs)
end

# Infer a @fragment's Quint return type from its body.
function _frag_ret_type(model, schema, body, paramtypes)
    prelude, ret = _split_body(body)
    accset = Dict{Symbol,String}()
    for st in prelude
        if st isa Expr && st.head === :(=) && st.args[1] isa Symbol
            k = _acc_kind(st.args[2])
            if k === :list
                et = _list_elemtype(st.args[2])
                accset[st.args[1]] = "Set[" * et * "]"
            elseif k === :set
                accset[st.args[1]] = "Set[int]"
            end
        end
    end
    ret isa Symbol && haskey(accset, ret) && return accset[ret]
    return _guess_quint_type(model, schema, ret, paramtypes)
end

_list_elemtype(e) = (e isa Expr && e.head === :ref && length(e.args) == 1 &&
    e.args[1] === :Int) ? "int" : "int"

function _guess_quint_type(model, schema, ex, paramtypes)
    if ex isa Symbol
        if isdefined(model, ex) && isconst(model, ex)
            v = getfield(model, ex)
            v isa Base.Enum && return String(nameof(typeof(v)))
        end
    elseif ex isa Bool
        return "bool"
    elseif ex isa Integer
        return "int"
    elseif ex isa Expr
        if ex.head === :if || ex.head === :elseif
            t = _guess_quint_type(model, schema, ex.args[2], paramtypes)
            return t
        elseif ex.head in (:&&, :||, :comparison)
            return "bool"
        elseif ex.head === :call
            nm = _callee_name(ex.args[1])
            nm in (:!, :(==), :(!=), :<, :(<=), :>, :(>=), :≠, :≤, :≥) && return "bool"
            nm in (:+, :-, :*, :÷, :div, :%, :^, :abs, :min, :max, :length, :count, :sum) && return "int"
            nm in (:Set, :union, :setdiff, :intersect) && return "Set[int]"
        end
    end
    return "bool"
end

# Best-effort Julia type from a Quint type string (for fragment param inference:
# records need their Julia type so `.field` / collapse resolve).
function _julia_from_quint(schema, qt::AbstractString)
    for (nm, ri) in schema.records
        string(nm) == qt && return _record_julia_type(schema, nm)
    end
    return nothing
end
function _record_julia_type(schema, nm::Symbol)
    # find a physical field whose element type is this record
    for f in schema.fields
        f.eltype isa Type && _is_record_type(f.eltype) && nameof(f.eltype) === nm && return f.eltype
    end
    return nothing
end

########################### Invariants ###########################

function _lower_invariants(schema, model, globals, fragsigs, frags, preludes, widenings)
    defs = String[]
    report = NamedTuple{(:name, :status, :reason),Tuple{String,Symbol,String}}[]
    names_ok = String[]
    for inv in module_invariants(model)
        invname = "inv_" * _sanitize_name(inv.name)
        local_ref = NamedTuple{(:subject, :category, :construct, :source, :hint),
                               Tuple{Symbol,Symbol,String,String,String}}[]
        ctx = _EmitCtx(schema, model, inv.statesym, :__none__; subject=Symbol(invname),
            globals=globals, fragsigs=fragsigs, refusals=local_ref, widenings=widenings)
        try
            expr = _qbody_expr(ctx, inv.body)
            union!(frags, ctx.fragments); union!(preludes, ctx.preludes)
            push!(defs, "  val " * invname * " = " * expr * "   // " * inv.name)
            push!(report, (name=inv.name, status=:clean, reason=""))
            push!(names_ok, invname)
        catch e
            e isa _BodyAbort || rethrow()
            reason = isempty(local_ref) ? "refused" : local_ref[end].category |> string
            hint = isempty(local_ref) ? "" : local_ref[end].hint
            push!(defs, "  // REFUSED invariant \"" * inv.name * "\": " * reason)
            push!(report, (name=inv.name, status=:refused, reason=reason))
        end
    end
    if !isempty(names_ok)
        push!(defs, "  val inv = " * join(names_ok, " and "))
    end
    return (defs, report)
end

_sanitize_name(s::AbstractString) =
    replace(lowercase(String(s)), r"[^a-z0-9]+" => "_") |> x -> strip(x, '_')

########################### Init (D15) ###########################

function _emit_init(schema, physical)
    io = IOBuffer()
    println(io, "  action init = all {")
    members = String[]
    for f in schema.fields
        f.kind in (:scalar, :array1, :arrayN, :dict, :set) || continue
        v = _emit_value(schema, fieldtype(schema.ptype, f.name), getfield(physical, f.name))
        push!(members, string(f.emit) * "' = " * v)
    end
    for (i, m) in enumerate(members)
        println(io, "    ", m, ",")
    end
    print(io, "  }")
    return String(take!(io))
end

########################### Full module text ###########################

function _assemble_text(name, schema, preludes, frag_defs, precond_defs, physical,
                        action_texts, wrapper_names, inv_defs, skipped)
    io = IOBuffer()
    println(io, "// ", name, ".qnt — generated by ChronoSim.compile_quint; do not edit.")
    if !isempty(skipped)
        # D11: a module missing actions must say so where a reader will see it.
        println(io, "// PARTIAL: skipped events (skip_events): ", join(skipped, " "))
        println(io, "// The `step` relation omits those events; verification results")
        println(io, "// cover only the compiled subset of the model's behavior.")
    end
    println(io, "module ", name, " {")
    # enum types
    for (nm, e) in sort(collect(schema.enums); by=first)
        println(io, "  type ", nm, " = ", join(String.(e.instances), " | "))
    end
    # record types
    for (nm, ri) in sort(collect(schema.records); by=first)
        ri.collapsed && continue
        fieldstr = join(("$(f): $(qt)" for (f, qt) in zip(ri.fields, ri.quintfields)), ", ")
        println(io, "  type ", nm, " = { ", fieldstr, " }")
    end
    println(io)
    # consts
    for f in schema.fields
        f.kind === :const || continue
        v = _emit_value(schema, fieldtype(schema.ptype, f.name), getfield(physical, f.name))
        println(io, "  pure val ", f.emit, " = ", v)
    end
    # vars
    for f in schema.fields
        f.kind in (:scalar, :array1, :arrayN, :dict, :set) || continue
        println(io, "  var ", f.emit, ": ", f.quinttype)
    end
    println(io)
    # prelude helpers
    for line in _prelude_defs(preludes)
        println(io, line)
    end
    # fragments then precond defs
    for d in frag_defs
        println(io, d); println(io)
    end
    for d in precond_defs
        println(io, d); println(io)
    end
    # init
    println(io, _emit_init(schema, physical))
    println(io)
    # actions
    for at in action_texts
        println(io, at); println(io)
    end
    # step
    println(io, "  action step = any {")
    for (i, w) in enumerate(wrapper_names)
        println(io, "    ", w, i < length(wrapper_names) ? "," : ",")
    end
    println(io, "  }")
    println(io)
    # invariants
    for d in inv_defs
        println(io, d)
    end
    print(io, "}")
    return String(take!(io))
end
