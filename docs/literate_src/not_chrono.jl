# # Starting from Simple Simulation
#
# ## Hand-made Can Be Excellent
#
# Let's make a cute little simulation of wandering, spawing agents **without
# using ChronoSim.jl.** This is
# less thorough than the [spatial rock-paper-scissors](https://juliadynamics.github.io/Agents.jl/stable/examples/event_rock_paper_scissors/)
# in Agents.jl.
# Start with a state that will be a vector of Agents.
using DataStructures, Distributions, Random
rng = Xoshiro(92347223)
@enum Matter Rock Paper Scissors
mutable struct Agent
    location::Vector{Int64}
    kind::Matter
end;
#
# We need a queue of events that happen next.
#
μ, γ = (1.0, 3.0)  # Rates for movement and spawning.
queue = BinaryMinHeap{Tuple{Float64,Tuple}}()
schedule(queue, distribution, key) = push!(queue, (rand(rng, distribution), key));
#
# The heart of the simulation will process the event to fire and then add future
# events to the queue.
#
DIRECTIONS = [[-1, 0], [1, 0], [0, 1], [0, -1]]
event_dict = Dict(
    :move => function (state, when, who, direction)
        state[who].location += DIRECTIONS[direction]
        schedule(queue, Exponential(μ), (:move, who, rand(rng, 1:length(DIRECTIONS))))
    end,
    :spawn => function (state, when, who)
        kind = state[who].kind
        push!(state, Agent(state[who].location, kind))
        child = length(state)
        schedule(queue, Exponential(μ), (:move, child, rand(rng, 1:length(DIRECTIONS))))
        schedule(queue, Exponential(γ), (:spawn, child))
        schedule(queue, Exponential(γ), (:spawn, who))
    end,
);
#
# The main loop of the simulation ends up being initialization and a small event loop.
#
function run_until(event_cnt)
    state = Vector{Agent}(undef, 10)
    for aidx in eachindex(state)
        state[aidx] = Agent([0, 0], rand(rng, instances(Matter)))
        schedule(queue, Exponential(μ), (:move, aidx, rand(rng, 1:length(DIRECTIONS))))
        schedule(queue, Exponential(γ), (:spawn, aidx))
    end
    now = 0.0
    for event_idx in 1:event_cnt
        (when, (event_type, args...)) = pop!(queue)
        now = when
        @show (when, event_type, args)
        event_dict[event_type](state, now, args...)
    end
end
run_until(10)
#
# This works great because it's very clear how events flow, which makes debugging
# easy. Why make life any more complicated?
#
# ## Why change
#
# There is a moment in the event logic where it decides what events could happen
# next. Let's say multiple events could queue up the same kind of follow-up
# event. Shouldn't the follow-up event decide when it could happen instead of the
# events that queue it? And if an event is no longer possible, shouldn't there be
# a way to cancel it?
#
# !!! tip "Idea"
#
#     Let's put the precondition for an event to fire with the event itself.
#
# What if we want to extend the simulation with more events? You need to go in
# and change what events are queued after one has fired.
#
# !!! tip "Idea"
#
#     Let's use an Observer pattern to let an event subscribe to previous events or to state changes.
#
# There is another complication that is sometimes overlooked for continuous-time
# simulation. When the state of a simulation changes, an event that was already
# queued might need to happen sooner or it might be pushed back in time. This is
# a re-enabling of the event where it can re-evaluate its probability to fire at
# future times.
#
# !!! tip "Idea"
#
#     Let's explicitly calculate a re-enabling time when appropriate.
#
