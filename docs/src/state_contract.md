# The State-Addressing Contract

ChronoSim discovers which events to re-examine by observing reads and writes
of the physical state. That discovery is only as trustworthy as the
notifications the observed containers emit. This page states the contract the
`ObservedState` containers promise, precisely enough to be tested
mechanically. The snapshot-diff fuzz tester (`test/test_container_fuzz.jl`)
is the runnable form of this page: it performs random mutation sequences
against each container, computes the true change set by comparing before and
after snapshots, and asserts the contract below.

## Vocabulary

A **place** is a leaf location in the physical state that holds a primitive
value: a struct field of `Int`, `Float64`, `Bool`, an enum, and so on. Places
are what preconditions read and what `fire!` writes.

An **address** is the name of a place: the tuple of path components from the
physical state to the leaf. Components are

- `Member(fieldname)` for struct fields (both fields of the physical state
  and fields of `@keyedby` element structs),
- `Int` for a one-dimensional `ObservedVector` index,
- `NTuple{N,Int}` for an `N`-dimensional `ObservedArray` index,
- the raw key for an `ObservedDict` entry.

Example: `(Member(:actor), 7, Member(:speed))` names
`physical.actor[7].speed`.

The **denotation** of an address at a moment in time is the value stored at
that place, or ⊥ (undefined) if the address names no live place — an index
beyond the array extent, a key absent from the dict.

## The contract

**C1 — Write soundness.** After any mutating operation on the physical
state, the set of addresses appended to `obs_modified` is a superset of the
set of addresses whose denotation changed, including changes to and from ⊥.
Over-notification is permitted (it costs re-evaluation, not correctness);
under-notification is a bug, because an event whose enabling condition
depends on a silently-changed place will never be re-examined.

**C2 — Address integrity.** At every moment a notification is emitted, the
`_address` chain of the emitting element is rooted at the physical state and
names the slot the element currently occupies. A notification emitted through
a stale address is a C1 violation in disguise: it reports a change at a place
other than the one that changed.

**C3 — Address determinism.** The address of a place is a pure function of
the path used to reach it. Two runs of the same program produce the same
addresses; addresses can be serialized, compared, and forged (constructed by
code that never touched the container, e.g. a generator template binding
event fields into an address pattern). Nothing about an address depends on
memory layout, hashing, or iteration order.

**Read symmetry.** The same three statements hold for reads and `obs_read`:
every operation whose *result* depends on the denotation of a place must
notify a read of that place, or of a coarser address that covers it (see
whole-container reads below). Reads feed the dependency network that decides
which events to re-check, so a missed read disables future wake-ups — the
same failure mode as a missed write, one step removed.

## Granularity: per-place, whole-container, and bulk reads

A read notification with a concrete address, such as `(Member(:calls),
(3, Up), Member(:requested))`, is **per-place**.

Some operations depend on the *shape* of a container rather than any one
entry: `length`, `isempty`, `keys`, `values`, `pairs` on an `ObservedDict`,
and every operation on an `ObservedSet`. These emit a **whole-container**
read or write: the container's own address with no trailing component, e.g.
`(Member(:calls),)`. A whole-container read means "this computation depends
on the entire container"; any write inside the container must be treated as
affecting it. This is sound and deliberately coarse.

`ObservedSet` is entirely whole-container: its elements are values, not
addressable places, so membership tests, insertions, and removals all read or
write the set's own address. Use a set when the *fact of membership* is the
state, and events should react to any change of the set.

## Fixed extent: position is identity

For `ObservedArray` and `ObservedVector`, an integer index is the identity
of a place. `actors[7]` must mean the same individual for the life of the
simulation, because addresses containing `7` are stored in the dependency
network and in generator templates that outlive any single read.

This only holds if the array's extent is fixed. A `popfirst!` or `deleteat!`
shifts every subsequent element to a new index: every address past the
deletion point changes denotation, the vacated tail becomes ⊥, and identity
silently migrates between addresses. Rather than notify O(n) places per
operation and still leave identity unstable, ChronoSim **restricts observed
arrays to fixed extent**:

- Allocate with `ObservedArray{T,Member}(undef, dims...)` and fill by
  `setindex!`.
- Element writes (`arr[i] = x`, `arr[i].field = v`) are the supported
  mutations.
- Length-changing operations — `push!`, `pop!`, `pushfirst!`, `popfirst!`,
  `append!`, `resize!` — throw a `FixedExtentError`.

**Choose containers by identity model:** positional addressing
(`ObservedArray`) when the population is fixed and dense — grid cells, a
fleet of `n` machines; keyed addressing (`ObservedDict`) when entities are
born, die, or carry natural identifiers — the key is the identity, and
`delete!`/`setindex!` change exactly one place. The full slot-map container
(stable handles over a dense store) is future work; the restriction above is
the honest contract until it exists.

## Documented read coarseness and holes

The following behaviors are part of the contract in its current form. They
are sound but coarse; the fuzzer measures their cost as imprecision, not
failure.

- `length`, `isempty`, `keys`, `values`, and `pairs` on an `ObservedDict`
  read the whole container.
- Iterating an `ObservedDict` with primitive values reads each key it
  yields.

Absence is observable: `haskey(dict, k)`, and the miss paths of `get`,
`get!`, and `pop!(dict, k, default)`, notify a read of the key `k` itself
even though `k` names no live place. Addresses are forgeable (C3), so the
dependency network can hold interest in a place before it exists; inserting
`k` later notifies a write of the same address and wakes the dependent
event.

The following are **known unsound holes**, tracked to be fixed (a test that
demonstrates one is a passing regression test once fixed):

- Iterating an `ObservedArray` or `ObservedSet` emits no reads. For
  fixed-extent arrays of compound elements this is benign — element field
  reads notify individually, and the extent cannot change — but iteration
  that inspects primitive element values directly is invisible. Preconditions
  should index rather than iterate, or the loop must be counted as reading
  every place it touched.

## What the fuzzer asserts

For each container type, the fuzzer generates random operation sequences
(reads, writes, and — for dicts and sets — insertions and deletions),
snapshots the raw underlying storage before and after each operation, and
computes the true denotation-change set Δ including ⊥ transitions. It then
asserts:

1. **C1/soundness:** `notified_writes ⊇ Δ` after every mutation.
2. **C2/integrity:** every notified address, replayed against the physical
   state by pure address lookup, resolves to the element that emitted it (for
   compound elements) or to the mutated slot (for primitive elements).
3. **C3/determinism:** the same operation sequence run twice from the same
   seed yields the identical notification sequence.
4. **Precision (reported, not asserted):** `|notified_writes| / |Δ|` per
   operation class — the over-notification factor.
