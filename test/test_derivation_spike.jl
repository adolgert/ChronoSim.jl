using ReTest

# Phase 2 falsification spike: derive event generators from precondition source
# BY HAND (plain functions over `Expr`), then prove the derived generators cover
# and behaviorally match the modeler's hand-written ones. These functions are
# deliberately kept in the test tree; they migrate to src/ in a later phase.
#
# `ElevatorExample` is defined by test_elevator.jl (which `include`s elevator.jl).
# We reference it only inside @testset bodies, which run after every test file is
# included, so include-order relative to test_elevator.jl does not matter here.

############################ Part A: derivation over Expr ############################

spike_is_literal(x) = x isa Number || x isa Bool || x isa String || x isa Char || x isa QuoteNode

# Root symbol of a pure `.field`/`[index]` access chain, else `nothing` (e.g. a call).
function spike_access_root(expr)
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

# Substitute local aliases everywhere, including inside index subexpressions, so a
# chain rooted at a local becomes a chain rooted at the state parameter. This is why
# alias resolution must recurse into `[index]` args: a tainted key like
# `(elevator.floor, elevator.direction)` only reveals its state reads once resolved.
function spike_resolve(expr, aliases)
    if expr isa Symbol
        return get(aliases, expr, expr)
    elseif expr isa Expr
        if expr.head === :.
            return Expr(:., spike_resolve(expr.args[1], aliases), expr.args[2])
        elseif expr.head === :ref
            return Expr(
                :ref,
                spike_resolve(expr.args[1], aliases),
                (spike_resolve(a, aliases) for a in expr.args[2:end])...,
            )
        else
            return Expr(expr.head, (spike_resolve(a, aliases) for a in expr.args)...)
        end
    else
        return expr
    end
end

# The `[index]` args along an access chain, outermost first, un-resolved.
function spike_index_subexprs(expr)
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

# Turn `system.elevator[i].floor` into `elevator[i].floor` by dropping the state
# head, so the reused ChronoSim.access_to_searchkey yields a matchstr with no
# spurious leading Member for the state parameter.
function spike_strip_state_head(expr, statesym)
    if expr isa Expr
        if expr.head === :.
            base = expr.args[1]
            if base === statesym
                fieldnode = expr.args[2]
                return fieldnode isa QuoteNode ? fieldnode.value : fieldnode
            else
                return Expr(:., spike_strip_state_head(base, statesym), expr.args[2])
            end
        elseif expr.head === :ref
            return Expr(:ref, spike_strip_state_head(expr.args[1], statesym), expr.args[2:end]...)
        end
    end
    return expr
end

"""
    spike_collect_reads(body, statesym, evtsym)

Walk a straight-line precondition body and return every maximal state-access chain
as `(access = <chain rooted at statesym>, index_exprs = [<each [] index>])`.
Assignments whose RHS is a bare state access bind a local alias (straight-line
propagation); their element access is not itself recorded because only the leaf
reads that are actually consumed become triggers.
"""
function spike_collect_reads(body::Expr, statesym::Symbol, evtsym::Symbol)
    aliases = Dict{Symbol,Any}()
    reads = Vector{Any}()

    record! = function (resolved_access)
        idxs = ChronoSim.access_to_argnames(resolved_access)
        push!(reads, (access=resolved_access, index_exprs=idxs))
    end

    walk = function (expr)
        if expr isa Symbol
            haskey(aliases, expr) && record!(aliases[expr])
            return nothing
        end
        expr isa Expr || return nothing
        r = spike_access_root(expr)
        if r === statesym || (r !== nothing && haskey(aliases, r))
            record!(spike_resolve(expr, aliases))
            for idx in spike_index_subexprs(expr)
                walk(idx)
            end
        else
            for a in expr.args
                walk(a)
            end
        end
    end

    for stmt in body.args
        stmt isa LineNumberNode && continue
        if stmt isa Expr && stmt.head === :(=) && stmt.args[1] isa Symbol
            rhs = stmt.args[2]
            resolved_rhs = spike_resolve(rhs, aliases)
            if spike_access_root(resolved_rhs) === statesym
                aliases[stmt.args[1]] = resolved_rhs
                for idx in spike_index_subexprs(rhs)
                    walk(idx)
                end
            else
                walk(rhs)
            end
        elseif stmt isa Expr && stmt.head === :return
            for a in stmt.args
                walk(a)
            end
        else
            walk(stmt)
        end
    end
    return reads
