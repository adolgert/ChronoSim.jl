########## @invariant macro + CheckInvariants policy (Phase 1d)
#
# `@invariant` registers a named pure boolean function of the physical state per
# model module; `CheckInvariants` evaluates them after init and after every
# fire, throwing a structured `InvariantViolation` on the first failure. The
# registry is populated at LOAD time (the macro emits a top-level
# `_register_invariant!` call): the compiled function object must exist, there
# is no `eval`, and it survives precompilation because registration runs when
# the model module's top level runs.

export @invariant, CheckInvariants, InvariantViolation

public module_invariants, InvariantDef

"""
    InvariantDef

One registered [`@invariant`](@ref): `name`, the compiled Bool-valued
`checker` function of the physical state, the declared state parameter
`statesym` (free in `body`), the source `body` AST (the model-checker
compiler's input), and the declaration `source::LineNumberNode`.
"""
struct InvariantDef
    name::String
    checker::Function          # compiled Bool-valued function of physical
    statesym::Symbol           # the declared parameter name, free in `body`
    body::Any                  # source AST of the function body (Phase 4 input)
    source::LineNumberNode
end

# DEVIATION from the design (precompilation, Amendment 1). The design stored a
# single module-keyed global `_INVARIANT_REGISTRY` inside ChronoSim, populated
# at the model module's load time. That does NOT survive precompilation: the
# `@invariant` calls run during the *model* module's precompile, and their
# mutations of ChronoSim's global are discarded when the model module loads from
# its cache (only the model module's own serialized state persists). So the
# store lives in the model module instead — a `const` Vector bound in the model
# module by the macro's expansion, which IS part of that module's precompile
# image. This is the same principle as `@precondition`'s baked `precondition_ast`
# method (src/derive.jl): the survivable artifact belongs to the model module.
const _INVARIANT_STORE = :__ChronoSimInvariants__

# Get (creating if absent) the model module's per-module invariant vector. The
# vector is a `const` binding in `mod`; created during `mod`'s own top-level run
# (precompile-safe: `mod` is open at that point), so it is serialized with `mod`.
function _invariant_store(mod::Module)
    if isdefined(mod, _INVARIANT_STORE)
        return getglobal(mod, _INVARIANT_STORE)::Vector{InvariantDef}
    end
    # Build the vector first, then bind it; return the same object rather than
    # reading the binding back, so we never touch the binding in the world in
    # which it was just defined (Julia 1.12 world-age strictness).
    vec = InvariantDef[]
    Core.eval(mod, :(const $_INVARIANT_STORE = $vec))
    return vec
end

# Insertion order is declaration order; re-registering an existing name keeps
# its slot (Revise-friendly), matching the design's overwrite semantics.
function _register_invariant!(mod::Module, name::String, checker::Function,
                              statesym::Symbol, body, source::LineNumberNode)
    store = _invariant_store(mod)
    def = InvariantDef(name, checker, statesym, body, source)
    idx = findfirst(d -> d.name == name, store)
    if idx === nothing
        push!(store, def)
    else
        store[idx] = def
    end
    return nothing
end

"""
    module_invariants(mod::Module) -> Vector{InvariantDef}

The invariants registered by `mod`'s [`@invariant`](@ref) declarations, in
declaration order.
"""
module_invariants(mod::Module) =
    isdefined(mod, _INVARIANT_STORE) ?
        copy(getglobal(mod, _INVARIANT_STORE)::Vector{InvariantDef}) : InvariantDef[]

"""
    @invariant "name" function (physical) ... end

Declare a named safety invariant for the enclosing model module: a **pure
boolean function of the physical state**. The declaration registers the
compiled function (for runtime checking by [`CheckInvariants`](@ref)) and the
source body (for later compilation to a model-checker spec) under
`(module, name)`; redeclaring the same name in the same module replaces the
previous definition.

The function must take exactly one argument (the physical state), read only
that argument, and return `Bool`. It must not mutate state, draw random
numbers, or close over mutable history — the checker may re-evaluate it at any
time and expects the same answer for the same state.

```julia
@invariant "person location xor elevator" function (physical)
    all((p.location > 0 && p.elevator == 0) || (p.location == 0 && p.elevator > 0)
        for p in physical.person)
end
```

Prefer one `@invariant` per logical clause: on violation, the failing *name* is
the first diagnostic, so small named invariants localize a break the way a
per-clause error message used to.
"""
macro invariant(name, fdef)
    name isa AbstractString || error(
        "@invariant: the first argument must be a literal string name, got " *
        "`$name` at $(__source__.file):$(__source__.line)")
    statesym, body = _split_invariant_fn(fdef, __source__)
    return quote
        ChronoSim._register_invariant!($__module__, $(String(name)),
            $(esc(fdef)), $(QuoteNode(statesym)), $(QuoteNode(body)),
            $(QuoteNode(__source__)))
    end
