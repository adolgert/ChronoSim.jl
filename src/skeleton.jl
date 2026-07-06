########## TrajectorySkeleton + RecordSkeleton policy
#
# An opt-in recording policy (Phase 1b). `RecordSkeleton` plugs into the
# `ExecutionPolicy` hooks and captures everything replay (1c) and the why-verbs
# (1e) will need: the pre-initialization RNG state, per fired event its clock
# key / firing time / changed addresses, and the enable/disable/proposal
# history that preceded it. Recording is opt-in; a simulation constructed
# without the policy is `NoPolicy` and pays nothing.

using Random: Xoshiro
using Serialization: serialize, deserialize
# `UnivariateDistribution` via framework.jl's module-level `using Distributions`.

export RecordSkeleton, TrajectorySkeleton, recorded_skeleton, save_skeleton, load_skeleton

public SkeletonStep, SkeletonInit, EnableRecord

"""
    EnableRecord{CK}

One distribution commitment to the sampler: a clock key `clock`, the
`distribution` handed to the sampler, and `te`, the absolute zero time of that
distribution. Stored inside a [`SkeletonStep`](@ref) or [`SkeletonInit`](@ref).
"""
struct EnableRecord{CK}
    clock::CK
    distribution::UnivariateDistribution   # abstract field; small immutable structs
    te::Float64                             # absolute zero time of `distribution`
end

"""
    SkeletonStep{CK}

The record of one fired event: `clock` (the fired clock key), `when` (firing
time), `changed` (addresses written by the event and any immediate events it
triggered, in write order), and the `enabled`, `disabled`, and `proposed`
clocks from bringing the event set back into agreement with the new state.
"""
struct SkeletonStep{CK}
    clock::CK                  # fired clock key
    when::Float64              # firing time
    changed::Vector{Tuple}     # durable ordered copy of changed_places
    enabled::Vector{EnableRecord{CK}}
    disabled::Vector{CK}
    proposed::Vector{CK}
end

"""
    SkeletonInit{CK}

The initialization record: `when` (`sim.when` at initialization), the addresses
the initializer wrote (`changed`), and the clocks `enabled` (with
distributions), `disabled` (always empty today, kept for format stability), and
`proposed` before the first step.
"""
struct SkeletonInit{CK}
    when::Float64              # sim.when at initialization (0.0 today)
    changed::Vector{Tuple}
    enabled::Vector{EnableRecord{CK}}
    disabled::Vector{CK}       # always empty today; kept for format stability
    proposed::Vector{CK}
end

"""
    TrajectorySkeleton{CK}

The recorded skeleton of one simulation run, produced by
[`RecordSkeleton`](@ref). `CK` is the simulation's clock-key type.

# Fields

  * `rng_state::Xoshiro` — a copy of the simulation RNG taken before the
    initializer ran; restoring it and re-running reproduces the trajectory
    exactly.
  * `metadata::Any` — the opaque value given to `RecordSkeleton`.
  * `init::SkeletonInit{CK}` — the initialization record: `when`, the
    addresses the initializer wrote (`changed`), and the clocks proposed and
    enabled (with distributions) before the first step.
  * `steps::Vector{SkeletonStep{CK}}` — one entry per fired event, in firing
    order. Each step carries `clock` (the fired clock key), `when` (firing
    time), `changed` (addresses written by the event and any immediate events
    it triggered, in write order), and the `enabled` (with the committed
    distribution object and its zero time `te`), `disabled`, and `proposed`
    clock keys from bringing the event set back into agreement with the new
    state.

A step's `enabled` includes re-enables (distribution replacements for a
still-enabled clock); an enabled interval for a clock runs from its first
enable after it was last disabled or fired. `init.disabled` is always empty
under the current executor and is kept for format stability.
"""
struct TrajectorySkeleton{CK}
    rng_state::Xoshiro
    metadata::Any
    init::SkeletonInit{CK}
    steps::Vector{SkeletonStep{CK}}
end

# Internal. CK-typed accumulation state behind a function barrier: the
# RecordSkeleton field is abstract (CK is unknown at policy construction), so
# each hook makes one dynamic dispatch into a _rec_* method specialized on
# _SkeletonRecorder{CK}, inside which every push! is type-stable.
mutable struct _SkeletonRecorder{CK}
    skeleton::TrajectorySkeleton{CK}
    pending_enabled::Vector{EnableRecord{CK}}
    pending_disabled::Vector{CK}
    pending_proposed::Vector{CK}
