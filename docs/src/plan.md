# Plan

This simulation framework asks a question: How can we simulate with time-varying
hazards and get full expressiveness and statistical capability?

### Problems We Want to Solve

 - GSPN requires building a large graph before simulating, and creating versions of a simulation requires creating versions of those graphs. It is painstaking.
 - GSMP historically use Exponential distributions or have limited ideas of what a hazard rate can be and a limited definition of state. But this IS a GSMP by its statistical definition.
 - Chemical simulation with time-varying hazards does happen. It's just restricted to particular forms for the hazard rates and a limited definition of state (counts of chemicals). It's not wrong, but it doesn't do arbitrary, real-valued state.

### This framework has an opinion

 1. **Which events are enabled and disabled will be mediated by changes to a state.**
    This is in contrast to a simulation where a firing function, within that function, will
    enable and disable events.

 2. **Events will be created dynamically based on the state.** There is a way to avoid construction
    of the bipartite graph of the Petri net.

Both of these points exist to make it easier to **compose simulations.**
They also enable us to use a simulation as a statistical evaluator of likelihoods of trajectories.
We will, for instance, be able to modify a simulation by specifying a list of events to
include in the simulation, substituting one event for another.

### This framework asks questions

 1. Is there a simulation component that will update state and clocks correctly
    in a way that helps write simulations but doesn't limit the kinds of uses? I mean
    is there some set of features we want in the state update that supports different applications
    like chemical simulation, disease simulation, reliability, etc?

 1. How can we define simulation state in a way that is a) observable by the framework
    and b) can be transactional so we can roll back changes to the state?

 1. What are design patterns for dynamic generation of events from the state?

 1. How can we make a framework that can be the base for a problem-specific DSL made with macros?

## Why use this?

 1. Curiosity to see how well/badly it works.
 1. Get ideas to do something different.
 1. You have a sincerely difficult simulation problem, and this is the best expression of it.

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
 1. Reliability with a set of trucks.
 1. SIR with strain mutation and individual movement models.
 1. Movement through a 2D domain for particle filtering.

### Known bugs

 1. Observe macro needs hygiene to evaluate methods in defining context.


## Future Capabilities

### Features

1. Clarify in docs that this is a model + propagator, not a framework.
1. Importance sampling
1. `fire!()` uses probabilistic programming to get complete likelihood.
1. The user can supply a list of all events in order to build a complete depnet before simulating.
1. Pregeneration of all rule-based events.
1. Transactional firing (for estimation of derivatives)
1. MCMC sampling from trajectories
1. Simulate backwards in time.


### Example Simulations

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

## Reframing as propagator

Three concepts around which to structure:

  1. Event Propagation: Given current state and enabled events, calculate the probability distribution over next events
  2. Likelihood Calculation: Compute the exact probability of observed event sequences (for model fitting)
  3. Compositional Integration: Use as a component within larger statistical or numerical analyses

## Main Pain Points

The central idea is that a Model is a set of events mediated by their interaction with state. We insist on this central idea by forbidding a user from creating events in a firing function. It must always be the case that, given a simulation state, it is possible to apply events to it and figure out which are or aren't enabled. This is what makes the system a weak Markov system. It's a limitation that we should be able to turn into a strength. I'm not sure how though.

 1. There is a tenuous connection from an updated state to the generators that see that state and connect it to events.
    - One debugging move: Always execute every enabling invariant at every step. If one is a yes but its generator didn't fire, then that's a problem.

 2. There are at least five separate definitions to create an Event. That's a lot to do. Is it easy to understand or can we reduce complexity?

 3. I know from experience that debugging these simulations is very difficult. Is there some idea I'm missing that would elucidate why some event failed to fire or why an event fires when you don't think it should?
    - `A` fired, so why wasn't `B` enabled? This is hard to track because `A` affects state, and maybe `B` doesn't see that state.
    - We could have the address of everything written and read. Relate it to what's in the network, like a local graph.

## Improvements to the Framework User Interface

This section is from conversations with AI about the spectrum of
ways to improve the user interface. There were some good ideas in there
so they are recorded here.

### The Five parts

| Component          | Role                                                                                                  |
|--------------------|-------------------------------------------------------------------------------------------------------|
| Events             | The SimEvent interface (precondition, enable, reenable, fire!, isimmediate)                           |
| Generators         | The reactive system that creates events from state changes or other events (@reactto, @conditionsfor) |
| Observable State   | Containers that track reads/writes (ObservedArray, ObservedDict, etc.)                                |
| Dependency Network | Bidirectional graph: which events depend on which state "places"                                      |
| SimulationFSM      | The orchestrator that coordinates all of the above with CompetingClocks                               |

  1. Where does complexity live today? The plan.md lists many UX improvements (macros, traits, templates). Is the current interface genuinely
  difficult, or is it just verbose? There's a difference between "hard to understand" and "tedious to write."
  2. The Observer pattern: You have observers on state and observers on events (the observer callback in SimulationFSM). How do users think about
  these? Are they fundamentally different, or could they unify?
  3. Likelihood calculation: The trace_likelihood and steploglikelihood integration suggests you're targeting inference/estimation workloads. Is that
  a primary use case or secondary?

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


