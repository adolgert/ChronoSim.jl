# The `@obsread` and `@obswrite` Macros

## When you would want these

The observed containers described on the previous page do all of the
recording for you, and they are the right choice for almost every model.
Sometimes, though, a simulation needs a data structure that the observed
containers do not offer — a specialized matrix type, a third-party spatial
index, or a plain array that you want to use for performance reasons. In that
situation you can hold the raw structure in the state and take over the
recording duty yourself with two macros: `@obsread` marks a read, and
`@obswrite` marks a write.

## How to use them

Declare the state with `@observedphysical` as usual, so that it has the
machinery for collecting reports, but give it whatever field types you need.

```julia
@observedphysical Fireflies begin
    watersource::Matrix{Float64}
    wind::Float64
    cnt::Int64
end
```

There is no observed container wrapped around `watersource` here, so nothing
records access to its elements automatically. Instead, every place your
events read or write it, you say so explicitly.

```julia
value = @obsread fireflies.watersource[i, j]
@obswrite fireflies.wind = 2.7
```

The first line records a read of the address `(:watersource, (i, j))` and
evaluates to the value. The second line performs the assignment and records a
write of `(:wind,)`.

## The responsibility you are taking on

When you use these macros, the correctness of the simulation rests on your
discipline. Every read that a `precondition` or `enable` function performs on
the raw structure must go through `@obsread`, and every write that a `fire!`
function performs must go through `@obswrite`. A missed write means some
event that depends on that value will not be re-examined when it changes, and
a missed read means an event will not wake up when the value it tested
changes later. Both failures are silent, which is exactly the class of bug
the observed containers exist to prevent, so prefer the containers wherever
they fit.

Be aware of two further limitations. The macros only understand direct field
access and indexing, so a mutating call such as `push!` on a raw vector is
invisible to them. And the `@precondition` derivation machinery analyzes
container access syntax, so preconditions that go through `@obsread` are
better served by hand-written `@conditionsfor` generators.
