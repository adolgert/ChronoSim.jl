using Logging
using Random
import CompetingClocks
using CompetingClocks:
    SamplingContext, SamplerBuilder, NextReactionMethod, enable!, disable!, next,
    keytype, steploglikelihood

using Distributions

export SimulationFSM, ModelDefinitionError, TraceEvaluation, trace_likelihood

########## The Simulation Finite State Machine (FSM)

mutable struct SimulationFSM{State,Sampler<:SamplingContext,CK,P<:ExecutionPolicy}
    physical::State
    sampler::Sampler
    immediategen::GeneratorSearch
    when::Float64
    rng::Xoshiro
    event_dependency::EventDependency{CK}
    enabled_events::Dict{CK,SimEvent}
    enabling_times::Dict{CK,Float64}
    observer                    # untouched: untyped, backward compatible
    policy::P                   # NEW, last field
    step_likelihood::Bool       # opt-in trace-likelihood capability
    likelihood_eltype::DataType # eltype(θ) for ForwardDiff
end


"""
Look at events and determine a common base type.
Internally the simulation tracks events with sets of tuples by turning
each event instance into a tuple. If all the tuples have the same type,
this should turn out to be performant.
"""
function common_base_key_tuple(events)
    all_field_types = [Tuple{Symbol,fieldtypes(T)...} for T in events]
    typejoined = reduce(typejoin, all_field_types)
    return typejoined
end


"""
    SimulationFSM(physical_state, trans_rules; sampler, key_type, step_likelihood,
                  likelihood_eltype, seed, rng, observer=nothing, policy=NoPolicy())

Create a simulation.

The `physical_state` is of type `PhysicalState`. The `trans_rules` are a list of
type `SimEvent`. The seed is an integer seed for a `Xoshiro` random number
generator. The observer is a callback with the signature:

```
observer(physical, when::Float64, event::SimEvent, changed_places::AbstractSet{Tuple})
```

The `changed_places` argument is a set-like object with tuples that are keys that
represent which places were changed.

The `policy` keyword is an [`ExecutionPolicy`](@ref) that observes the executor
at its hook points; it defaults to [`NoPolicy`](@ref), which compiles away and
costs a production run nothing.

# Sampler selection

The `sampler` keyword takes a CompetingClocks sampler *method spec* or a
`CompetingClocks.SamplerBuilder`, and `SimulationFSM` owns the random number
generator and builds the underlying `SamplingContext` itself.

  * `sampler=nothing` (default) uses `NextReactionMethod()`, which reproduces the
    historical `CombinedNextReaction` sampler and its exact rng stream.
  * `sampler=spec` where `spec isa CompetingClocks.SamplerSpec` (e.g.
    `NextReactionMethod()`, `FirstReactionMethod()`) builds a context around that
    method.
  * `sampler=builder` where `builder isa SamplerBuilder` uses the builder as-is;
    in that case `key_type`, `step_likelihood`, and `likelihood_eltype` must not
    also be passed (the builder already carries them).

The `key_type` keyword overrides the clock-key type (default
`common_base_key_tuple` of the events). Set `step_likelihood=true` to
opt in to the trace-likelihood machinery ([`trace_likelihood`](@ref)); passing a
non-`Float64` `likelihood_eltype` (e.g. `eltype(θ)` for `ForwardDiff`)
auto-enables it.

Passing a sampler *instance* (e.g. `CombinedNextReaction{K,Float64}()` or a
`MemorySampler`) is no longer supported and throws an `ArgumentError` with
migration guidance.
"""
function SimulationFSM(
    physical, events;
    sampler=nothing,
    key_type=nothing,
    step_likelihood::Bool=false,
    likelihood_eltype::DataType=Float64,
    observer=nothing, rng=nothing, seed=nothing,
    policy::ExecutionPolicy=NoPolicy(),
)
    randgen = if !isnothing(rng)
        rng
    elseif !isnothing(seed)
        Xoshiro(seed)
    else
        Xoshiro()
    end

    if sampler isa SamplerBuilder
        if key_type !== nothing || step_likelihood || likelihood_eltype !== Float64
            throw(ArgumentError(
                "When `sampler` is a SamplerBuilder it already carries the clock " *
                "key type and likelihood settings; do not also pass `key_type`, " *
                "`step_likelihood`, or `likelihood_eltype`."))
        end
        builder = sampler
        if builder.time_type !== Float64 || builder.start_time != 0.0 ||
                builder.support_delayed
            throw(ArgumentError(
                "SimulationFSM requires a SamplerBuilder with time_type=Float64, " *
                "start_time=0.0, and support_delayed=false; the simulation clock " *
                "is Float64, starts at 0.0, and draws via next(), which does not " *
                "handle delayed reactions."))
        end
        ClockKey = builder.clock_type
        sim_step_likelihood = builder.step_likelihood || builder.path_likelihood ||
            builder.likelihood_cnt > 1
        sim_likelihood_eltype = builder.likelihood_eltype
    else
        # A non-Float64 accumulator implies a likelihood watcher is needed.
        sim_step_likelihood = step_likelihood || likelihood_eltype !== Float64
        sim_likelihood_eltype = likelihood_eltype
        ClockKey = key_type !== nothing ? key_type : common_base_key_tuple(events)
        method = if isnothing(sampler)
            # Pin the historical default; never let the builder auto-select, which
            # would pick a different sampler and change every seeded test.
            NextReactionMethod()
        elseif sampler isa CompetingClocks.SamplerSpec
            sampler
        else
            throw(ArgumentError(
                "The `sampler` keyword now takes a sampler *method spec* " *
                "(e.g. NextReactionMethod(), FirstReactionMethod()) or a " *
                "CompetingClocks.SamplerBuilder, not a sampler instance. " *
                "SimulationFSM owns the rng and builds the SamplingContext itself. " *
                "Replace `sampler=CombinedNextReaction{K,Float64}()` with " *
                "`sampler=NextReactionMethod(), key_type=K`."))
        end
        builder = SamplerBuilder(
            ClockKey, Float64; method=method,
            step_likelihood=sim_step_likelihood, likelihood_eltype=sim_likelihood_eltype,
        )
        @debug "Creating a sampler with clock key type $ClockKey"
    end
    ctx = SamplingContext(builder, randgen)
    generator_searches = generators_from_events(events)
    if isnothing(observer)
        observer = (args...) -> nothing
    end
    return SimulationFSM{typeof(physical),typeof(ctx),ClockKey,typeof(policy)}(
        physical,
        ctx,
        generator_searches["immediate"],
        0.0,
        randgen,
        EventDependency{ClockKey}(generator_searches["timed"]),
        Dict{ClockKey,SimEvent}(),
        Dict{ClockKey,Float64}(),
        observer,
        policy,
        sim_step_likelihood,
        sim_likelihood_eltype,
    )
