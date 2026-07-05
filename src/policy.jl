########## Executor policy trait
#
# The executor drives every simulation through six hook points. A policy
# observes those hooks; the default `NoPolicy` compiles to nothing at every
# site. The policy is carried as a type parameter of `SimulationFSM`, so a
# concrete policy type gives static dispatch and the no-op path costs a
# production run zero time and zero allocation. Later phases (skeleton
# recording, replay probes, `@invariant`, why-verbs, effect-conformance) plug
# in here by subtyping `ExecutionPolicy` and overriding only the hooks they need.

"""
    ExecutionPolicy

Abstract supertype for executor policies. A policy observes the simulation
executor at six hook points: [`on_init`](@ref), [`on_propose`](@ref),
[`on_enable`](@ref), [`on_disable`](@ref), [`on_prefire`](@ref), and
[`on_postfire`](@ref). Every hook has a no-op default returning `nothing`, so a
concrete policy overrides only the hooks it needs. The policy is stored as a
type parameter of [`SimulationFSM`](@ref); the default [`NoPolicy`](@ref)
compiles to nothing at every hook site and costs a production run zero time and
zero allocation.

Hooks are called with the live simulation as the second argument. A policy must
not mutate the physical state, the sampler, or the RNG; doing so breaks the
determinism guarantees the differential tests enforce.
"""
abstract type ExecutionPolicy end

"""
    NoPolicy()

The default [`ExecutionPolicy`](@ref): every hook is a no-op that the compiler
removes. Constructing a [`SimulationFSM`](@ref) without a `policy` keyword uses
this policy.
"""
struct NoPolicy <: ExecutionPolicy end

"""
    on_init(policy, sim, init_evt, changed_places)

Called once, after the initializer has run and the initial event set is enabled
(state/event invariant holds), before the user observer sees the initial state.
`changed_places` is the set of addresses the initializer wrote.
"""
on_init(::ExecutionPolicy, sim, init_evt, changed_places) = nothing

"""
    on_propose(policy, sim, event)

Called once per candidate event that a generator proposed and that survived
deduplication, before its precondition is evaluated. Admitted candidates are
reported by the subsequent [`on_enable`](@ref).
"""
on_propose(::ExecutionPolicy, sim, event) = nothing

"""
    on_enable(policy, sim, clock_key, event, distribution, te)

Called each time a clock's firing distribution is committed to the sampler:
both when a newly-admitted event is enabled and when a still-enabled event is
re-enabled with a replacement distribution. `te` is the absolute zero time of
`distribution`; the enabling wall-clock time is `sim.when`.
"""
on_enable(::ExecutionPolicy, sim, clock_key, event, distribution, te) = nothing

"""
    on_disable(policy, sim, clock_key)

Called when an enabled clock is disabled because its precondition no longer
holds, before it is removed from `sim.enabled_events`. The clock that fires is
consumed, not disabled, and is reported by [`on_prefire`](@ref) and
[`on_postfire`](@ref) instead.
"""
on_disable(::ExecutionPolicy, sim, clock_key) = nothing

"""
    on_prefire(policy, sim, clock_key, event, when)

Called immediately before `event` fires at time `when`: `sim.when` still holds
the previous event time and no state has been mutated yet.
"""
on_prefire(::ExecutionPolicy, sim, clock_key, event, when) = nothing

"""
    on_postfire(policy, sim, clock_key, event, when, changed_places)

Called after `event` fired at `when` and the enabled-event set has been brought
back into agreement with the new state, before the user observer runs.
`changed_places` contains every address written by the event and by any
immediate events it triggered.
"""
on_postfire(::ExecutionPolicy, sim, clock_key, event, when, changed_places) = nothing

public ExecutionPolicy, NoPolicy, on_init, on_propose, on_enable, on_disable,
    on_prefire, on_postfire
