########## PolicyStack: compose several ExecutionPolicies (Phase 1d)
#
# A generic combinator over the ExecutionPolicy hook trait. Every hook fans out
# to each member in tuple order via first/tail recursion with explicit per-hook
# argument lists (not Vararg), so a concrete stack is statically dispatched and
# an empty stack compiles to `return nothing` like NoPolicy. Chosen over
# pairwise policy references because 1e composes three-plus policies and Phase 2
# a fourth; one O(1) combinator beats O(n^2) coupling.

export PolicyStack

public find_policy

"""
    PolicyStack(policies::ExecutionPolicy...)

Compose several [`ExecutionPolicy`](@ref)s into one: every hook fans out to
each member **in the given order**. The member tuple is a type parameter, so a
concrete stack is statically dispatched and an empty stack compiles away like
[`NoPolicy`](@ref). Order matters when members interact: place a
[`RecordSkeleton`](@ref) *before* a [`CheckInvariants`](@ref) so the recorded
skeleton already contains the violating step when the violation is thrown.
"""
struct PolicyStack{T<:Tuple} <: ExecutionPolicy
    policies::T
end
PolicyStack(policies::ExecutionPolicy...) = PolicyStack(policies)

# One fan-out helper per hook, generated at load time. Explicit per-hook
# argument lists (not Vararg) keep every call statically specialized. All seven
# hooks fan out, including `on_preinit` (1b's seventh hook) so a RecordSkeleton
# inside a stack still captures the pre-init RNG state.
for (hook, argnames) in (
    (:on_preinit, ()),
    (:on_init, (:init_evt, :changed_places)),
    (:on_propose, (:event,)),
    (:on_enable, (:clock_key, :event, :distribution, :te)),
    (:on_disable, (:clock_key,)),
    (:on_prefire, (:clock_key, :event, :when)),
    (:on_postfire, (:clock_key, :event, :when, :changed_places)),
)
    fan = Symbol(:_fan_, hook)
    @eval begin
        @inline $fan(::Tuple{}, sim, $(argnames...)) = nothing
        @inline function $fan(ps::Tuple, sim, $(argnames...))
            $hook(first(ps), sim, $(argnames...))
            return $fan(Base.tail(ps), sim, $(argnames...))
        end
        $hook(stack::PolicyStack, sim, $(argnames...)) =
            $fan(stack.policies, sim, $(argnames...))
    end
end

"""
    find_policy(::Type{T}, policy) -> Union{T,Nothing}

Return the first policy of type `T` in `policy` — `policy` itself, or, when it
is a [`PolicyStack`](@ref), its first matching member (searching nested stacks
depth-first) — else `nothing`.
"""
find_policy(::Type{T}, p::ExecutionPolicy) where {T} = p isa T ? p : nothing
find_policy(::Type{T}, stack::PolicyStack) where {T} = _find_policy(T, stack.policies)
@inline _find_policy(::Type{T}, ::Tuple{}) where {T} = nothing
@inline function _find_policy(::Type{T}, ps::Tuple) where {T}
    hit = find_policy(T, first(ps))
    hit !== nothing && return hit
    return _find_policy(T, Base.tail(ps))
end
