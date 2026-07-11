########## The recipe layer: the θ-free structural description BEHIND the seam.
#
# Milestone 2 (design guarantee G4). The θ seam (`enable(event, physical, θ,
# when)`) hands an estimator an explicit parameter vector, but a *record-derived*
# estimator needs more: it must rebuild each clock's distribution at a θ (possibly
# dual-valued) the forward run never saw, WITHOUT re-running user model code. That
# requires a θ-FREE, isbits description of the distribution that can be stored in a
# record and later combined with any θ. `DistRecipe` is that description.
#
# This struct is ported faithfully from the VasAdjoint prototype
# (knowledge/proto_vas_adjoint.md), where it was validated as the one source of
# truth that keeps simulator, likelihood, replay, and oracle from disagreeing: the
# seam distribution is DERIVED from the recipe (recipe + θ -> distribution), so an
# event that opts into `enable_recipe` cannot have its `enable` drift from what a
# record replays.

using Distributions

export DistRecipe, FAM_EXPONENTIAL, FAM_WEIBULL, build_distribution,
    enable_recipe, enable_from_recipe

const FAM_EXPONENTIAL = 1
const FAM_WEIBULL = 2

"""
    DistRecipe(fam, param, mult, shape)

A θ-free, `isbits` description of one clock's waiting-time distribution.

# Fields

  * `fam::Int` — the family, `FAM_EXPONENTIAL` or `FAM_WEIBULL`.
  * `param::Int` — which component of the parameter vector `θ` governs the rate.
  * `mult::Float64` — a state-dependent rate multiplier (e.g. a token count for a
    mass-action rate); the realized rate is `mult * θ[param]`.
  * `shape::Float64` — the family's fixed shape. `NaN` for the exponential family,
    which has no shape.

The realized distribution at a parameter vector `θ` (via [`build_distribution`](@ref))
has rate `mult * θ[param]`, i.e. scale `inv(mult * θ[param])`.

# Equality

Recipes compare **by value** so that "the recipe changed while the transition
stayed enabled" — the mid-flight re-evaluation trigger of later milestones — is a
working test. The exponential family stores `shape == NaN`, and `NaN != NaN` under
`==`, which would wrongly make two identical exponential recipes compare unequal.
We therefore define `Base.:(==)` to compare `shape` with `isequal`
(`isequal(NaN, NaN) === true`) while the other fields use `==`. `Base.hash` is
overridden to match, so recipes are also usable as dictionary keys.

We keep `NaN` as the exponential shape (rather than a `0.0` sentinel) because it
is the value the VasAdjoint prototype validated and because `NaN` cannot be
mistaken for a real Weibull shape; the equality override is the price of that
choice and is paid once, here.
"""
struct DistRecipe
    fam::Int
    param::Int
    mult::Float64
    shape::Float64
end

# Field-wise equality, but `isequal` on `shape` so two exponential recipes (whose
# shape is NaN) compare equal. A changed `mult`, `param`, or `fam` compares unequal.
Base.:(==)(a::DistRecipe, b::DistRecipe) =
    a.fam == b.fam && a.param == b.param && a.mult == b.mult && isequal(a.shape, b.shape)
# Hash must agree with the custom ==: hash the shape via `isequal` semantics too.
Base.hash(r::DistRecipe, h::UInt) =
    hash(r.fam, hash(r.param, hash(r.mult, hash(r.shape, hash(:DistRecipe, h)))))

"""
    build_distribution(r::DistRecipe, θ)

Realize the θ-free [`DistRecipe`](@ref) `r` at a parameter vector `θ` into a
Distributions.jl distribution with rate `r.mult * θ[r.param]`.

# Type stability

Both branches return a distribution whose `partype` is `eltype(θ)`: for a dual
`θ`, the exponential scale `inv(r.mult * θ[r.param])` is a `Dual`, so
`Exponential` has dual `partype`; in the Weibull branch the `Float64` `shape` is
promoted against the dual scale by the `Weibull(α, θ)` constructor, so its
`partype` is dual as well. This is what lets `ForwardDiff` thread a gradient
through a record replay.
"""
build_distribution(r::DistRecipe, θ) =
    r.fam == FAM_EXPONENTIAL ? Exponential(inv(r.mult * θ[r.param])) :
                               Weibull(r.shape, inv(r.mult * θ[r.param]))

"""
    enable_recipe(event, physical, when) -> (DistRecipe, te) | nothing

The θ-free structural half of the seam, opt-in. An event that defines this returns
a [`DistRecipe`](@ref) and an enabling time `te`; its four-argument
[`enable`](@ref) is then DERIVED with [`enable_from_recipe`](@ref) so the seam and
the recipe read one source of truth and can never disagree. The default returns
`nothing` (no recipe).
"""
enable_recipe(event::SimEvent, physical, when) = nothing

"""
    enable_from_recipe(event, physical, θ, when) -> (dist, te)

Derive an event's four-argument [`enable`](@ref) from its [`enable_recipe`](@ref):
read the recipe, then [`build_distribution`](@ref) it at `θ`. Wire it in one line
so the distribution logic lives only in the recipe:

```julia
enable_recipe(::MyEvent, phys, when) = (DistRecipe(FAM_EXPONENTIAL, 1, 1.0, NaN), when)
enable(e::MyEvent, phys, θ, when)    = enable_from_recipe(e, phys, θ, when)
```
"""
function enable_from_recipe(event::SimEvent, physical, θ, when)
    r = enable_recipe(event, physical, when)
    r === nothing && throw(ArgumentError(
        "enable_from_recipe called for $(typeof(event)), which does not define " *
        "enable_recipe(event, physical, when)"))
    (recipe, te) = r
    return (build_distribution(recipe, θ), te)
end
