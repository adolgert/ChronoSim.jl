# The Quint compiler — trace export, toolchain discovery, and `validate_trace`.
#
# Reconstructs a recorded trajectory's states with `replay`+a snapshot probe,
# serializes each into a Quint record literal (the value emitter), emits an
# embedded `<name>_trace` module (D3), and checks it: stage 1 (`quint run`, Node)
# that every recorded state satisfies every compiled invariant; stage 2
# (`quint verify`, Apalache) that every recorded transition is accepted by the
# recorded event's parameterized action (D5). Missing tooling yields `:skipped`.

########################### Toolchain discovery ###########################

"""
    find_quint_toolchain(; quint_dir=get(ENV, "CHRONOSIM_QUINT", nothing),
                           java_home=get(ENV, "JAVA_HOME", nothing)) -> QuintToolchain

Locate the pinned checkers. Never installs anything.
"""
function find_quint_toolchain(; quint_dir=get(ENV, "CHRONOSIM_QUINT", nothing),
                                java_home=get(ENV, "JAVA_HOME", nothing))
    quint = nothing
    if quint_dir !== nothing && isdir(quint_dir)
        binpath = joinpath(quint_dir, "node_modules", ".bin", "quint")
        if isfile(binpath)
            quint = `$binpath`
        elseif Sys.which("npx") !== nothing
            quint = `npx --prefix $quint_dir quint`
        end
    end
    if quint === nothing
        w = Sys.which("quint")
        w === nothing || (quint = `$w`)
    end
    jh = java_home
    if jh === nothing && Sys.which("java") !== nothing
        jh = "__PATH__"
    end
    return QuintToolchain(quint, jh, Dict{String,String}())
end

# Env overrides for a quint invocation (JAVA_HOME for Apalache), or `nothing` to
# inherit the parent environment unchanged.
function _quint_env(t::QuintToolchain)
    (t.java_home === nothing || t.java_home == "__PATH__") && return nothing
    return ["JAVA_HOME" => t.java_home,
            "PATH" => joinpath(t.java_home, "bin") * ":" * get(ENV, "PATH", "")]
end

########################### State reconstruction ###########################

# A probe that serializes the schema vars from `sim.physical` at :init/:postfire.
mutable struct _SnapshotProbe
    schema::_QuintSchema
    states::Vector{String}
end

function (p::_SnapshotProbe)(sim, step, phase, event, when)
    (phase === :init || phase === :postfire) || return nothing
    push!(p.states, _serialize_state(p.schema, sim.physical))
    return nothing
end

# One Quint record literal `{ v1: ..., v2: ... }` for the current physical state.
function _serialize_state(schema::_QuintSchema, physical)
    parts = String[]
    for f in schema.fields
        f.kind in (:scalar, :array1, :arrayN, :dict, :set) || continue
        v = _emit_value(schema, fieldtype(schema.ptype, f.name), getfield(physical, f.name))
        push!(parts, string(f.emit) * ": " * v)
    end
    return "{ " * join(parts, ", ") * " }"
end

########################### Trace module emission ###########################

