# Struct of Observed Vectors and Arrays

## Guide

The `ChronoSim.ObservedState` module supplies macros and containers that make a simulation state that is a mutable struct containing containers of mutable structs. The goal
is to associate every part of the system state with a unique *address.*

 * `state.board[3,2].food` → `(:board, (3, 2), :food)`
 * `state.actor[17].speed` → `(:actor, 17, :speed)`
 * `state.params["theta"]` → `(:params, "theta")`

The macros `@observedphysical` and `@keyedby` work with the custom datatypes
`ObservedArray` and `ObservedDict` to ensure every time you set a property on
the state that the address of that property is recorded.

This is defined in the `ChronoSim.ObservedState` module within ChronoSim.
The `@keyedby` macro takes three arguments:

 1. The name of the type you want to create, here `Piece`.
 1. How that type is indexed within the `ObservedArray` or `ObservedVector`,
    so this will be an Int or tuple of Ints for an `ObservedArray` or whatever
    the key type is for an `ObservedDict`.
 1. The body of the struct. The struct created will be mutable and will store
    hidden fields that contain its index within the owning container.

```julia
using ChronoSim.ObservedState
@keyedby Piece Int begin
    speed::Float64
    kind::String
end
```
Here we show an NTuple for a mutable struct within a 2D array.
```julia
@keyedby Square NTuple{2,Int64} begin
    grass::Float64
    food::Float64
end
```
The `@observedphysical` macro creates a mutable struct that has two hidden
fields, `obs_reads::Set{Tuple}` and `obs_modified::Set{Tuple}`. The struct
can contain any types, but the `ObservedArray` and `ObservedDict` are the
ones that will be tracked.

```julia
@observedphysical Board begin
    board::ObservedArray{Square,2}
    actor::ObservedDict{Int,Piece}
    params::Dict{Symbol,Float64}
    actors_max::Int64
end
```

Initialization of an `ObservedArray` usually requires a for-loop because you
want to make a separate instance of the contained `@keyedby` struct.
```julia
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

When the simulation changes the speed of a piece, it will look normal.
```julia
board_state.actor[1].speed = 2.0
```
That assignment will be recorded as a modification of `(:actor, 1, :speed)`.

If the simulation changes `params` or `actors_max`, those are not contained in `ObservedArray` or `ObservedDict` so they aren't recorded.

## Implementation

The internal implementations of the `@keyedby` struct hook into the `getproperty`
and `setproperty` methods in order to record reads and writes. They then use
a pointer to the containing `ObservedArray` or `ObservedDict` to notify up the
chain that a read or write happened. Similarly, each `ObservedArray` or
`ObservedDict` has a pointer to its container for notification.

This is an area of the implementation that may not be robust because there is
less testing of containers of containers, for instance. It's not clear how
this will hold up to creative usage.