end

# An index is clean iff it is built only from `evt.field` accesses and literals.
# Anything else (a state access, a container index) taints it.
function spike_only_evt_and_literals(x, evtsym)
    spike_is_literal(x) && return true
    if x isa Expr
        if x.head === :. && x.args[1] === evtsym
            return true
        elseif x.head === :. || x.head === :ref
            return false
        else
            return all(a -> spike_only_evt_and_literals(a, evtsym), x.args)
        end
    end
    return false
end

function spike_classify_index(idx, evtsym)
    clean = spike_only_evt_and_literals(idx, evtsym)
    binding = if idx isa Expr && idx.head === :. && idx.args[1] === evtsym
        idx.args[2] isa QuoteNode ? idx.args[2].value : idx.args[2]
    else
        nothing
    end
    return (clean, binding)
end

"""
    spike_classify(read, evtsym)

A read is CLEAN iff every index expression uses only `evtsym` field accesses and
literals; TAINTED if any index subexpression reads state. Returns
`(clean, bindings)` where `bindings[k]` is the event field bound by index position
`k` (or `nothing` for a literal).
"""
function spike_classify(read, evtsym)
    bindings = Any[]
    clean = true
    for idx in read.index_exprs
        c, b = spike_classify_index(idx, evtsym)
        clean &= c
        push!(bindings, b)
    end
    return (clean=clean, bindings=bindings)
end

"""
    spike_derive(EventType, body, statesym, evtsym, widen_domain) -> Vector{EventGenerator}

Derive place-triggered generators from a precondition body. Reads are deduplicated
by masked matchstr (multiple reads of one field collapse to one trigger). A CLEAN
read yields a generator that fires the event at the read's index; a TAINTED read
yields a WIDENED generator that ignores the concrete index and enumerates
`widen_domain(physical)`.
"""
function spike_derive(
    EventType, body::Expr, statesym::Symbol, evtsym::Symbol, widen_domain::Function
)
    reads = spike_collect_reads(body, statesym, evtsym)
    gens = EventGenerator[]
    seen = Vector{Any}()
    for read in reads
        matchstr = ChronoSim.access_to_searchkey(spike_strip_state_head(read.access, statesym))
        any(m -> m == matchstr, seen) && continue
        push!(seen, matchstr)
        if spike_classify(read, evtsym).clean
            gen = EventGenerator(
                ToPlace, matchstr, (generate, physical, inds...) -> generate(EventType(inds...))
            )
        else
            gen = EventGenerator(
                ToPlace,
                matchstr,
                (generate, physical, inds...) -> begin
                    for j in widen_domain(physical)
                        generate(EventType(j))
                    end
                end,
            )
        end
        push!(gens, gen)
    end
    return gens
end

############################ Part B: the spike tests ############################

# Exact source of the two precondition bodies (hand-driven: quoting is in scope for
# the spike; AST-from-method extraction is a later phase). statesym=:system, evtsym=:evt.
const SPIKE_OPEN_BODY = quote
    elevator = system.elevator[evt.elevator_idx]
    call_exists =
        elevator.direction != Stationary &&
        system.calls[(elevator.floor, elevator.direction)].requested
    button_pressed = elevator.floor ∈ elevator.buttons_pressed
    return !elevator.doors_open && (call_exists || button_pressed)
end

const SPIKE_CALL_BODY = quote
    person = system.person[evt.person]
    return person.location != person.destination && !person.waiting
end

# Multiset comparison over matchstr/event vectors. `==` (not `Set` hashing) because
# Member/MEMBERINDEX compare by value via `===` but do not have a value-hash defined.
function spike_is_subset(a, b)
    remaining = collect(b)
    for x in a
        i = findfirst(y -> y == x, remaining)
        i === nothing && return false
        deleteat!(remaining, i)
    end
    return true
end
spike_multiset_equal(a, b) = length(a) == length(b) && spike_is_subset(a, b)