# Build the `<name>_trace` module text from the reconstructed state literals and
# the recorded event/args per step.
function _emit_trace_module(qm::QuintModel, states::Vector{String}, steps)
    schema = qm.schema
    statetype = "{ " * join((string(f.emit) * ": " * f.quinttype
        for f in schema.fields if f.kind in (:scalar, :array1, :arrayN, :dict, :set)), ", ") * " }"
    io = IOBuffer()
    tname = qm.name * "_trace"
    println(io, "// ", tname, ".qnt — generated; do not edit.")
    println(io, "module ", tname, " {")
    println(io, "  import ", qm.name, ".* from \"./", qm.name, "\"")
    println(io)
    N = length(states)
    println(io, "  pure val TraceN = ", N)
    println(io, "  pure val TraceStates: List[", statetype, "] = [")
    for (i, s) in enumerate(states)
        println(io, "    ", s, i < N ? "," : "")
    end
    println(io, "  ]")
    println(io)
    # per-invariant pure-def form is not available generically; instead check each
    # recorded state against the compiled `inv` by substituting the state's fields.
    # We reuse the model invariant defs by evaluating them over the trace states via
    # a state-parameterized wrapper is not emittable here, so stage 1 checks each
    # var's presence and the compiled inv over the *current* vars after t_init.
    println(io, "  var t_i: int")
    # init to state 0
    inits = String[]
    for f in schema.fields
        f.kind in (:scalar, :array1, :arrayN, :dict, :set) || continue
        push!(inits, string(f.emit) * "' = TraceStates[0]." * string(f.emit))
    end
    println(io, "  action t_init = all {")
    for x in inits
        println(io, "    ", x, ",")
    end
    println(io, "    t_i' = 1,")
    println(io, "  }")
    println(io)
    # step: advance to the next recorded state (data replay), guard: matches prefix
    matchparts = String[string(f.emit) * " == TraceStates[t_i - 1]." * string(f.emit)
        for f in schema.fields if f.kind in (:scalar, :array1, :arrayN, :dict, :set)]
    println(io, "  action t_step = all {")
    println(io, "    t_i < TraceN,")
    for f in schema.fields
        f.kind in (:scalar, :array1, :arrayN, :dict, :set) || continue
        println(io, "    ", f.emit, "' = TraceStates[t_i]." * string(f.emit) * ",")
    end
    println(io, "    t_i' = t_i + 1,")
    println(io, "  }")
    println(io)
    # stage-1 target: every recorded state satisfies the compiled invariant
    # (`inv` is imported unqualified from the model module).
    hasinv = occursin("val inv =", qm.text)
    println(io, "  val traceStatesInv = ", hasinv ? "inv" : "true")
    println(io, "}")
    return String(take!(io))
end

########################### Shell-out ###########################

# Run one quint invocation, teeing output to `logpath`. Returns `:ok` when the
# process ran (any exit code — a found violation exits nonzero and is a normal
# outcome decided from the log) or `:crashed` when it could not be spawned.
function _run_quint(t::QuintToolchain, args::Vector{String}, logpath::String;
                    dir::AbstractString=dirname(logpath))
    cmd = `$(t.quint) $args`
    env = _quint_env(t)
    scmd = env === nothing ? setenv(cmd; dir=dir) : addenv(setenv(cmd; dir=dir), env...)
    return open(logpath, "w") do io
        try
            Base.run(pipeline(ignorestatus(scmd); stdout=io, stderr=io))
            :ok
        catch err
            msg = sprint(showerror, err)
            write(io, "CRASHED: could not run the quint toolchain\n", msg, "\n")
            :crashed
        end
    end
end

# quint run reports "[ok]"/"No violation" on success; a violation prints a trace.
function _run_passed(logpath::String)
    txt = read(logpath, String)
    occursin("[ok]", txt) || occursin("No violation", txt)
end

_run_violated(logpath::String) = occursin("[violation]", read(logpath, String))

# The last `n` lines of a checker log, for :error skip_reason texts.
function _log_tail(logpath::String, n::Int=4)
    isfile(logpath) || return "(no log)"
    lines = readlines(logpath)
    join(lines[max(1, end - n + 1):end], " | ")
end

########################### validate_trace ###########################

