# Custom State

The physical state of a simulation is an architectural component of a simulation. The simulation framework interacts with the physical state in just two ways, so there are two methods required to define your own version of a physical state that works for this simulation framework.

The two methods a physical state must support are `capture_state_changes` and `capture_state_reads`. Here are the implementations used by `ChronoSim.ObservedPhysical`. The first argument, `f::Function`, is a firing function or an enabling function that modifies state or reads state.
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
These functions return named tuples where the first member passes through the
result of calling the function `f()` and the second contains a list of tuples
that represent addresses of parts of the state.
An ordered set is used in order to make simulations deterministic once the random number generator is seeded.
