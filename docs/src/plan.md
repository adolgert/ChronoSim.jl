# Plan

## Current Capabilities

```@raw html
<iframe src="assets/d3_event_diagram.html" style="width: 100%; height: 500px; border: none;"></iframe>
```

### Features
 
1. Rule-based events
1. Sampling methods
1. Dirac delta function times (for ODEs)
1. Deterministic once random seed is set.
1. Re-enabling of events
1. Rules that depend on events instead of just states.
   * Macro and struct for event(key)
1. Observers on events
1. Observers of state changes
1. Immediate events

### Examples

 1. Elevators with TLA+.

### Known bugs

 1. Observe macro needs hygiene to evaluate methods in defining context.


## Future Capabilities

### Features

1. Importance sampling
1. Pregeneration of all rule-based events.
1. Transactional firing (for estimation of derivatives)
1. HMC sampling from trajectories


### Example Simulations

 1. Movement and infection.
 1. Move, infect, age, birth.
 1. Policy-driven movement.
 1. Queuing model.
 1. Chemical equations.
 1. Drone search pattern with geometry.
 1. HMC for house-to-house infestation.
 1. Job shop problem.
 1. Cars driving on a map.

### Example Uses of Simulations

 1. Hook into standard Julia analysis tools.
 1. Sampling rare events.
 1. Parameter fitting to world data.
 1. Optimization of parameters to minimize a goal function.
 1. HMC on trajectories to find a most likely event stream.
 1. POMDP

 ### Performance Questions

 1. How stable can I make the type system in the running simulation? It uses Events in places and tuples in others.
 1. The TrackedEntry needs to be timed and gamed.
 1. Could the TrackedEntry be an N-dimensional array? Could each entry be an array? A dictionary?
 1. Can the main simulation look over the keys to determine types before it instantiates?
 1. The depnet is absolutely wrong for the current main loop. It might be closer to right for another mainloop. Should try various implementations.
 1. Measure performance with profiling. Look for the memory leaks.


## Improvements to the Framework User Interface

This section is from conversations with AI about the spectrum of
ways to improve the user interface. There were some good ideas in there
so they are recorded here.


### generator functions use do-function syntax so make it easier.

Create a macro for generator functions that looks like you call
`generate(event)` but really calls a do-function callback underneath.

### Simplify enabling/reenabling

Ask the simulation to define the distribution and when but not the
sampler, rng, or clock_key.

### Explicitly register functions
  In framework.jl - automatic method generation
  function register_event(event_type::Type{<:SimEvent}, spec::EventSpec)
      # Generate precondition, generators, enable, fire! automatically
      # Based on declarative specification
  end

### Macro to say what generators trigger on
  Framework provides path builder
  @watches actors[*].state  # Instead of [:actors, ℤ, :state]
  @watches board[*].occupant

### Put common event patterns into template structs
  Framework could provide base types:
  - ActorEvent{T} - for single-actor events
  - InteractionEvent{T} - for multi-actor events
  - ScheduledEvent{T} - for time-based events
  - StateTransitionEvent{T} - for state machine transitions

or make it a function:
  Framework provides factory for common patterns
  create_state_transition_event(
      :Break,
      from_state = :working,
      to_state = :broken,
      rate_field = :fail_dist,
      age_tracking = true
  )

### Put common enabling patterns into template structs

  Common patterns built into framework
  abstract type RateModel end
  struct ConstantRate <: RateModel; dist; end
  struct ActorRate <: RateModel; field::Symbol; end
  struct TimeBasedRate <: RateModel; calc::Function; end

### Help build the simulation itself

  In framework.jl
  @simulation MySimulation begin
      state_type = IndividualState
      events = [StartDay, EndDay, Break, Repair]
      sampler = CombinedNextReaction

      initialize = function(physical, rng)
          # initialization code
      end

      stop_when = (physical, step, event, when) -> when > days
  end

### Make tools with which to make simulation DSLs

```
  # Framework should export these primitives
  export create_generator, register_precondition, add_rate_function
  export EventSpecification, GeneratorSpec, RateSpec

  # So users can build their own DSLs:
  macro my_reliability_event(name, spec)
      quote
          struct $(esc(name)) <: ActorEvent{IndividualState}
              actor_idx::Int
          end

          # Use framework primitives
          register_precondition($(esc(name)), $(spec.precondition))
          add_rate_function($(esc(name)), $(spec.rate))
      end
  end
```

### Use traits more than inheritance

Maybe both traits and hooks, where a user registers a function to call for
a particular event.

```
  # Framework defines traits
  abstract type EventTrait end
  struct HasActor <: EventTrait end
  struct HasSchedule <: EventTrait end
  struct HasInteraction <: EventTrait end

  # Users can mix traits freely
  event_traits(::Type{<:SimEvent}) = ()
  event_traits(::Type{Break}) = (HasActor(), HasSchedule())

  # Framework dispatches on traits
  function generate_precondition(evt::Type{T}) where T
      traits = event_traits(T)
      # Compose behavior from traits
  end
```