###   Idea 3: The Command-Handler Pattern (The "Made Up" Idea)

What if we get rid of enable and rate functions as top-level concepts for the user and borrow from
patterns like CQRS/Event Sourcing?

* The Concept: The simulation loop is driven by Commands.
    1. State is your physical state.
    2. A Command is a data struct representing an intent to cause an event (e.g., TryToBreak(actor_idx)). Users can
        dispatch commands at any time.
    3. A Handler is a function handle(command, state). It looks at the command and the current state and returns
        zero or more potential (Event, Distribution) tuples. For TryToBreak(1), the handler checks if actor 1 is
        working and, if so, returns (BreakOccurred(1), fail_dist). This single function effectively combines the
        "generator", "precondition", and "rate" logic.
    4. An Event is a data struct representing something that happened (e.g., BreakOccurred(actor_idx)).
    5. The `fire!` function is replaced by a pure "reducer" function: apply(event, state) -> new_state.

    The main loop would look like:
    1. Collect all possible Commands that could be issued in the current state.
    2. Run them through their Handlers to get a list of possible (Event, Distribution) pairs.
    3. Pass this list to CompetingClocks.jl to sample the next Event.
    4. apply the chosen event to the state.
    5. Repeat.

* How it Simplifies:
    * Conceptual Clarity: The flow is very clear: you issue a Command, a Handler translates it into a potential
        Event, the sampler picks one, and an apply function enacts it. The roles are extremely well-defined.
    * It *almost* gets rid of event keys: The sampler would work with Event structs directly. The clock_key could be
        generated implicitly from the event's type and data. You wouldn't need a separate "key" struct.
    * It combines Generator, Enable, and Rate: The Handler function serves all three purposes in one go.

* This takes the five parts of each event and spreads them across the simulation. It looks
  more like a traditional simulation. In that case, how is this simulation style, splitting the
  event enabling from the state, so different from simulation where, during the handling of a
  command, new events are created? What is the intrinsic different, and if there is an advantage
  to splitting events and state, how do we realize that advantage while retaining the narrative
  structure of traditional simulation styles? Or how do we realize the advantages of avoiding
  that narrative structure? Where is the payoff?

This is a more functional approach that radically simplifies the user's conceptual model, even if it adds a few new
concepts (Command, Handler).

The payoff is that this purity and separation are precisely what unlocks the advanced capabilities you want and makes
your "propagator" vision a reality.

1. The Event Log Becomes a First-Class Citizen: Because the apply function is pure (state, event) -> new_state, the
    entire simulation history can be represented as new_state = apply(event_n, ... apply(event_1, apply(event_0,
    initial_state))). The sequence of events [event_0, event_1, ..., event_n] is a complete, tangible, and replayable
    log of what happened. This isn't just a printout; it's a data structure you can analyze.

2. Likelihood Calculation Becomes Trivial: With the event log as data, calculating the likelihood of that specific
    trajectory is straightforward. At each step k, you know exactly which possibilities the handle function presented
    to the sampler and which event_k was chosen. The total likelihood is the product of those individual
    probabilities.

3. Time-Travel, Counterfactuals, and Debugging: This is the killer feature.
    * Want to simulate backwards? You have the whole event history.
    * Want to know "what if"? Go back to state_k, inspect the possibilities generated by the handlers, and manually
        run the propagator with a different event choice. You can fork reality at any point.
    * Debugging is transformed. A bug is no longer a mysterious state corruption. It's an apply function that
        returned the wrong new_state for a given (event, old_state). You can test your apply reducers like any other
        pure function, completely isolated from the complexity of the simulation loop.

4. Enforced Separation of Concerns: Your commitment to separating the model from the sampler is now enforced by the
    function signatures. The model code (handlers and reducers) literally cannot access the sampler. This makes the
    system architecture incredibly clean and robust.

### It looks like the AI caught on to my plan:

 A Possible Reframing

  What if the mental model were:

  User defines: ModelSpec
    ├── State type (plain Julia struct, no ObservedArray needed)
    ├── Event types
    └── Event interface methods (fire!, enable, precondition)

  ChronoSim provides: Execution strategies
    ├── ForwardSimulation (adds generators, ObservedState, DependencyNetwork)
    ├── LikelihoodReplay (uses core model only)
    └── GenDistribution / TuringModel wrappers

### Hooks!

ChronoSim.jl runs simulations forward but doesn't have hooks for:
  - Pausing at decision points
  - Branching into multiple rollouts
  - Comparing outcomes and selecting actions

And we really need to make clear this isn't just about forward simulation.