end


function checksim(sim::SimulationFSM)
    @assert keys(sim.enabled_events) == keys(sim.event_dependency.depnet.event)
    @assert sim.when == time(sim.sampler)
end

struct ModelDefinitionError <: Exception
    context::String
    event_type::Type
    event::Any
    cause::Exception
    backtrace::Vector
end

function Base.showerror(io::IO, e::ModelDefinitionError)
    println(io, "Error in user-defined $(e.context) for $(e.event_type)")
    println(io, "  Event: $(e.event)")
    println(io, "  Caused by:")
    showerror(io, e.cause)
    println(io, "\n\nIn model code:")
    Base.show_backtrace(io, e.backtrace)
end

function invoke_user_code(f::Function, context::String, event::SimEvent)
    try
        return f()
    catch e
        bt = catch_backtrace()
        throw(ModelDefinitionError(context, typeof(event), event, e, bt))
    end
end

"""
The three `sim_event_*` functions call user-defined code, so we separate this
out in order to check the calls and return values. This also provides a way
to mock interaction with both events and the sampler for testing the central
function `deal_with_changes()`. Subclass `SimEvent` to create a fake interaction.
"""
function sim_event_precondition(event::SimEvent, physical)
    reads_result = capture_state_reads(physical) do
        invoke_user_code("precondition", event) do
            precondition(event, physical)
        end
    end
    # Soundness oracle (opt-in): the derived triggers must cover every read the
    # precondition performed, else a change could flip it silently.
    maybe_verify_coverage(event, reads_result.reads)
    return reads_result
end


function sim_event_enable(event::SimEvent, event_key, sim, when)
    reads_result = capture_state_reads(sim.physical) do
        enabling_spec = invoke_user_code("enable", event) do
            enable(event, sim.physical, when)
        end
        if length(enabling_spec) != 2
            error("""The enable() function for $event_key should return a
                distribution and a time. This one returns $enabling_spec.
                """)
        end
        return enabling_spec
    end
    (dist, enable_time) = reads_result.result
    # User contract is absolute `enable_time`; the context takes a relative shift
    # `te = ctx.time + relative_te`, and `sim.when == time(ctx)` here.
    enable!(sim.sampler, event_key, dist, enable_time - sim.when)
    on_enable(sim.policy, sim, event_key, event, dist, enable_time)
    return (; reads=reads_result.reads)