end

# Accepts exactly two anonymous shapes; everything else errors naming the
# construct and its source location (_fragment_error discipline).
function _split_invariant_fn(fdef, src)
    where_ = "at $(src.file):$(src.line)"
    if fdef isa Expr && fdef.head === :function && fdef.args[1] isa Expr &&
            fdef.args[1].head === :tuple
        args = fdef.args[1].args
        length(args) == 1 || error("@invariant: the function must take exactly " *
            "one argument (the physical state), got $(length(args)) $where_")
        return (_invariant_param(args[1], where_), fdef.args[2])
    elseif fdef isa Expr && fdef.head === :(->)
        arg = fdef.args[1]
        arg isa Expr && arg.head === :tuple && length(arg.args) == 1 && (arg = arg.args[1])
        return (_invariant_param(arg, where_), fdef.args[2])
    end
    error("@invariant: expected an anonymous function of the physical state — " *
        "`@invariant \"name\" function (physical) ... end` or " *
        "`@invariant \"name\" physical -> ...` — got `$(fdef isa Expr ? fdef.head : fdef)` $where_")
end

function _invariant_param(a, where_)
    a isa Symbol && return a
    a isa Expr && a.head === :(::) && a.args[1] isa Symbol && return a.args[1]
    error("@invariant: the argument must be a plain name (optionally `::Type`), " *
        "got `$a` $where_ — keyword, vararg, and destructured parameters are not " *
        "supported; the invariant is a boolean function of physical only")
end

########## The policy

struct _CompiledInvariant{F}
    name::String
    fn::F
    source::LineNumberNode
end

"""
    CheckInvariants(model::Module)

An [`ExecutionPolicy`](@ref) that evaluates every [`@invariant`](@ref)
registered by `model` after initialization and after every fired event, in
declaration order. On the first invariant that returns `false` it throws an
[`InvariantViolation`](@ref) identifying the invariant, the firing event, and
the written addresses that the invariant reads (the *guilty* addresses).

Checking is opt-in and debug/test-tier: pass `policy=CheckInvariants(MyModel)`
to [`SimulationFSM`](@ref), or compose it with a recorder so the violation
carries a replayable prefix:

```julia
rec = RecordSkeleton()
sim = SimulationFSM(physical, events; seed=42,
    policy=PolicyStack(rec, CheckInvariants(MyModel)))
```

Throws an `ArgumentError` at construction when `model` registers no
invariants. The per-fire cost is the cost of the invariant bodies themselves;
state reads are only captured on the failure path.
"""
mutable struct CheckInvariants{T<:Tuple} <: ExecutionPolicy
    model::Module
    invariants::T              # NTuple of _CompiledInvariant{F}, concrete: per-call static dispatch
    fires::Int                 # this policy's own fire count (1a: no step counter on SimulationFSM)
end

function CheckInvariants(mod::Module)
    defs = module_invariants(mod)
    isempty(defs) && throw(ArgumentError(
        "CheckInvariants($mod): no @invariant is registered for this module. " *
        "Declare `@invariant \"name\" function (physical) ... end` at the module " *
        "top level (and make sure the module is loaded) before constructing the policy."))
    invs = Tuple(_CompiledInvariant(d.name, d.checker, d.source) for d in defs)
    return CheckInvariants{typeof(invs)}(mod, invs, 0)
end

function on_init(chk::CheckInvariants, sim, init_evt, changed_places)
    chk.fires = 0                              # re-init resets, 1b decision-9 precedent
    _check_invariants(chk, sim, clock_key(init_evt), sim.when, changed_places, 0)
    return nothing
end

function on_postfire(chk::CheckInvariants, sim, clock_key_, event, when, changed_places)
    chk.fires += 1
    _check_invariants(chk, sim, clock_key_, when, changed_places, chk.fires)
    # The plain-call sweep pushed its reads onto physical.obs_read. Every
    # capture_state_reads empties that vector before use, so this is purely a
    # memory cap for runs whose fires trigger no precondition re-evaluation.
    empty!(getfield(sim.physical, :obs_read))
    return nothing
end

_check_invariants(chk, sim, ck, when, changed, step) =
    _check_each(chk.invariants, chk, sim, ck, when, changed, step)

@inline _check_each(::Tuple{}, chk, sim, ck, when, changed, step) = nothing
@inline function _check_each(invs::Tuple, chk, sim, ck, when, changed, step)
    inv = first(invs)
    ok = inv.fn(sim.physical)                  # plain call: the happy path captures nothing
    ok isa Bool || error(
        "@invariant \"$(inv.name)\" (declared at $(inv.source.file):$(inv.source.line)) " *
        "returned $(typeof(ok)), not Bool. An invariant must be a boolean function " *
        "of the physical state.")
    ok || _throw_violation(chk, inv, sim, ck, when, changed, step)
    return _check_each(Base.tail(invs), chk, sim, ck, when, changed, step)
