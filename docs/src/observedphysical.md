# Declaring the Simulation State

## Why the state is special

ChronoSim needs to know which parts of the state each event reads and writes,
because that knowledge is what drives the whole simulation: it decides which
events get re-checked and which new events get proposed after every firing.
The `ChronoSim.ObservedState` module therefore provides containers and macros
that give every piece of your state a unique *address* and report every read
and write of it.

An address is a tuple that names the path from the top of the state down to
one value. A few examples show the pattern.

- Reading `state.board[3, 2].food` records the address `(:board, (3, 2), :food)`.
- Writing `state.actors[17].speed` records the address `(:actors, 17, :speed)`.
- Reading `state.car_floor` records the address `(:car_floor,)`.

You do not construct or handle addresses yourself when writing a model. They
appear in diagnostics, and they are the vocabulary that generators use, so it
helps to know what they look like.

## Declaring element types with `@keyedby`

The mutable structs that live inside observed containers are declared with
`@keyedby`. The macro takes three things: the name of the type, the type of
the index that will locate it inside its container, and the fields.

```julia
using ChronoSim.ObservedState

@keyedby Piece Int64 begin
    speed::Float64
    kind::String
end
```

A `Piece` will live in a vector or an `Int`-keyed dictionary, so its index
type is `Int64`. An element of a two-dimensional array is indexed by a tuple
of two integers, so it is declared like this:

```julia
@keyedby Square NTuple{2,Int64} begin
    grass::Float64
    food::Float64
end
```

The struct that `@keyedby` creates is mutable, and it carries a hidden field
that records where it currently sits inside its owning container. That hidden
field is how a write like `piece.speed = 2.0` can report its full address
even though the assignment never mentions the container.

## Declaring the state with `@observedphysical`

The top-level state is declared with `@observedphysical`, which creates a
mutable struct plus the machinery that collects read and write reports.

```julia
@observedphysical Board begin
    board::ObservedArray{Square,2,Member}
    actors::ObservedDict{Int64,Piece,Member}
    actors_max::Int64
    params::Param{Dict{Symbol,Float64}}
end
```

Each field is tracked according to its type, and there are four cases worth
understanding.

1. **Observed containers** — `ObservedArray` (with `ObservedVector` and
   `ObservedMatrix` as aliases), `ObservedDict`, and `ObservedSet` — track
   their contents at the level of individual elements and fields. The final
   `Member` type parameter says the container is addressed as a named field
   of the state; you write it as shown and do not need to think about it
   further.
2. **Plain scalar fields** such as `actors_max::Int64` are tracked at the
   granularity of the whole field. Reading or writing `state.actors_max`
   records the address `(:actors_max,)`. This is the right choice for global
   quantities such as a count, a mode flag, or the position of a single
   shared resource.
3. **`Param`-wrapped fields** are deliberately invisible to tracking. Wrap a
   field in `Param{T}` when it is configuration that never changes during a
   run, such as a table of rate constants or a precomputed distance matrix.
   Reads of it cost nothing and create no dependencies, and the field is
   accessed transparently, so `state.params[:gravity]` works without
   unwrapping.
4. **Plain container fields** (an ordinary `Dict` or `Vector` that is neither
   observed nor `Param`-wrapped) are a trap and should be avoided: assigning
   the whole field is tracked, but mutating its interior is not, so an event
   whose precondition depends on the interior will not be re-checked when it
   changes. If the contents change during the simulation, use an observed
   container; if they never change, wrap the field in `Param`.

## Choosing between an array and a dictionary

The two main containers correspond to two ways of thinking about identity,
and the distinction matters because addresses must keep meaning the same
thing over the life of a run.

Use an **`ObservedArray`** when the population is fixed and densely indexed:
grid cells, a fleet of exactly `n` machines, the floors of a building. The
integer position *is* the identity of the element. For this reason observed
arrays have a fixed extent: operations that would change their length, such
as `push!`, `pop!`, or `resize!`, throw a `FixedExtentError`. Allocate the
final size up front and fill it by assignment.

Use an **`ObservedDict`** when entities are created or destroyed during the
run, or when they carry natural identifiers: people arriving and leaving,
strains of a pathogen appearing by mutation, calls keyed by the floor that
placed them. The key is the identity, insertion and deletion are ordinary
`setindex!` and `delete!`, and each affects exactly one address.

Use an **`ObservedSet`** when the state you care about is membership itself
and events should react to any change of the set. A set's elements have no
individual addresses; every operation reads or writes the set as a whole.

## Initializing the state

Construction usually takes a short loop, because each element must be its own
instance.

```julia
board_data = ObservedArray{Square,Member}(undef, 3, 3)
for i in 1:3, j in 1:3
    board_data[i, j] = Square(0.5, 1.0)
end

actor_data = ObservedDict{Int64,Piece,Member}()
actor_data[1] = Piece(2.5, "walker")
actor_data[2] = Piece(3.0, "runner")

params = Dict(:gravity => 9.8, :friction => 0.1)
board_state = Board(board_data, actor_data, 10, params)
```

The constructor that `@observedphysical` generates takes the fields in
declaration order. A `Param` field accepts the unwrapped value and wraps it
for you.

After construction, ordinary Julia syntax does the right thing. The
assignment below looks like any other assignment, and it is also recorded as
a write to `(:actors, 1, :speed)`, which is what lets the framework react
to it.

```julia
board_state.actors[1].speed = 2.0
```

## The contract, in brief

The containers promise three things, and the rest of the framework is built
on them. First, whenever the state changes, the set of recorded write
addresses covers everything that actually changed, so no event can miss a
change it depends on. Second, an element's recorded address always names the
place it currently occupies, so reports are never misfiled. Third, addresses
are stable, deterministic names: the same access produces the same address in
every run, and two runs with the same seed produce the same trajectory. These
three promises are checked mechanically by a fuzz tester in the test suite,
and the precise statement of the contract, including what "covers" means and
which operations are deliberately coarse, is in the
[State Contract](state_contract.md) page of the Development section.