end


function sim_event_reenable(event::SimEvent, event_key, sim)
    first_enable = sim.enabling_times[event_key]
    reads_result = capture_state_reads(sim.physical) do
        invoke_user_code("reenable", event) do
            reenable(event, sim.physical, first_enable, sim.when)
        end
    end
    if !isnothing(reads_result.result)
        (dist, enable_time) = reads_result.result
        # Absolute `enable_time` → relative shift; `sim.when == time(ctx)` here.
        enable!(sim.sampler, event_key, dist, enable_time - sim.when)
        on_enable(sim.policy, sim, event_key, event, dist, enable_time)
    end
    return reads_result.reads
end


"""
    deal_with_changes(sim::SimulationFSM, event_dependency, fired_event_keys, changed_places)

An event changed the state. This function modifies events to respond to changes in state.

 * `sim` - the simulation
 * `event_dependency` - the bipartite graph of addresses and clocks, separated out from the sim
   so that we can test more easily.
 * `fired_event_keys` - a list of what fired. It's a list because of immediate events.
 * `changed_places` - the addresses of physical state affected by firing.
"""
function deal_with_changes(
    sim::SimulationFSM{State,Sampler,CK}, event_dependency, fired_event_keys, changed_places
) where {State,Sampler,CK}
    # This function starts with enabled events. It ends with enabled events.
    # Let's look at just those events that depend on changed places.
    #                      Finish
    #                 Enabled     Disabled
    # Start  Enabled  re-enable   remove
    #       Disabled  create      nothing
    #
    # Sort for reproducibility run-to-run.
    isempty(changed_places) && return nothing

    clock_toremove = CK[]
    over_event_invariants(event_dependency, sim, fired_event_keys, changed_places) do event
        check_clock_key = clock_key(event)
        event_should_be_enabled, depends_places = sim_event_precondition(event, sim.physical)
        # While the current dependency network knows if it was enabled, we check it here
        # in case we use a dependency graph that doesn't depend on the current state.
        event_was_enabled = check_clock_key ∈ keys(sim.enabled_events)

        if event_was_enabled && !event_should_be_enabled
            push!(clock_toremove, check_clock_key)
        elseif !event_was_enabled && event_should_be_enabled
            record_admitted(event)
            sim.enabled_events[check_clock_key] = event
            sim.enabling_times[check_clock_key] = sim.when
            rate_deps, = sim_event_enable(event, check_clock_key, sim, sim.when)
            @debug "Evtkey $(check_clock_key) with enable deps $(depends_places) rate deps $(rate_deps)"
            add_event!(event_dependency, check_clock_key, depends_places, rate_deps)
        elseif event_was_enabled && event_should_be_enabled
            # Every time we check an invariant after a state change, we must
            # re-calculate how it depends on the state. For instance,
            # A can move right. Then A moves down. Then A can still move
            # right, but its moving right now depends on a different space
            # to the right. This is because a "move right" event is defined
            # relative to a state, not on a specific, absolute set of places.
            depended_on_places = getevent_enable(event_dependency, check_clock_key)
            @assert eltype(depends_places) == eltype(depended_on_places)
            if depends_places != depended_on_places
                rate_deps = sim_event_reenable(event, check_clock_key, sim)
                add_event!(event_dependency, check_clock_key, depends_places, rate_deps)
            else
                rate_deps = getevent_rate(event_dependency, check_clock_key)
                @assert eltype(rate_deps) == eltype(changed_places)
                if !isdisjoint(rate_deps, changed_places)
                    new_rate_deps = sim_event_reenable(event, check_clock_key, sim)
                    if rate_deps != new_rate_deps
                        add_event!(event_dependency, check_clock_key, depends_places, new_rate_deps)
                    end
                end
            end
            # else event wasn't enabled and it isn't now.
        end
    end

    disable_clocks!(sim, clock_toremove)
    remove_event!(event_dependency, clock_toremove)

    over_event_rates(event_dependency, sim, fired_event_keys, changed_places) do event
        rate_clock_key = clock_key(event)
        rate_event = get(sim.enabled_events, rate_clock_key, nothing)
        if !isnothing(rate_event)
            rate_deps = getevent_rate(event_dependency, rate_clock_key)
            new_rate_deps = sim_event_reenable(rate_event, rate_clock_key, sim)
            if rate_deps != new_rate_deps
                cond_deps = getevent_enable(event_dependency, rate_clock_key)
                add_event!(event_dependency, rate_clock_key, cond_deps, new_rate_deps)
            end
            # else it won't be in event_dependency either so nothing to add/delete.
        end
    end