This could also help the functions on events.
```
  # Instead of storing functions, use traits
  abstract type PreconditionTrait end
  struct StateCheck{S} <: PreconditionTrait
      required_state::S
  end

  struct EventConfig{P <: PreconditionTrait}
      precondition_trait::P
  end

  # Fast dispatch
  @inline function check_precondition(evt::ActorEvent, physical, ::StateCheck{S}) where S
      physical.actors[evt.actor_idx].state == S
  end
```

### Make Syntax Trees Accessible

```
  # If framework uses macros, expose the AST
  macro framework_helper(expr)
      ast = parse_event_ast(expr)
      # Let users transform it
      transformed = apply_user_transforms(ast)
      return generate_code(transformed)
  end

  # Users can register transforms
  register_ast_transform!(my_reliability_transform)
```

### Macro advice

Macro Design Best Practices

AVOID These Patterns:

```
  # 1. Rigid syntax requirements
  @framework_event name::Type = value  # Forces specific syntax

  # 2. Closed evaluation contexts
  @framework_event Break begin
      eval(:(struct Break ... end))  # Evaluates in framework module
  end

  # 3. Monolithic macros
  @define_entire_event Break working broken fail_dist ...
```

PREFER These Patterns:

```
  # 1. Composable macro fragments
  @event_struct Break actor_idx::Int
  @event_precondition Break (evt, phys) -> phys.actors[evt.actor_idx].state == working
  @event_rate Break (evt, phys) -> phys.params[evt.actor_idx].fail_dist

  # 2. Pass-through to user context
  macro framework_helper(name, user_expr)
      quote
          # Evaluate in caller's context
          local user_result = $(esc(user_expr))
          framework_process($(QuoteNode(name)), user_result)
      end
  end

  # 3. Metadata-based approach
  @event_metadata Break begin
      traits = [:actor_based, :state_transition]
      watches = [:actors]
      # Users can add custom metadata
  end
```

## Sample Implementation

### Of a framework that enables user DSLs

```
  # Framework provides:
    module ChronoSim

  # Low-level registration API
  function register_event_type(T::Type, config::EventConfig)
      # Store in global registry
  end

  # Composable specifications
  # This should use parametric types
  struct EventConfig{P,G,E,F}
      precondition::Union{Function, Nothing}
      generators::Vector{GeneratorSpec}
      enable::Union{Function, Nothing}
      fire::Union{Function, Nothing}
      metadata::Dict{Symbol, Any}
  end

  # Give the parametric event config a solid constructor.
  function actor_event_behavior(;
      required_state::Symbol,
      rate_field::Symbol,
      fire_action::Function
  )
      EventBehavior(
          # Specialized, inlinable functions
          (evt, physical) -> getfield(physical.actors[evt.actor_idx], :state) == required_state,
          (evt, sampler, physical, when, rng) -> enable!(
              sampler,
              clock_key(evt),
              getfield(getfield(physical.params[evt.actor_idx], rate_field)),
              when, when, rng
          ),
          fire_action,
          default_actor_generators()
      )
  end

  end # module

  # User's DSL:
  module ReliabilityDSL
    using ChronoSim

  macro reliability_event(name, from, to, rate_field)
      quote
          struct $(esc(name)) <: SimEvent
              actor_idx::Int
          end

          config = actor_event_config(
              precondition_state = $(esc(from)),
              rate_distribution = evt -> evt.physical.params[evt.actor_idx].$rate_field,
              fire_action = (evt, phys, when) -> begin
                  phys.actors[evt.actor_idx].state = $(esc(to))
                  # Custom reliability logic here
              end
          )

          register_event_type($(esc(name)), config)
      end
  end

  # Clean syntax for users
  @reliability_event Break working broken fail_dist
  @reliability_event Repair broken ready repair_dist

  end # module
```

### Of an ActorEvent{T}

