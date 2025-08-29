
# The @observe Macro

If you want to construct a physical state that uses containers or data types that aren't dictionaries or contiguous vectors, you may want to try the `@observe` macro in `ChronoSim.ObservedState`.

## Guide

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

## Implementation

The `@observe` macro is fairly simple. It detects whether it sees an assigment in order to determine whether it is reading or writing. Then it parses the variables for property access through dots, '.', or through brackets, '[]'. A drawback of this macro is that it doesn't understand `push!` functions, for instance. We might improve this by appealing to `Accessors.jl`.