end


function disable_clocks!(sim::SimulationFSM, clock_keys)
    isempty(clock_keys) && return nothing
    @debug "Disable clock $(clock_keys)"
    for clock_done in clock_keys
        on_disable(sim.policy, sim, clock_done)
        disable!(sim.sampler, clock_done)
        delete!(sim.enabled_events, clock_done)
        delete!(sim.enabling_times, clock_done)
    end
end


function modify_state!(sim::SimulationFSM, fire_event)
    changes_result = capture_state_changes(sim.physical) do
        fire!(fire_event, sim.physical, sim.when, sim.rng)
    end
    changed_places = changes_result.changes
    seen_immediate = SimEvent[]
    over_generated_events(
        sim.immediategen, sim.physical, clock_key(fire_event), changed_places
    ) do newevent
        if newevent ∉ seen_immediate && precondition(newevent, sim.physical)
            push!(seen_immediate, newevent)
            ans = capture_state_changes(sim.physical) do
                fire!(newevent, sim.physical, sim.when, sim.rng)
            end
            # Merge the immediate event's changed addresses element-wise;
            # push! would insert the whole set as one (mistyped) element.
            union!(changed_places, ans.changes)
        end
    end
    return changed_places
end

"""
    fire!(sim::SimulationFSM, time, event_key)

Let the event act on the state.
"""
function fire!(sim::SimulationFSM, when, what)
    event = sim.enabled_events[what]              # moved up (no side effects)
    on_prefire(sim.policy, sim, what, event, when)  # sim.when is still the old time
    sim.when = when
    # Break the invariant that state and events are consistent.
    changed_places = modify_state!(sim, event)
    # The fired clock is realized (its draw is consumed), so commit it with
    # `fire!` rather than `disable!`. Disabling would censor the draw and let a
    # reusing sampler (e.g. CombinedNextReaction) resurrect residual randomness
    # for a draw that was fully consumed -- a statistics bug for non-exponential
    # distributions. The SamplingContext's `fire!` sets `ctx.time = when` and
    # delegates to the underlying sampler's `fire!`, preserving this invariant.
    fire!(sim.sampler, what, when)
    delete!(sim.enabled_events, what)
    delete!(sim.enabling_times, what)
    remove_event!(sim.event_dependency, [what])
    deal_with_changes(sim, sim.event_dependency, what, changed_places)
    checksim(sim)
    # Invariant for states and events is restored, so show the result.
    on_postfire(sim.policy, sim, what, event, when, changed_places)
    sim.observer(sim.physical, when, event, changed_places)
end

get_enabled_events(sim::SimulationFSM) = collect(values(sim.enabled_events))

"""
Initialize the simulation. You could call it as a do-function.
It is structured this way so that the simulation will record changes to the
physical state.
```
    initialize!(sim) do init_physical
        initialize!(init_physical, agent_cnt, sim.rng)
    end
```
"""
function initialize!(init_evt, callback::Function, sim::SimulationFSM)
    on_preinit(sim.policy, sim)
    changes_result = capture_state_changes(sim.physical) do
        callback(sim.physical, sim.when, sim.rng)
    end
    # The `what` event is type Nothing to signal it isn't an event.
    deal_with_changes(sim, sim.event_dependency, nothing, changes_result.changes)
    checksim(sim)
    on_init(sim.policy, sim, init_evt, changes_result.changes)
    sim.observer(sim.physical, sim.when, init_evt, changes_result.changes)
end


"""
    run(simulation, initializer, stop_condition)

Given a simulation, this initializes the physical state and generates a
trajectory from the simulation until the stop condition is met. The `initializer`
is either a function whose argument is a physical state and returns nothing, or
it is an event key for an event that initializes the system. The
stop condition is a function with the signature:

```
stop_condition(physical_state, step_idx, event::SimEvent, when)::Bool
```

The event and when passed into the stop condition are the event and time that are
about to fire but have not yet fired. This lets you enforce a stopping time that
is between events.
"""
# Next-event source for the forward executor: draw from the sampler.
struct _SamplerNext end
function (::_SamplerNext)(sim::SimulationFSM, step_idx)
    (when, what) = next(sim.sampler)
    if isfinite(when) && !isnothing(what)
        return (when, what)
    else
        # The old forward loop logged @info exactly here, on sampler exhaustion.
        @info "No more events to process after $step_idx iterations."
        return nothing
    end