end

"""
    RecordSkeleton(; metadata=nothing)

An [`ExecutionPolicy`](@ref) that records a [`TrajectorySkeleton`](@ref) of
the run: the pre-initialization RNG state, and per fired event its clock key,
firing time, changed state addresses, and the enable/disable/proposal history
that preceded it. Recording is opt-in: pass `policy=RecordSkeleton()` to
[`SimulationFSM`](@ref); a simulation constructed without it records nothing
and pays nothing. `metadata` is stored opaquely in the skeleton — put model
identification (module, constructor arguments, git SHA) there; the framework
never reads it.

The policy only observes: it never draws from the RNG and never mutates state,
so a recorded run's trajectory is identical to the same seed run unrecorded.
Retrieve the result with [`recorded_skeleton`](@ref) after `run` returns.
Re-initializing the same simulation discards the previous recording.

```julia
rec = RecordSkeleton(metadata=(model="sirvillage", people=30))
sim = SimulationFSM(physical, events; seed=2938423, policy=rec)
ChronoSim.run(sim, InitEvent(), stop)
skel = recorded_skeleton(rec)
```
"""
mutable struct RecordSkeleton <: ExecutionPolicy
    metadata::Any
    recorder::Union{Nothing,_SkeletonRecorder}   # bound at on_preinit
end
RecordSkeleton(; metadata=nothing) = RecordSkeleton(metadata, nothing)

########## Hook methods

function on_preinit(p::RecordSkeleton, sim)
    CK = keytype(sim.enabled_events)      # Base.keytype(::Dict) = CK; CompetingClocks
                                          # extends Base.keytype, so no shadowing
    init = SkeletonInit{CK}(sim.when, Tuple[], EnableRecord{CK}[], CK[], CK[])
    steps = SkeletonStep{CK}[]
    sizehint!(steps, 4096)
    skel = TrajectorySkeleton{CK}(copy(sim.rng), p.metadata, init, steps)
    p.recorder = _SkeletonRecorder{CK}(skel, EnableRecord{CK}[], CK[], CK[])
    return nothing
end

on_propose(p::RecordSkeleton, sim, event) = _rec_propose(p.recorder, clock_key(event))
on_enable(p::RecordSkeleton, sim, ck, event, dist, te) = _rec_enable(p.recorder, ck, dist, te)
on_disable(p::RecordSkeleton, sim, ck) = _rec_disable(p.recorder, ck)
on_init(p::RecordSkeleton, sim, init_evt, changed) = _rec_init(p.recorder, changed)
on_postfire(p::RecordSkeleton, sim, ck, event, when, changed) =
    _rec_step(p.recorder, ck, when, changed)
# on_prefire is NOT overridden: on_postfire already carries (clock_key, when,
# changed_places), which is everything a sealed step needs.

# Guards: a hook arriving before on_preinit (impossible through run/
# trace_likelihood, cheap to be safe about) is a silent no-op.
_rec_propose(::Nothing, ck) = nothing
_rec_enable(::Nothing, ck, dist, te) = nothing
_rec_disable(::Nothing, ck) = nothing
_rec_init(::Nothing, changed) = nothing
_rec_step(::Nothing, ck, when, changed) = nothing

_rec_propose(r::_SkeletonRecorder, ck) = (push!(r.pending_proposed, ck); nothing)
function _rec_enable(r::_SkeletonRecorder{CK}, ck, dist, te) where {CK}
    push!(r.pending_enabled, EnableRecord{CK}(ck, dist, te))
    return nothing
end
_rec_disable(r::_SkeletonRecorder, ck) = (push!(r.pending_disabled, ck); nothing)

function _rec_init(r::_SkeletonRecorder, changed)
    init = r.skeleton.init
    append!(init.changed, changed)                 # OrderedSet{Tuple} -> Vector{Tuple}
    append!(init.enabled, r.pending_enabled);   empty!(r.pending_enabled)
    append!(init.disabled, r.pending_disabled); empty!(r.pending_disabled)
    append!(init.proposed, r.pending_proposed); empty!(r.pending_proposed)
    return nothing
end

function _rec_step(r::_SkeletonRecorder{CK}, ck, when, changed) where {CK}
    step = SkeletonStep{CK}(ck, when, collect(Tuple, changed),
        copy(r.pending_enabled), copy(r.pending_disabled), copy(r.pending_proposed))
    empty!(r.pending_enabled); empty!(r.pending_disabled); empty!(r.pending_proposed)
    push!(r.skeleton.steps, step)
    return nothing
