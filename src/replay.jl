########## Deterministic replay with probes (Phase 1c)
#
# Two consumers of 1b's `TrajectorySkeleton`. `replay` re-executes a recorded
# run bit-for-bit, checking `(clock_key, when)` at every step against the
# skeleton at the exact code point where `run` evaluates its stop condition, so
# the random stream is reproduced identically. Probes ride separately in a
# `ProbePolicy`. Purely additive: no framework/policy/derive file is edited, so
# a run without `ProbePolicy` pays nothing.

export replay, ReplayDivergence

public ProbePolicy

"""
    ReplayDivergence(step, expected, actual)

Thrown by [`replay`](@ref) when the re-executed run fires a different
`(clock_key, when)` than the skeleton recorded at `step`. `expected` is
`(clock, when)` from the skeleton; `actual` is the re-run's `(clock, when)`,
or `nothing` when the re-run's sampler ran out of events before reaching
`step`. Replay is exact — there is no tolerance — so any divergence means the
rebuilt simulation is not the recorded one: check constructor arguments,
package versions, and that no model code uses randomness outside `sim.rng`.
"""
struct ReplayDivergence <: Exception
    step::Int
    expected::Tuple{Any,Float64}                  # (clock_key, when) from skeleton
    actual::Union{Nothing,Tuple{Any,Float64}}     # nothing => sampler exhausted early
end

function Base.showerror(io::IO, e::ReplayDivergence)
    println(io, "ReplayDivergence at step ", e.step)
    println(io, "  expected : ", e.expected[1], " at t=", e.expected[2])
    if e.actual === nothing
        println(io, "  actual   : (no event; sampler exhausted before this step)")
    else
        println(io, "  actual   : ", e.actual[1], " at t=", e.actual[2])
        if e.actual[1] == e.expected[1]
            println(io, "  clock matches; time differs by ", e.actual[2] - e.expected[2])
        end
    end
    println(io, "Replay is exact: this rebuilt simulation is not the recorded run.")
    print(io,   "Check: same constructor args; same package/Julia versions; ",
        "no randomness outside sim.rng.")
end

"""
    ProbePolicy(probes::Tuple)

An [`ExecutionPolicy`](@ref) that calls each probe at three points of every
step: `probe(sim, step, phase, event, when)` where `phase` is `:init` (once,
step 0, after initialization), `:prefire` (before the step's event mutates
state; `sim.when` still holds the previous time), and `:postfire` (state and
enabled set settled, before the user observer). Probes must only observe:
never mutate state, the sampler, or the RNG. Installed automatically by
[`replay`](@ref)'s `probes` keyword; usable directly as
`SimulationFSM(...; policy=ProbePolicy((p1, p2)))` to probe a forward run.
"""
mutable struct ProbePolicy{P<:Tuple} <: ExecutionPolicy
    probes::P
    step::Int          # fires counted by the policy itself (1a: no sim counter)
end
ProbePolicy(probes::Tuple) = ProbePolicy(probes, 0)

@inline function _call_probes(p::ProbePolicy, sim, step, phase, event, when)
    for probe in p.probes
        probe(sim, step, phase, event, when)
    end
    return nothing
end

on_preinit(p::ProbePolicy, sim) = (p.step = 0; nothing)   # re-run safe, like 1b
on_init(p::ProbePolicy, sim, init_evt, changed) =
    _call_probes(p, sim, 0, :init, init_evt, sim.when)
function on_prefire(p::ProbePolicy, sim, clock, event, when)
    p.step += 1
    return _call_probes(p, sim, p.step, :prefire, event, when)
end
on_postfire(p::ProbePolicy, sim, clock, event, when, changed) =
    _call_probes(p, sim, p.step, :postfire, event, when)

# Internal: the before_step! gate for _step_loop!. Sits where run's
# _StopAdapter sits: after the sampler draw, before fire!.
mutable struct _ReplayGate{CK}
    steps::Vector{SkeletonStep{CK}}
    limit::Int          # replay this many steps (== upto, or length(steps))
    checked::Int        # steps successfully matched so far