end

# Next-event source for the trace evaluator: index the recorded trace.
struct _TraceNext{T<:AbstractVector}
    trace::T
end
function (tn::_TraceNext)(sim::SimulationFSM, step_idx)
    step_idx > length(tn.trace) && return nothing
    (when, what) = tn.trace[step_idx]
    # A non-finite time or missing key ends evaluation, matching the old loop's
    # break; the old trace loop logged @info only in exactly this case.
    if isfinite(when) && !isnothing(what)
        return (when, what)
    else
        @info "No more events to process after $step_idx iterations."
        return nothing
    end
end

# Per-step gate for `run`: adapts the user stop condition. A concrete struct
# (not a closure) so the captured function's type is a parameter and the
# per-step call is statically dispatched.
struct _StopAdapter{F}
    stop_condition::F
end
function (sa::_StopAdapter)(sim::SimulationFSM, step_idx, what, when)
    return sa.stop_condition(sim.physical, step_idx, what, when)
end

# The executor seam. Both the forward executor (`run`) and the trace evaluator
# (`trace_likelihood`) drive this loop; they differ only in the two injected
# callables: `next_event(sim, step_idx) -> (when, what) | nothing` supplies the
# next event, and `before_step!(sim, step_idx, what, when) -> Bool` runs the
# per-step gate (stop condition or feasibility + accumulation) and returns
# `true` to stop before firing.
function _step_loop!(sim::SimulationFSM, next_event::N, before_step!::B) where {N,B}
    step_idx = 1
    while true
        nxt = next_event(sim, step_idx)
        if !isnothing(nxt)
            (when, what) = nxt
            before_step!(sim, step_idx, what, when) && break
            @debug "Firing $what at $when"
            fire!(sim, when, what)
        else
            break
        end
        step_idx += 1
    end
    return step_idx
end

function run(sim::SimulationFSM, init_evt::SimEvent, init_func::Function, stop_condition::Function)
    initialize!(init_evt, init_func, sim)
    stop_condition(sim.physical, 0, init_evt, sim.when) && return nothing
    return _step_loop!(sim, _SamplerNext(), _StopAdapter(stop_condition))
end

function run(sim::SimulationFSM, init_evt::SimEvent, stop_condition::Function)
    init_func = (physical, when, rng) -> fire!(init_evt, physical, when, rng)
    run(sim, init_evt, init_func, stop_condition)
end

function run(sim::SimulationFSM, initializer::Function, stop_condition::Function)
    run(sim, InitializeEvent(), initializer, stop_condition)
end

"""
    TraceEvaluation

The result of evaluating a recorded trace against a model with
[`trace_likelihood`](@ref).

# Fields

  * `loglikelihood::L` — sum of the per-step log-likelihoods, or `-Inf`
    when the trace is infeasible under the model. The element type `L` is
    `sim.likelihood_eltype` (`Float64` by default, or a `ForwardDiff.Dual`
    when `likelihood_eltype=eltype(θ)` was passed for gradients).
  * `feasible::Bool` — `true` when every step of the trace named an enabled
    event at a time strictly after the previous event.
  * `steps_evaluated::Int` — number of steps successfully evaluated; equals
    `length(steploglik)`. When infeasible, evaluation stopped at step
    `steps_evaluated + 1`.
  * `first_infeasible::Union{Nothing,Tuple{Int,Any,Symbol}}` — `nothing` for a
    feasible trace, else `(step, event, reason)` for the first failing step.
    `reason` is `:not_enabled` (the event was not in `sim.enabled_events` when
    its turn came) or `:time_order` (its time was not strictly greater than the
    simulation clock).
  * `steploglik::Vector{L}` — the per-step log-likelihood contributions,
    one entry per evaluated step.

The `sim` passed to [`trace_likelihood`](@ref) must be constructed with
`step_likelihood=true` so its `SamplingContext` records the enabled-clock
likelihood. To make the result differentiable with `ForwardDiff`, also pass
`likelihood_eltype=eltype(θ)`, which sets `L` to the Dual number type.
"""
struct TraceEvaluation{L<:Real}
    loglikelihood::L
    feasible::Bool
    steps_evaluated::Int
    first_infeasible::Union{Nothing,Tuple{Int,Any,Symbol}}
    steploglik::Vector{L}