end

"""
    recorded_skeleton(policy::RecordSkeleton) -> TrajectorySkeleton

Return the skeleton recorded by `policy`. Throws an `ArgumentError` when the
policy has not yet observed an initialized run.
"""
function recorded_skeleton(p::RecordSkeleton)
    r = p.recorder
    r === nothing && throw(ArgumentError(
        "this RecordSkeleton has not observed a run; pass it as " *
        "`policy=RecordSkeleton()` to SimulationFSM and run the simulation first"))
    return r.skeleton
end

########## Equality and hash

Base.:(==)(a::EnableRecord, b::EnableRecord) =
    a.clock == b.clock && a.distribution == b.distribution && a.te == b.te
Base.hash(a::EnableRecord, h::UInt) =
    hash(a.te, hash(a.distribution, hash(a.clock, hash(:EnableRecord, h))))

Base.:(==)(a::SkeletonStep, b::SkeletonStep) =
    a.clock == b.clock && a.when == b.when && a.changed == b.changed &&
    a.enabled == b.enabled && a.disabled == b.disabled && a.proposed == b.proposed
Base.hash(a::SkeletonStep, h::UInt) =
    hash(a.proposed, hash(a.disabled, hash(a.enabled, hash(a.changed,
        hash(a.when, hash(a.clock, hash(:SkeletonStep, h)))))))

Base.:(==)(a::SkeletonInit, b::SkeletonInit) =
    a.when == b.when && a.changed == b.changed && a.enabled == b.enabled &&
    a.disabled == b.disabled && a.proposed == b.proposed
Base.hash(a::SkeletonInit, h::UInt) =
    hash(a.proposed, hash(a.disabled, hash(a.enabled, hash(a.changed,
        hash(a.when, hash(:SkeletonInit, h))))))

Base.:(==)(a::TrajectorySkeleton, b::TrajectorySkeleton) =
    a.rng_state == b.rng_state && isequal(a.metadata, b.metadata) &&
    a.init == b.init && a.steps == b.steps
Base.hash(a::TrajectorySkeleton, h::UInt) =
    hash(a.steps, hash(a.init, hash(a.metadata, hash(a.rng_state,
        hash(:TrajectorySkeleton, h)))))

########## Show

function Base.show(io::IO, sk::TrajectorySkeleton)
    tend = isempty(sk.steps) ? sk.init.when : sk.steps[end].when
    print(io, "TrajectorySkeleton(", length(sk.steps), " steps, t=",
        sk.init.when, "..", tend, ")")
end

function Base.show(io::IO, ::MIME"text/plain", sk::TrajectorySkeleton{CK}) where {CK}
    counts = Dict{Symbol,Int}()
    for s in sk.steps
        evt = s.clock[1]::Symbol           # clock_key()'s first component
        counts[evt] = get(counts, evt, 0) + 1
    end
    top = sort!(collect(counts); by=kv -> (-kv[2], kv[1]))   # count desc, name asc: stable
    tend = isempty(sk.steps) ? sk.init.when : sk.steps[end].when
    println(io, "TrajectorySkeleton")
    println(io, "  clock key  : ", CK)
    println(io, "  steps      : ", length(sk.steps))
    println(io, "  time span  : ", sk.init.when, " -> ", tend)
    print(io,   "  top events : ")
    print(io, isempty(top) ? "none" :
        join((string(k, " ", v) for (k, v) in Iterators.take(top, 5)), " | "))
end

########## Serialization

"""
    save_skeleton(path, skel::TrajectorySkeleton) -> path
    load_skeleton(path) -> TrajectorySkeleton

Write/read a skeleton with the `Serialization` stdlib. The format is bound to
the Julia version and to the struct layouts of ChronoSim and Distributions:
a file written under one Julia or package version may fail to load under
another. Use it for debugging sessions and CI artifacts, not archival; a
portable format is future work.
"""
function save_skeleton(path::AbstractString, skel::TrajectorySkeleton)
    open(path, "w") do io
        serialize(io, skel)
    end
    return String(path)
end

"""
    load_skeleton(path) -> TrajectorySkeleton

Read a skeleton written by [`save_skeleton`](@ref). The format is bound to the
Julia version and package struct layouts; see `save_skeleton` for the caveats.
"""
load_skeleton(path::AbstractString) = deserialize(path)::TrajectorySkeleton
