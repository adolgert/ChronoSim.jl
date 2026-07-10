########## CountingRNG: a draw-counting proxy over an inner AbstractRNG
#
# Adoption step 1 (design §"What this means for ChronoSim.jl"): a user's
# `fire!(event, physical, when, rng)` may draw randomness, which breaks the
# record-determinism guarantee G3 (the recorded initial condition + firing
# sequence no longer replays to the same trajectory). The decision of record is
# that the RNG STAYS -- easy-mode simulation must keep working -- and the
# framework's obligation is DETECTION, not prevention. `CountingRNG` is that
# detector: wrap `sim.rng`, hand the wrapper to `fire!`, and if the draw count
# advanced during a firing the trajectory is "fire-random" and any record-derived
# estimator must be warned before it trusts the record.
#
# The wrapper must reproduce the inner rng's stream BYTE-FOR-BYTE, because it is
# always installed for every firing (see `modify_state!`): a proxy that changed
# the stream would change every seeded trajectory. Julia's `Xoshiro` funnels all
# generation through a fixed set of primitive `rand` methods (native `UInt64`,
# the partial-word integer types, the `UInt52`/`UInt104` raw words, and the
# `CloseOpen01` float words) plus SIMD bulk `rand!`/`randn!`. We shadow exactly
# those primitives, count one tick each, and DELEGATE value production to the
# inner rng, so the produced bits are identical to using the inner rng directly.
# Counting at the primitive level means every higher-level draw (`rand(1:6)`,
# `randn`, `rand(rng, dist)` from Distributions) advances the count without any
# per-draw allocation.

using Random
using Random: SamplerType, SamplerTrivial, CloseOpen01, UInt52Raw, UInt52, UInt104

export CountingRNG

"""
    CountingRNG(rng::AbstractRNG) <: AbstractRNG

An `AbstractRNG` that forwards every draw to the wrapped `rng` and counts it in
the mutable `count` field. The produced random stream is identical to the
wrapped rng used directly, so installing the counter never perturbs a
trajectory; it only observes how many primitive draws passed through. Used by
the framework to detect whether a user `fire!` drew randomness (see
[`SimulationFSM`](@ref)'s fire-randomness tracking).

Counting is at the generation-primitive level: one tick per native word a draw
consumes. Exact tick counts are an implementation detail (a `Float64` draw is
one tick, `randn` is usually one, a rejection sampler may be several); only
"advanced or not" is contractual, which is all fire-randomness detection needs.
"""
mutable struct CountingRNG{R<:AbstractRNG} <: AbstractRNG
    rng::R
    count::Int
end
CountingRNG(rng::AbstractRNG) = CountingRNG(rng, 0)

# The 52-bit-native trait must mirror the inner rng so generic fallbacks that do
# consult it agree with the inner rng's width.
Random.rng_native_52(r::CountingRNG) = Random.rng_native_52(r.rng)

# Reset the tick counter; returns the previous value.
@inline function reset_count!(r::CountingRNG)
    old = r.count
    r.count = 0
    return old
end

# The partial-word integer primitives Xoshiro resolves through a single method.
const _CountingPartialInt = Union{
    SamplerType{Bool},SamplerType{Int8},SamplerType{UInt8},SamplerType{Int16},
    SamplerType{UInt16},SamplerType{Int32},SamplerType{UInt32},SamplerType{Int64},
}

# Scalar generation primitives: count, then delegate to the inner rng so the bits
# match exactly. `@eval` keeps each method concretely typed (no per-draw dispatch
# overhead, no allocation).
for S in (:(SamplerType{UInt64}), :(SamplerType{UInt128}), :(SamplerType{Int128}),
          :_CountingPartialInt, :(SamplerTrivial{UInt52Raw{UInt64}}),
          :(SamplerTrivial{UInt52{UInt64}}), :(SamplerTrivial{UInt104{UInt128}}))
    @eval @inline function Random.rand(r::CountingRNG, sp::$S)
        r.count += 1
        return rand(r.rng, sp)
    end
end
for FT in (Float16, Float32, Float64)
    @eval @inline function Random.rand(r::CountingRNG, sp::SamplerTrivial{CloseOpen01{$FT}})
        r.count += 1
        return rand(r.rng, sp)
    end
end

# Bulk array fills: Xoshiro uses a SIMD algorithm whose output differs from a
# sequential element-wise fill, so we must delegate to the inner rng to preserve
# the stream. We target exactly Xoshiro's optimized `Array{T}` + sampler pairs;
# this does not overlap the `AliasTable`-array or `BitArray` `rand!` methods, so
# no method ambiguity is introduced (verified by Aqua's ambiguity test).
for FT in (Float16, Float32, Float64)
    @eval @inline function Random.rand!(
        r::CountingRNG, dst::Array{$FT}, sp::SamplerTrivial{CloseOpen01{$FT}}
    )
        r.count += 1
        rand!(r.rng, dst, sp)
        return dst
    end
end
for IT in (Bool, Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Int128, UInt128)
    @eval @inline function Random.rand!(r::CountingRNG, dst::Array{$IT}, sp::SamplerType{$IT})
        r.count += 1
        rand!(r.rng, dst, sp)
        return dst
    end
end
@inline function Random.randn!(r::CountingRNG, dst::Array{T}) where {T<:Base.IEEEFloat}
    r.count += 1
    randn!(r.rng, dst)
    return dst
end
@inline function Random.randexp!(r::CountingRNG, dst::Array{T}) where {T<:Base.IEEEFloat}
    r.count += 1
    randexp!(r.rng, dst)
    return dst
end