"""
    validate_trace(qm::QuintModel, skeleton::TrajectorySkeleton, sim_factory;
                   maxsteps::Int=50, workdir=mktempdir(),
                   toolchain::QuintToolchain=find_quint_toolchain())
        -> TraceValidationReport

Check a recorded trajectory against the compiled spec. The skeleton stores only
`(clock, when, changed)` per step, so full states are reconstructed by `replay`
with a snapshotting probe; `sim_factory` is exactly `replay`'s factory:
`sim_factory(policy) -> (sim, initializer)` with the recorded run's constructor
arguments.

Two checks, reported separately:
  * `invariants` — every reconstructed state satisfies every compiled invariant
    (`quint run` on the generated trace module; Node only).
  * `transitions` — every recorded step is accepted by the recorded event's
    compiled action from the preceding state (`quint verify`/Apalache on the
    forced-step module; needs a JVM).
Each verdict is `:passed`, `:failed` (with `first_failure` naming the step, its
event and `when`, localized by the checker output or the ascending prefix loop),
`:skipped` (toolchain absent — the report prints how to install, quoting
quint_spike/VERSIONS.md), or `:error` (the checker crashed; log tail in
`skip_reason`). Steps beyond `maxsteps` are not checked and the report says so;
there are no silent caps.

    validate_trace(model, events, physical, skeleton, sim_factory; kwargs...)

Convenience form that compiles first: compile keywords (`name`, `skip_events`,
`assume_true_guards`, `invariants`, `mutate_for_test`) go to
[`compile_quint`](@ref); an unknown keyword is an `ArgumentError`.
"""
function validate_trace(qm::QuintModel, skeleton, sim_factory;
                        maxsteps::Int=50, workdir::AbstractString=mktempdir(),
                        toolchain::QuintToolchain=find_quint_toolchain())
    t0 = time()
    steps_total = length(skeleton.steps)
    upto = min(maxsteps, steps_total)
    probe = _SnapshotProbe(qm.schema, String[])
    replay(sim_factory, skeleton; upto=upto, probes=(probe,))
    states = probe.states
    steps = skeleton.steps[1:upto]

    mkpath(workdir)
    modelpath = joinpath(workdir, qm.name * ".qnt")
    write_quint(modelpath, qm)
    tmod = _emit_trace_module(qm, states, steps)
    tracepath = joinpath(workdir, qm.name * "_trace.qnt")
    open(tracepath, "w") do io
        write(io, tmod)
    end

    logs = Dict{Symbol,String}()
    skip = Dict{Symbol,String}()
    inv_verdict = :skipped
    trans_verdict = :skipped
    first_failure = nothing

    if !quint_available(toolchain)
        skip[:invariants] = _INSTALL_QUINT
        skip[:transitions] = _INSTALL_QUINT
    else
        # stage 1: quint run on the trace module (invariants over recorded states)
        log1 = joinpath(workdir, "stage1_run.log"); logs[:invariants] = log1
        r1 = _run_quint(toolchain, String["run", "--max-steps=$(max(1, length(states) - 1))",
            "--max-samples=1", "--init=t_init", "--step=t_step",
            "--invariant=traceStatesInv", tracepath], log1; dir=workdir)
        if r1 === :crashed
            inv_verdict = :error
            skip[:invariants] = "checker crashed: " * _log_tail(log1)
        elseif _run_passed(log1)
            inv_verdict = :passed
        elseif _run_violated(log1)
            inv_verdict = :failed
            first_failure = _stage1_failure(log1, skeleton)
        else
            inv_verdict = :error
            skip[:invariants] = "unrecognized checker output: " * _log_tail(log1)
        end
        # stage 2 needs a JVM; forced-step verification is Apalache-gated
        if !java_available(toolchain)
            skip[:transitions] = _INSTALL_JAVA
        else
            s2 = _stage2_transitions(qm, states, steps, workdir, toolchain)
            trans_verdict = s2.verdict
            s2.reason == "" || (skip[:transitions] = s2.reason)
            for (k, v) in s2.logs
                logs[k] = v
            end
            if s2.failure !== nothing && first_failure === nothing
                first_failure = s2.failure
            end
        end
    end
    return TraceValidationReport(Symbol(qm.name), inv_verdict, trans_verdict, upto, steps_total,
        first_failure, skip, logs, time() - t0)
end

const _VALIDATE_COMPILE_KEYS = (:name, :skip_events, :assume_true_guards, :invariants,
                                :mutate_for_test)
const _VALIDATE_CHECK_KEYS = (:maxsteps, :workdir, :toolchain)

# Convenience form: compile first. Unknown keywords throw instead of being dropped.
function validate_trace(model::Module, events::AbstractVector, physical, skeleton, sim_factory;
                        kwargs...)
    ck = Pair{Symbol,Any}[k => v for (k, v) in pairs(kwargs) if k in _VALIDATE_COMPILE_KEYS]
    vk = Pair{Symbol,Any}[k => v for (k, v) in pairs(kwargs) if k in _VALIDATE_CHECK_KEYS]
    leftover = [k for (k, _) in pairs(kwargs)
                if !(k in _VALIDATE_COMPILE_KEYS) && !(k in _VALIDATE_CHECK_KEYS)]
    isempty(leftover) || throw(ArgumentError(
        "validate_trace: unknown keyword argument(s) $(Tuple(leftover)); " *
        "compile keywords are $(_VALIDATE_COMPILE_KEYS), " *
        "checker keywords are $(_VALIDATE_CHECK_KEYS)"))
    qm = compile_quint(model, events, physical; ck...)
    return validate_trace(qm, skeleton, sim_factory; vk...)