@testset "derivation_spike derived matchstrs cover hand-written ones" begin
    Ev = ElevatorExample
    MI = ChronoSim.MEMBERINDEX

    hw_open = [g.matchstr for g in generators(Ev.OpenElevatorDoors)]
    der_open = [
        g.matchstr for g in spike_derive(
            Ev.OpenElevatorDoors,
            SPIKE_OPEN_BODY,
            :system,
            :evt,
            physical -> eachindex(physical.elevator),
        )
    ]
    @test spike_is_subset(hw_open, der_open)
    expected_open = vcat(hw_open, Any[Any[Member(:elevator), MI, Member(:doors_open)]])
    @test spike_multiset_equal(der_open, expected_open)

    hw_call = [g.matchstr for g in generators(Ev.CallElevator)]
    der_call = [
        g.matchstr for g in spike_derive(
            Ev.CallElevator, SPIKE_CALL_BODY, :system, :evt, physical -> eachindex(physical.person)
        )
    ]
    @test spike_is_subset(hw_call, der_call)
    expected_call = Any[
        Any[Member(:person), MI, Member(:location)],
        Any[Member(:person), MI, Member(:destination)],
        Any[Member(:person), MI, Member(:waiting)],
    ]
    @test spike_multiset_equal(der_call, expected_call)
end

@testset "derivation_spike behavioral equality on shared triggers" begin
    Ev = ElevatorExample
    system = Ev.ElevatorSystem(3, 2, 5)

    indices_for = function (matchstr)
        head = matchstr[1]
        if head == Member(:elevator)
            return Any[1, 2]
        elseif head == Member(:person)
            return Any[1, 2, 3]
        elseif head == Member(:calls)
            return Any[(1, Ev.Up), (2, Ev.Down), (3, Ev.Up)]
        else
            error("unexpected matchstr head $head")
        end
    end

    cases = [
        (Ev.OpenElevatorDoors, SPIKE_OPEN_BODY, sys -> eachindex(sys.elevator)),
        (Ev.CallElevator, SPIKE_CALL_BODY, sys -> eachindex(sys.person)),
    ]
    for (EvType, body, wd) in cases
        der = spike_derive(EvType, body, :system, :evt, wd)
        for hg in generators(EvType)
            di = findfirst(g -> g.matchstr == hg.matchstr, der)
            @test di !== nothing
            di === nothing && continue
            dg = der[di]
            for idx in indices_for(hg.matchstr)
                acc_hw = Any[]
                acc_der = Any[]
                hg.generator(e -> push!(acc_hw, e), system, idx)
                dg.generator(e -> push!(acc_der, e), system, idx)
                @test spike_multiset_equal(acc_hw, acc_der)
            end
        end
    end
end

@testset "derivation_spike dedup produces no duplicate matchstrs" begin
    Ev = ElevatorExample
    der = spike_derive(
        Ev.OpenElevatorDoors,
        SPIKE_OPEN_BODY,
        :system,
        :evt,
        physical -> eachindex(physical.elevator),
    )
    ms = [g.matchstr for g in der]
    for i in eachindex(ms), j in eachindex(ms)
        i < j && @test ms[i] != ms[j]
    end
end

@testset "derivation_spike clean/tainted classification" begin
    clean_read = (
        access=:(system.elevator[evt.elevator_idx].floor), index_exprs=Any[:(evt.elevator_idx)]
    )
    c = spike_classify(clean_read, :evt)
    @test c.clean
    @test c.bindings == Any[:elevator_idx]

    tainted_read = (
        access=:(
            system.calls[(
                system.elevator[evt.elevator_idx].floor, system.elevator[evt.elevator_idx].direction
            )].requested
        ),
        index_exprs=Any[:((
            system.elevator[evt.elevator_idx].floor, system.elevator[evt.elevator_idx].direction
        ))],
    )
    t = spike_classify(tainted_read, :evt)
    @test !t.clean

    literal_read = (access=:(system.elevator[5].floor), index_exprs=Any[5])
    l = spike_classify(literal_read, :evt)
    @test l.clean
    @test l.bindings == Any[nothing]
end