end
function (g::_ReplayGate)(sim::SimulationFSM, step_idx, what, when)
    step_idx > g.limit && return true             # upto / end-of-skeleton stop
    expected = g.steps[step_idx]
    if !(expected.clock == what && expected.when == when)   # exact, no tolerance
        throw(ReplayDivergence(step_idx, (expected.clock, expected.when), (what, when)))
    end
    g.checked = step_idx
    return false
end

"""
    replay(sim_factory, skeleton; upto=nothing, probes=()) -> SimulationFSM

Deterministically re-execute a run recorded as a [`TrajectorySkeleton`](@ref)
and return the live simulation for inspection.

`sim_factory` is called as `sim_factory(policy)` and must return
`(sim, initializer)`: a fresh `SimulationFSM` built with the SAME constructor
arguments as the recorded run and with the given `policy` passed through
(`SimulationFSM(...; policy=policy)`), plus the same initializer (a `SimEvent`
or an init function) that was given to `run`. Any `seed`/`rng` the factory
passes is overwritten: replay restores `skeleton.rng_state` before
initializing, so the re-run consumes the identical random stream.

At every step, the fired `(clock_key, when)` is checked against
`skeleton.steps` at the same code point where `run` evaluates its stop
condition (before firing). A mismatch throws [`ReplayDivergence`](@ref) —
determinism is broken, which is itself a bug to surface loudly: the usual
causes are different constructor arguments, a different package/Julia version,
or model code drawing randomness from outside `sim.rng`.

`upto=k` stops after step `k` fires and returns the sim in exactly the state
the original run had after its k-th event (`upto=0` returns the initialized
state). `probes` is a tuple of functions called as
`probe(sim, step, phase, event, when)` with `phase` one of `:init`,
`:prefire`, `:postfire`; see [`ProbePolicy`](@ref).

```julia
skel = load_skeleton("smoke.skel")
sim = replay(skel; upto=17) do policy
    physical = Village(30, 10, 1.0, Xoshiro(0))   # same ctor args; rng is overwritten
    sim = SimulationFSM(physical, EVENTS; policy=policy)
    (sim, InitEvent())
end
guard_clauses(Infect(3, 7), sim.physical)
```
"""
function replay(sim_factory::Function, skeleton::TrajectorySkeleton;
                upto::Union{Nothing,Int}=nothing, probes::Tuple=())
    limit = upto === nothing ? length(skeleton.steps) : upto
    0 <= limit <= length(skeleton.steps) || throw(ArgumentError(
        "upto=$upto is outside this skeleton's 0:$(length(skeleton.steps)) steps"))
    policy = ProbePolicy(probes)
    (sim, initializer) = _replay_factory_result(sim_factory(policy))
    sim.policy === policy || throw(ArgumentError(
        "sim_factory must pass the policy it is given: SimulationFSM(...; policy=policy)"))
    (init_evt, init_func) = _resolve_initializer(initializer)   # mirrors run's two forms
    copy!(sim.rng, skeleton.rng_state)      # 1b decision 1: the exact restore point
    initialize!(init_evt, init_func, sim)   # on_preinit -> callback -> enables, as recorded
    limit == 0 && return sim
    gate = _ReplayGate(skeleton.steps, limit, 0)
    _step_loop!(sim, _SamplerNext(), gate)
    gate.checked == limit || throw(ReplayDivergence(
        gate.checked + 1,
        (skeleton.steps[gate.checked + 1].clock, skeleton.steps[gate.checked + 1].when),
        nothing))
    return sim
end

_replay_factory_result(t::Tuple{Any,Any}) = t
_replay_factory_result(other) = throw(ArgumentError(
    "sim_factory(policy) must return (sim::SimulationFSM, initializer); got $(typeof(other))"))

_resolve_initializer(evt::SimEvent) =
    (evt, (physical, when, rng) -> fire!(evt, physical, when, rng))
_resolve_initializer(f::Function) = (InitializeEvent(), f)
