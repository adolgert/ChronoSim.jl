using Base: Base

"""
    @observedphysical <typename> <definition block>

This macro defines a physical state that uses the ObservedState
machinery to track changes to that physical state.

For example:
```julia
@keyedby Int Piece begin
    speed::Float64
    kind::String
end

@keyedby NTuple{2,Int64} Square begin
    grass::Float64
    food::Float64
end

@observedphysical Board begin
    board::ObservedArray{Square,2}
    actor::ObservedDict{Int,Piece}
    params::Dict{Symbol,Float64}
    actors_max::Int64
end
```
This macro creates a struct that contains tracking information about
its Observed members, so in the example `params` would not be tracked.
The `Board` type has a parent type `ObservedPhysical` which has the
parent type `ChronoSim.PhysicalState`.

Expanding the macro, we would see:
```julia
mutable struct Board <: ObservedPhysical
    board::ObservedArray{Square,2}
    actor::ObservedDict{Int,Piece}
    params::Dict{Symbol,Float64}
    actors_max::Int64
    obs_modified::Vector{Tuple}
    obs_read::Vector{Tuple}
    Board(board, actor, params, actors_max) = ...
end
```
Here, the list of read and modified state uses the abstract type
`Tuple` because it unifies the way changed state is reported for the
two observed containers: `(:board, (2,2), :grass)` and
`(:actor, 7, :speed)`. The ellipsis above for the constructor is a
constructor that initializes `obs_modified` and `obs_read` to empty
vectors.
"""
