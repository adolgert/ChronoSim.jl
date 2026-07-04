# Custom State Types

The physical state is an architectural component you can replace. The
framework interacts with the state through exactly two functions, so if the
observed containers and the `@obsread`/`@obswrite` macros both fail to fit
your problem — for example, because your state lives in an external data
structure or a memory-mapped file — you can supply your own state type by
implementing those two functions for it.

The two functions are `capture_state_changes` and `capture_state_reads`.
Each takes a function `f` to run (a firing function in the first case, a
precondition or enabling function in the second) and your state. Each must
run `f`, collect the addresses that were written or read while it ran, and
return both the result and that collection. Here are the implementations
that the built-in `ObservedPhysical` uses, which serve as the specification.

```julia
function capture_state_changes(f::Function, physical::ObservedPhysical)
    empty!(physical.obs_modified)
    result = f()
    # An ordered set makes the downstream processing deterministic,
    # which keeps whole trajectories reproducible under one seed.
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

Both functions return a named tuple. The first element passes through
whatever `f` returned, and the second is a collection of address tuples. The
addresses you report must satisfy the same contract the built-in containers
satisfy: writes must cover everything that changed, reads must cover
everything the result depended on, and the same access must produce the same
address in every run. The [State Contract](state_contract.md) page in the
Development section states these obligations precisely, and it is the
document to read before building a custom state, because the correctness of
event scheduling rests entirely on them.