```
  abstract type ActorEvent{T} <: SimEvent end

  # Default implementation that concrete types can override
  actor_index(evt::ActorEvent) = evt.actor_idx
  actor_collection(::Type{<:ActorEvent{T}}) where T = :actors
  actor_state_field(::Type{<:ActorEvent{T}}) where T = :state

  # Generic precondition - can be overridden
  function precondition(evt::E, physical) where E <: ActorEvent
      actor_idx = actor_index(evt)
      checkbounds(Bool, getfield(physical, actor_collection(E)), actor_idx) || return false

      # Allow custom precondition logic
      actor_precondition(evt, physical)
  end

  # Subtype must implement this
  actor_precondition(evt::ActorEvent, physical) =
      error("Must implement actor_precondition for $(typeof(evt))")

  # Generic generators for any ActorEvent
  function generators(::Type{E}) where E <: ActorEvent{T} where T
      collection = actor_collection(E)
      state_field = actor_state_field(E)

      return [
          EventGenerator(
              ToPlace,
              [collection, ℤ, state_field],
              function (f::Function, physical, actor)
                  evt = try_create_event(E, actor, physical)
                  !isnothing(evt) && f(evt)
              end
          )
      ]
  end

  # Helper to create event if valid
  try_create_event(::Type{E}, actor_idx, physical) where E <: ActorEvent = E(actor_idx)

  # Generic enable with rate lookup
  function enable(evt::E, sampler, physical, when, rng) where E <: ActorEvent
      rate_dist = get_rate_distribution(evt, physical)
      enable_time_args = get_enable_times(evt, physical, when)
      enable!(sampler, clock_key(evt), rate_dist, enable_time_args..., rng)
  end

  # Default reenable delegates to enable
  function reenable(evt::E, sampler, physical, first_enabled, curtime, rng) where E <: ActorEvent
      rate_dist = get_rate_distribution(evt, physical)
      reenable_time_args = get_reenable_times(evt, physical, first_enabled, curtime)
      enable!(sampler, clock_key(evt), rate_dist, reenable_time_args..., rng)
  end

  # Subtype must implement rate lookup
  get_rate_distribution(evt::ActorEvent, physical) =
      error("Must implement get_rate_distribution for $(typeof(evt))")

  # Default time arguments
  get_enable_times(evt::ActorEvent, physical, when) = (when, when)
  get_reenable_times(evt::ActorEvent, physical, first_enabled, curtime) = (first_enabled, curtime)
```
And what it does to the simulation code:
```
 struct Break <: ActorEvent{IndividualState}
      actor_idx::Int
  end

  # Only need to specify unique behavior
  actor_precondition(evt::Break, physical) =
      physical.actors[evt.actor_idx].state == working

  get_rate_distribution(evt::Break, physical) =
      physical.params[evt.actor_idx].fail_dist

  # Custom time calculation for non-memoryless distributions
  get_enable_times(evt::Break, physical, when) =
      (when - physical.actors[evt.actor_idx].work_age, when)

  function fire!(evt::Break, physical, when, rng)
      physical.actors[evt.actor_idx].state = broken
      started_work = physical.actors[evt.actor_idx].started_working_time
      physical.actors[evt.actor_idx].work_age += when - started_work
  end

  # EndDay is even simpler
  struct EndDay <: ActorEvent{IndividualState}
      actor_idx::Int
  end

  actor_precondition(evt::EndDay, physical) =
      physical.actors[evt.actor_idx].state == working

  get_rate_distribution(evt::EndDay, physical) =
      physical.params[evt.actor_idx].done_dist

  function fire!(evt::EndDay, physical, when, rng)
      physical.actors[evt.actor_idx].state = ready
      started_work = physical.actors[evt.actor_idx].started_working_time
      physical.actors[evt.actor_idx].work_age += when - started_work
  end

  # Repair
  struct Repair <: ActorEvent{IndividualState}
      actor_idx::Int
  end

  actor_precondition(evt::Repair, physical) =
      physical.actors[evt.actor_idx].state == broken

  get_rate_distribution(evt::Repair, physical) =
      physical.params[evt.actor_idx].repair_dist

  function fire!(evt::Repair, physical, when, rng)
      physical.actors[evt.actor_idx].state = ready
      physical.actors[evt.actor_idx].work_age = 0.0
  end
```

### Event generation in particular

This is a macro language to generate events. This one would create a function
called `generators(::Type{MoveTransition})` that contains a list of EventGenerator
objects.
```
@conditionsfor MoveTransition begin
    @reactto changed(agent[i].loc) begin physical
        agent_loc = physical.agent[i].loc
        for direction in valid_directions(physical.geom, agent_loc)
            generate(MoveTransition(agent_who, direction))
        end
    end
    @reactto fired(InfectTransition(sick, healthy)) begin physical
        for neigh in neighborsof(physical, healthy)
            for nextneigh in neighborsof(physical, neigh)
            generate(InfectTransition(neigh, nextneigh))
        end
    end
end
```
The `@reactto changed(agent[i].loc)` creates a generator that reacts `ToPlace`
where the search string is `[:agent, ℤ, :loc]`. Then it makes a function closure
with the arguments `(generate::Function, physical, i)` where the value passed
to `i` is the `ℤ` match.

The `@reactto fired(InfectTransition(sick, healthy))` creates a generator that
reacts `ToEvent` where the search string is `[:InfectTransition]` and the function
closure has the arguments `(generate::Function, physical, sick, healthy)`.
The values for sick and healthy are taken from the matched event.