end

# Cold path: re-run under read capture to learn what the failing evaluation
# read (decision 4), intersect with this fire's writes, attach the skeleton.
@noinline function _throw_violation(chk, inv, sim, ck, when, changed, step)
    reads_result = capture_state_reads(sim.physical) do
        inv.fn(sim.physical)
    end
    reads = collect(Tuple, reads_result.reads)
    guilty = Tuple[a for a in reads if a in changed]
    reproduced = reads_result.result === false
    rec = find_policy(RecordSkeleton, sim.policy)
    skel = (rec === nothing || rec.recorder === nothing) ? nothing : recorded_skeleton(rec)
    cmd = (skel === nothing || step == 0) ? nothing :
        "replay(sim_factory, skeleton; upto=$(step - 1))"
    throw(InvariantViolation(inv.name, chk.model, inv.source, step, ck, when,
        guilty, reads, collect(Tuple, changed), reproduced, skel, cmd))
end

########## InvariantViolation + showerror

"""
    InvariantViolation

Thrown by [`CheckInvariants`](@ref) when a registered invariant evaluates to
`false`. Carries the full forensic payload; `whystopped` prints it, and
`showerror` renders the same fields.

# Fields
  * `name::String` — the violated invariant's declared name.
  * `model::Module` — the module whose registry supplied it.
  * `source::LineNumberNode` — where the invariant was declared.
  * `step::Int` — fires since initialization; `0` means the initializer itself
    left the state in violation.
  * `event::Any` — clock key of the event whose fire broke the invariant (the
    initializer's key at step 0).
  * `when::Float64` — the firing time.
  * `guilty::Vector{Tuple}` — addresses **both** written by this fire and read
    by the failing invariant evaluation: which write broke it. May be empty
    when the invariant reads untracked state or the overlap is invisible.
  * `reads::Vector{Tuple}` — every address the failing evaluation read.
  * `changed::Vector{Tuple}` — every address this fire wrote.
  * `reproduced::Bool` — `false` when re-evaluation under read capture
    returned `true`, i.e. the invariant is not a pure function of state.
  * `skeleton::Union{Nothing,TrajectorySkeleton}` — the recorded prefix, when
    a [`RecordSkeleton`](@ref) shares the policy stack.
  * `replay_command::Union{Nothing,String}` — the exact `replay(...)` call
    that reproduces the state one step before the violation; `nothing` when no
    skeleton was recorded or the violation is at step 0.
"""
struct InvariantViolation <: Exception
    name::String
    model::Module
    source::LineNumberNode
    step::Int
    event::Any                 # clock key tuple
    when::Float64
    guilty::Vector{Tuple}
    reads::Vector{Tuple}
    changed::Vector{Tuple}
    reproduced::Bool
    skeleton::Union{Nothing,TrajectorySkeleton}
    replay_command::Union{Nothing,String}
end

const _SHOW_ADDR_CAP = 8

function _print_addrs(io, addrs, cap)
    for a in Iterators.take(addrs, cap)
        println(io, "    ", a)
    end
    length(addrs) > cap && println(io, "    ... and $(length(addrs) - cap) more")
end

function Base.showerror(io::IO, e::InvariantViolation)
    println(io, "InvariantViolation: invariant \"", e.name, "\" is false")
    println(io, "  model    : ", e.model)
    println(io, "  declared : ", e.source.file, ":", e.source.line)
    println(io, "  step     : ", e.step, e.step == 0 ?
        " (violated by the initializer, before any event fired)" :
        " (fires since init)")
    println(io, "  event    : ", e.event)
    println(io, "  when     : ", e.when)
    if isempty(e.guilty)
        println(io, "  guilty   : none identified — no address this fire wrote is read ")
        println(io, "             by the invariant (untracked reads, or corruption that ")
        println(io, "             predates this step)")
    else
        println(io, "  guilty   : ", length(e.guilty),
            " address(es) written by this fire AND read by the invariant")
        _print_addrs(io, e.guilty, _SHOW_ADDR_CAP)
    end
    println(io, "  reads    : ", length(e.reads), " address(es) in the failing evaluation")
    _print_addrs(io, e.reads, _SHOW_ADDR_CAP)
    e.reproduced || println(io,
        "  WARNING  : re-evaluation under read capture returned true — this invariant ",
        "is not a pure function of the physical state")
    if e.replay_command !== nothing
        println(io, "  replay   : ", e.replay_command,
            "   # reproduces the state one step before the violation")
    elseif e.step == 0
        println(io, "  replay   : n/a — re-run the initializer to reproduce this state")
    else
        println(io, "  replay   : no skeleton recorded; compose ",
            "PolicyStack(RecordSkeleton(), CheckInvariants(", nameof(e.model),
            ")) to capture one")
    end
    print(io, "The invariant held after the previous step; the writes above broke it.")
end