end

# Stage-1 localization: the trace-module run is deterministic, so the printed
# counterexample's final `t_i: n` names the violating state: TraceStates[n-1],
# i.e. recorded step n-1 (0 = the initial state).
function _stage1_failure(logpath::String, skeleton)
    txt = read(logpath, String)
    ms = collect(eachmatch(r"t_i:\s*(\d+)", txt))
    isempty(ms) && return (step=0, event=:__init__, when=skeleton.init.when, stage=:invariants)
    idx = parse(Int, ms[end].captures[1]) - 1
    if idx <= 0 || idx > length(skeleton.steps)
        return (step=max(idx, 0), event=:__init__, when=skeleton.init.when, stage=:invariants)
    end
    s = skeleton.steps[idx]
    return (step=idx, event=s.clock[1]::Symbol, when=s.when, stage=:invariants)
end

# The `{ v1: t1, ... }` Quint type of a full recorded state.
function _state_type(schema::_QuintSchema)
    "{ " * join((string(f.emit) * ": " * f.quinttype
        for f in schema.fields if f.kind in (:scalar, :array1, :arrayN, :dict, :set)), ", ") * " }"
end

_varfield_names(schema) =
    Symbol[f.emit for f in schema.fields if f.kind in (:scalar, :array1, :arrayN, :dict, :set)]

# The forced-step module (D5): each step forces the RECORDED event's parameterized
# action from the matched prefix state. Apalache VIOLATING `traceNotAccepted` (i.e.
# reaching t_i == TraceN with every prefix matched) is the PASS.
function _emit_forced_module(qm::QuintModel, states::Vector{String}, steps)
    schema = qm.schema
    vfs = _varfield_names(schema)
    io = IOBuffer()
    fname = qm.name * "_forced"
    println(io, "// ", fname, ".qnt — generated; do not edit.")
    println(io, "module ", fname, " {")
    println(io, "  import ", qm.name, ".* from \"./", qm.name, "\"")
    N = length(states)
    println(io, "  pure val TraceN = ", N)
    println(io, "  pure val TraceStates: List[", _state_type(schema), "] = [")
    for (i, s) in enumerate(states)
        println(io, "    ", s, i < N ? "," : "")
    end
    println(io, "  ]")
    println(io, "  var t_i: int")
    println(io, "  val currentMatches = and {")
    for v in vfs
        println(io, "    ", v, " == TraceStates[t_i - 1]." * string(v) * ",")
    end
    println(io, "  }")
    println(io, "  action t_init = all {")
    for v in vfs
        println(io, "    ", v, "' = TraceStates[0]." * string(v) * ",")
    end
    println(io, "    t_i' = 1,")
    println(io, "  }")
    println(io, "  action t_step = all {")
    println(io, "    currentMatches,")
    for (k, step) in enumerate(steps)
        call = _forced_call(qm, schema, step)
        println(io, "    ", k == 1 ? "if" : "else if", " (t_i == ", k, ") ", call)
    end
    print(io, "    else all { ")
    print(io, join((string(v) * "' = " * string(v) for v in vfs), ", "))
    println(io, ", false },")
    println(io, "    t_i' = t_i + 1,")
    println(io, "  }")
    println(io, "  val traceNotAccepted = not(t_i == TraceN and currentMatches)")
    # per-prefix reachability targets for the ascending localization loop
    for k in 2:N
        println(io, "  val notReach_", k, " = not(t_i == ", k, " and currentMatches)")
    end
    println(io, "}")
    return String(take!(io))
end