end

function Base.show(io::IO, ev::TraceEvaluation)
    print(io, "TraceEvaluation(feasible=", ev.feasible,
        ", loglikelihood=", ev.loglikelihood,
        ", steps_evaluated=", ev.steps_evaluated, ")")
end

function Base.show(io::IO, ::MIME"text/plain", ev::TraceEvaluation)
    println(io, "TraceEvaluation")
    println(io, "  feasible         : ", ev.feasible)
    println(io, "  loglikelihood    : ", ev.loglikelihood)
    println(io, "  steps evaluated  : ", ev.steps_evaluated)
    if ev.first_infeasible === nothing
        print(io,   "  first infeasible : none")
    else
        (step, event, reason) = ev.first_infeasible
        print(io,   "  first infeasible : step ", step, ", event ", event,
            ", reason ", reason)
    end
end

# Per-step gate for the evaluator: feasibility check + accumulation.
mutable struct _TraceAccumulator{L<:Real}
    steploglik::Vector{L}
    feasible::Bool
    first_infeasible::Union{Nothing,Tuple{Int,Any,Symbol}}
end
_TraceAccumulator{L}() where {L<:Real} = _TraceAccumulator{L}(L[], true, nothing)
function (acc::_TraceAccumulator)(sim::SimulationFSM, step_idx, what, when)
    reason = if !haskey(sim.enabled_events, what)
        :not_enabled
    elseif !(when > sim.when)
        :time_order
    else
        nothing
    end
    if reason !== nothing
        acc.feasible = false
        acc.first_infeasible = (step_idx, what, reason)
        return true                       # stop the loop; do NOT fire
    end
    # The accumulator runs BEFORE fire! advances the clocks, so ctx.time (which
    # the context supplies as t0 internally) is the previous event time.
    push!(acc.steploglik, steploglikelihood(sim.sampler, when, what))
    return false
end

"""
    trace_likelihood(sim::SimulationFSM, initializer, trace) -> TraceEvaluation

Evaluate a recorded trace against a model: initialize `sim`, then walk the
trace, accumulating each step's log-likelihood and firing the step's event, and
return a [`TraceEvaluation`](@ref). The `trace` is an `AbstractVector` of
`(when::Float64, clock_key::Tuple)` pairs, as recorded by an observer via
`clock_key(event)`. The `initializer` is either an initialization function
`(physical, when, rng) -> nothing` or a `SimEvent` whose `fire!` initializes
the state; a third method accepts `(sim, init_evt::SimEvent, init_func::Function, trace)`.

Infeasible traces do not throw. If a step names an event that is not enabled,
or a time that is not strictly after the previous event's time, evaluation
stops and the result has `feasible == false`, `loglikelihood == -Inf`, and
`first_infeasible` identifying the step. A trace entry with a non-finite time
ends evaluation early without marking the trace infeasible.

`sim` must be constructed with `step_likelihood=true` so its `SamplingContext`
records the enabled-clock likelihood. To make the result differentiable with
`ForwardDiff`, also pass `likelihood_eltype=eltype(θ)`:

```julia
sim = SimulationFSM(physical, events; step_likelihood=true, likelihood_eltype=eltype(θ))
```
"""
function trace_likelihood(
    sim::SimulationFSM, init_evt::SimEvent, init_func::Function, trace::AbstractVector
)
    sim.step_likelihood || throw(ArgumentError(
        "trace_likelihood needs a simulation built with step_likelihood=true; " *
        "for gradients also pass likelihood_eltype=eltype(θ). " *
        "Example: SimulationFSM(physical, events; step_likelihood=true)"))
    Base.require_one_based_indexing(trace)
    L = sim.likelihood_eltype
    acc = _TraceAccumulator{L}()
    initialize!(init_evt, init_func, sim)
    _step_loop!(sim, _TraceNext(trace), acc)
    loglikelihood = acc.feasible ? sum(acc.steploglik; init=zero(L)) : convert(L, -Inf)
    return TraceEvaluation(
        loglikelihood, acc.feasible, length(acc.steploglik), acc.first_infeasible,
        acc.steploglik,
    )
end

function trace_likelihood(sim::SimulationFSM, initializer::SimEvent, trace)
    init_func = (physical, when, rng) -> fire!(initializer, physical, when, rng)
    trace_likelihood(sim, initializer, init_func, trace)
end

function trace_likelihood(sim::SimulationFSM, initializer::Function, trace)
    trace_likelihood(sim, InitializeEvent(), initializer, trace)
end
