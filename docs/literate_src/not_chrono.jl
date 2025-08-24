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
WINNER = Dict(
    (Rock, Rock) => 2,
    (Paper, Paper) => 2,
    (Scissors, Scissors) => 2,
    (Rock, Paper) => 2,
    (Rock, Scissors) => 1,
    (Paper, Rock) => 1,
    (Paper, Scissors) => 2,
    (Scissors, Rock) => 2,
    (Scissors, Paper) => 1,
)
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
        newloc = state.agent[who].location + DIRECTIONS[direction]
        if checkbounds(Bool, state.locations[newloc])
            if state.locations[newloc] == 0
                state.locations[newloc] = who
                state.locations[state.agent[who].location] = 0
            else
                opponent = state.locations[newloc]
                if WINNER[(state.agent[who].kind, state.agent[opponent].kind)] == 1
                    state.locations[newloc] = who
                    state.locations[state.agent[who].location] = 0
                    state.agent[opponent].location = [0, 0]
                end
            end
        end
        schedule(queue, Exponential(μ), (:move, who, rand(rng, 1:length(DIRECTIONS))))
    end,
    :spawn => function (state, when, who)
        kind = state.agent[who].kind
        push!(state.agent, Agent(state.agent[who].location, kind))
        child = length(state.agent)
        schedule(queue, Exponential(μ), (:move, child, rand(rng, 1:length(DIRECTIONS))))
        schedule(queue, Exponential(γ), (:spawn, child))
        schedule(queue, Exponential(γ), (:spawn, who))
    end,
);
#
# The main loop of the simulation ends up being initialization and a small event loop.
#
mutable struct Board
    agent::Vector{Agent}
    locations::Array{Int,2}
    Board(n) = new(Agent[], zeros(Int, n, n))
end
function run_until(event_cnt)
    N = 10
    state = Board(N)
    for aidx in 1:N
        loc_found = false
        agent_loc = [0, 0]
        while !loc_found
            agent_loc = rand(rng, 1:N, 2)
            loc_found = state.locations[agent_loc[1], agent_loc[2]] == 0
        end
        agent = Agent(agent_loc, rand(rng, instances(Matter)))
        state.locations[agent_loc[1], agent_loc[2]] = aidx
        push!(state.agent, agent)
        schedule(queue, Exponential(μ), (:move, aidx, rand(rng, 1:length(DIRECTIONS))))
        schedule(queue, Exponential(γ), (:spawn, aidx))
    end
    now = 0.0
    for event_idx in 1:event_cnt
        (when, (event_type, args...)) = pop!(queue)
        now = when
        @show (when, event_type, args)
        # Skip events if they refer to an agent that has been knocked off the board.
        if state.agent[args[1]].location[1] != 0
            event_dict[event_type](state, now, args...)
        end
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
# Let's see what ChronoSim does with a similar simulation.
#
using ChronoSim
using ChronoSim.ObservedState
import ChronoSim: precondition, enable, fire!, generators

@keyedby Critter Int64 begin
    location::Vector{Int}
    kind::Matter
end

@keyedby Square Tuple{Int64,Int64} begin
    resident::Int64
end

@observedphysical Land begin
    agent::ObservedVector{Critter}
    board::ObservedArray{Square,2}
end

function Land(board_side::Int, person_cnt::Int)
    for aidx in 1:N
        loc_found = false
        agent_loc = [0, 0]
        while !loc_found
            agent_loc = rand(rng, 1:N, 2)
            loc_found = state.locations[agent_loc[1], agent_loc[2]] == 0
        end
        agent = Agent(agent_loc, rand(rng, instances(Matter)))
        state.locations[agent_loc[1], agent_loc[2]] = aidx
        push!(state.agent, agent)
        schedule(queue, Exponential(μ), (:move, aidx, rand(rng, 1:length(DIRECTIONS))))
        schedule(queue, Exponential(γ), (:spawn, aidx))
    end
end
