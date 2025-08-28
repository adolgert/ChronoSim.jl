# Simulation State

A simulation changes state over time. This kind of simulation enables and disables events depending on changes to the state, so you have to define a simulation state that can record that it was changed or read.

The three sections below describe two ways to create a state that records its accesses and one way you could define your own custom state.

## Struct of Observed Vectors and Arrays

The `ChronoSim.ObservedState` module supplies macros and containers that make a simulation state that is a mutable struct containing containers of mutable structs.
```julia
using ChronoSim.ObservedState
@keyedby Piece Int begin
    speed::Float64
    kind::String
end

@keyedby Square NTuple{2,Int64} begin
    grass::Float64
    food::Float64
end

@observedphysical Board begin
    board::ObservedArray{Square,2}
    actor::ObservedDict{Int,Piece}
    params::Dict{Symbol,Float64}
    actors_max::Int64
end

board_data = ObservedArray{Square}(undef, 3, 3)
for i in 1:3, j in 1:3
    board_data[i, j] = Square(0.5, 1.0)
end

actor_data = ObservedDict{Int,Piece}()
actor_data[1] = Piece(2.5, "walker")
actor_data[2] = Piece(3.0, "runner")

params = Dict(:gravity => 9.8, :friction => 0.1)
board_state = Board(board_data, actor_data, params, 10)
```

When the simulation changes the speed of a piece, it will look normal:
```julia
board_state.actor[1].speed = 2.0
```
That assignment will be recorded as a modification of `(:actor, 1, :speed)`.

If the simulation changes `params` or `actors_max`, those are not contained in `ObservedArray` or `ObservedDict` so they aren't recorded.

## @Observe Macro

If you want to construct a physical state that uses different containers or data types, you may want to try the `@observe` macro in `ChronoSim.ObservedState`.

Again, create an `@observedphysical` state so that it has the ability to record changes and reads. But here, include any containers you would like.
```julia
@observedphysical Fireflies begin
    watersource::Matrix{Float64}
    wind::Float64
    cnt::Int64
end
```
This time, however, because there are no `ObservedArray` or `ObservedDict` to help record reads or writes to the state, use a macro to notify the state every time a firing function writes or an enabling function reads.
```julia
value = @observe fireflies.watersource[i, j]
@observe fireflies.wind = 2.7
```
The first use of `@observe` will record a read of `(:watersource, (i, j))`. The second use of `@observe` will record a write of `(:wind,)`.

## Custom State

The physical state of a simulation is an architectural component of a simulation. The simulation framework interacts with the physical state in just two ways, so it is fairly simple to define your own version of a physical state that works for this simulation framework.

The two functions a physical state must support are `capture_state_changes` and `capture_state_reads`. Here are the implementations used by `ChronoSim.ObservedPhysical`. The first argument, `f::Function`, is a firing function or an enabling function that modifies state or reads state.
```julia
function capture_state_changes(f::Function, physical::ObservedPhysical)
    empty!(physical.obs_modified)
    result = f()
    # Use ordered set here so that list is deterministic.
    changes = OrderedSet(physical.obs_modified)
    return (; result, changes)
end

function capture_state_reads(f::Function, physical::ObservedPhysical)
    empty!(physical.obs_read)
    result = f()
    reads = OrderedSet(physical.obs_read)
    return (; result, reads)
end
```