# `ev_<Event>_par(arg1, arg2, ...)` from a recorded step's clock key.
function _forced_call(qm::QuintModel, schema::_QuintSchema, step)
    ck = step.clock
    ev = ck[1]::Symbol
    parname = get(qm.actions, ev, nothing)
    parname === nothing && return "false"   # skipped event: no action to force
    args = ck[2:end]
    argstrs = String[_emit_value(schema, typeof(a), a) for a in args]
    return string(parname) * "(" * join(argstrs, ", ") * ")"
end

# Stage 2: transition acceptance via the forced-step module + `quint verify`
# (Apalache). A found violation of `traceNotAccepted` is the PASS. Returns
# `(verdict, failure, reason, logs)`; on `:failed` the ascending prefix loop
# localizes the first rejected transition.
function _stage2_transitions(qm, states, steps, workdir, toolchain)
    logs = Dict{Symbol,String}()
    # a recorded step firing a skipped event makes the forced module unsound
    for (k, step) in enumerate(steps)
        ev = step.clock[1]::Symbol
        if !haskey(qm.actions, ev)
            return (verdict=:skipped, failure=nothing, logs=logs,
                reason="recorded step $k fires `$ev`, which was skipped by " *
                       "configuration (skip_events); the PARTIAL module cannot " *
                       "force that transition")
        end
    end
    fmod = _emit_forced_module(qm, states, steps)
    fpath = joinpath(workdir, qm.name * "_forced.qnt")
    open(fpath, "w") do io
        write(io, fmod)
    end
    depth = max(1, length(states) - 1)
    logpath = joinpath(workdir, "stage2_verify.log")
    logs[:transitions] = logpath
    r = _run_quint(toolchain, String["verify", "--max-steps=$depth", "--init=t_init",
        "--step=t_step", "--invariant=traceNotAccepted", fpath], logpath; dir=workdir)
    r === :crashed && return (verdict=:error, failure=nothing, logs=logs,
        reason="checker crashed: " * _log_tail(logpath))
    outcome = _apalache_outcome(logpath)
    # Apalache outcomes on the forced-step module:
    #   Error    -> traceNotAccepted was violated: the whole trace reached t_i==TraceN
    #               with every prefix matched -> every transition ACCEPTED -> :passed.
    #   Deadlock -> the forced step could not fire at some point: a recorded event's
    #               (possibly mutated) guard/effect REJECTED the transition -> :failed.
    #   NoError  -> full acceptance was never reachable -> :failed.
    outcome == "Error" && return (verdict=:passed, failure=nothing, logs=logs, reason="")
    if outcome == "Deadlock" || outcome == "NoError"
        failure = _localize_stage2(qm, steps, length(states), fpath, workdir, toolchain, logs)
        return (verdict=:failed, failure=failure, logs=logs, reason="")
    end
    return (verdict=:error, failure=nothing, logs=logs,
        reason="unrecognized Apalache outcome `$outcome`: " * _log_tail(logpath))
end

function _apalache_outcome(logpath::String)
    m = match(r"The outcome is:\s*(\w+)", read(logpath, String))
    m === nothing ? "" : String(m.captures[1])
end

# The design's ascending localization loop: for k = 2..N, `notReach_k` holding
# (NoError) means matched state k-1 is unreachable, so recorded step k-1 is the
# first rejected transition. Each run is shallow (depth k-1); failure path only.
function _localize_stage2(qm, steps, N, fpath, workdir, toolchain, logs)
    for k in 2:N
        lp = joinpath(workdir, "stage2_localize_$k.log")
        r = _run_quint(toolchain, String["verify", "--max-steps=$(k - 1)",
            "--init=t_init", "--step=t_step", "--invariant=notReach_$k", fpath],
            lp; dir=workdir)
        r === :crashed && break
        if _apalache_outcome(lp) != "Error"      # not violated => prefix k unreachable
            logs[:localize] = lp
            s = steps[k - 1]
            return (step=k - 1, event=s.clock[1]::Symbol, when=s.when, stage=:transitions)
        end
    end
    # every prefix reachable individually (or the loop crashed): report the last step
    s = steps[end]
    return (step=length(steps), event=s.clock[1]::Symbol, when=s.when, stage=:transitions)
end
