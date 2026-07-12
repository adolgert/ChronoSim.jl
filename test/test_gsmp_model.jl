using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks: NextReactionMethod
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!, param_names

# Phase OB-3c: the model value. GsmpModel holds exactly what determines the
# probability law of trajectories as a function of θ — the event families in
# declaration order, the initial law, the global parameter names — and derives
# the rest (resolved bindings, the instance-key union, the family-position
# order) once at construction. `simulate` is the model-value front door; its
# core obligation is byte-identity with the hand-built SimulationFSM front
# door on the same master seed.

# A machines model whose two families each bind their one formal (:rate) to a
# DIFFERENT global θ name, plus a Bernoulli recipe over the up flags, so one
# model exercises the binding seam, the θ-dependent initial law, and the
# instance-key union at once. fire! never draws, so trajectories are pure
# functions of x₀ and the per-clock streams — the setting where the two front
# doors must agree bit for bit.
module GMShop
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!, param_names

@keyedby Machine Int64 begin
    up::Bool
end

@observedphysical Shop begin
    machine::ObservedVector{Machine,Member}
end

function Shop(n::Int)
    m = ObservedArray{Machine,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Machine(true)
    end
    return Shop(m)
end

struct Fail <: SimEvent
    idx::Int64
end
param_names(::Type{Fail}) = (:rate,)
@precondition precondition(e::Fail, s) = s.machine[e.idx].up
enable(::Fail, s, p, when) = (Exponential(1 / p.rate), when)
fire!(e::Fail, s, when, rng) = (s.machine[e.idx].up = false; nothing)

struct Repair <: SimEvent
    idx::Int64
end
param_names(::Type{Repair}) = (:rate,)
@precondition precondition(e::Repair, s) = !s.machine[e.idx].up
enable(::Repair, s, p, when) = (Exponential(1 / p.rate), when)
fire!(e::Repair, s, when, rng) = (s.machine[e.idx].up = true; nothing)

ups(s) = [s.machine[i].up for i in eachindex(s.machine)]
end # module GMShop

# Two structurally IDENTICAL θ-free models that differ only in one event
# type's NAME: Fail sorts before Repair alphabetically, Zfail sorts after.
# They exist to show the family-position order is a function of tuple
# position, not of the name, while the model-free interim isless is not.
# Construction-only models: the order tests never simulate them, so the event
# types need no precondition/enable/fire! methods.
module GMOrder
using ChronoSim
struct Fail <: SimEvent
    idx::Int64
end
struct Repair <: SimEvent
    idx::Int64
end
end # module GMOrder

module GMOrderZ
using ChronoSim
struct Zfail <: SimEvent
    idx::Int64
end
struct Repair <: SimEvent
    idx::Int64
end
end # module GMOrderZ

# The one model most tests share: Fail's rate is :lambda, Repair's is :mu, and
# the recipe's Bernoulli up-probability is :p0 (read positionally, θ[3],
# because a recipe receives the WHOLE θ vector, not a family view).
function _gmshop_model(n::Int)
    recipe = InitialRecipe(
        () -> GMShop.Shop(n),
        [(:machine, i, :up) => (θ -> Bernoulli(θ[3])) for i in 1:n],
    )
    return GsmpModel(
        events=(entry(GMShop.Fail; params=(rate=:lambda,)),
                entry(GMShop.Repair; params=(rate=:mu,))),
        initial=recipe,
        params=(:lambda, :mu, :p0),
    )
end

# =============================================================================
# Construction and accessors: what the model value derives once.
# =============================================================================

@testset "model value: construction normalizes entries and the initial law and derives the key union, the family index, and the resolved bindings once" begin
    θ = [1.3, 2.1, 0.6]
    model = _gmshop_model(3)

    # The entries tuple, in declaration order, each normalized to EventEntry.
    evs = model_events(model)
    @test evs isa Tuple
    @test length(evs) == 2
    @test all(e -> e isa EventEntry, evs)
    @test event_type(evs[1]) === GMShop.Fail
    @test event_type(evs[2]) === GMShop.Repair

    # The initial law is stored normalized, ready for run/trace_likelihood.
    @test model_initial(model) isa ChronoSim.NormalizedInitialLaw
    @test model_initial(model).form == :recipe

    # Global names, positional for θ.
    @test model_params(model) == (:lambda, :mu, :p0)

    # The derived key type is the instance-key union, inline for isbits events.
    @test model_keytype(model) === Union{GMShop.Fail,GMShop.Repair}
    @test Base.isbitsunion(model_keytype(model))

    # Family position by type and by instance.
    @test family_index(model, GMShop.Fail) == 1
    @test family_index(model, GMShop.Repair) == 2
    @test family_index(model, GMShop.Repair(4)) == 2

    # The resolved binding maps each family's one formal to its θ position,
    # and the view built from it is the NamedTuple the θ seam will hand enable.
    @test model_binding(model, GMShop.Fail) isa ChronoSim.ResolvedBinding
    @test model_binding(model, GMShop.Fail).idx == (1,)
    @test model_binding(model, GMShop.Repair).idx == (2,)
    @test model_param_view(model, GMShop.Fail, θ) == (rate=1.3,)
    @test model_param_view(model, GMShop.Repair, θ) == (rate=2.1,)

    # A model with no bindings needs no params: bare types normalize and the
    # whole-θ passthrough view is the very same object.
    plain = GsmpModel(events=(GMOrder.Fail, GMOrder.Repair), initial=() -> 0)
    @test model_params(plain) == ()
    @test all(e -> e isa EventEntry, model_events(plain))
    @test model_binding(plain, GMOrder.Fail) === nothing
    @test model_param_view(plain, GMOrder.Fail, θ) === θ
end

@testset "model value: construction rejects a duplicated event type, a binding to an unknown global name, and a foreign type in family_index" begin
    recipe_init = () -> GMShop.Shop(2)

    # Same-type-twice: the parametric-type workaround is named in the error.
    dup_err = try
        GsmpModel(
            events=(entry(GMShop.Fail; params=(rate=:lambda,)),
                    entry(GMShop.Fail; params=(rate=:mu,))),
            initial=recipe_init, params=(:lambda, :mu),
        )
        nothing
    catch e
        e
    end
    @test dup_err isa ArgumentError
    @test occursin("appears twice", dup_err.msg)
    @test occursin("parametric type", dup_err.msg)

    # A binding whose actual name is not among the model's global names.
    bind_err = try
        GsmpModel(
            events=(entry(GMShop.Fail; params=(rate=:nope,)),
                    entry(GMShop.Repair; params=(rate=:mu,))),
            initial=recipe_init, params=(:lambda, :mu),
        )
        nothing
    catch e
        e
    end
    @test bind_err isa ArgumentError
    @test occursin(":nope", bind_err.msg)

    # A family that declares formals cannot resolve without global names.
    @test_throws ArgumentError GsmpModel(
        events=(entry(GMShop.Fail; params=(rate=:lambda,)),), initial=recipe_init)

    # An empty event list is not a model.
    @test_throws ArgumentError GsmpModel(events=(), initial=recipe_init)

    # family_index refuses a type that is not a family of this model, naming it.
    model = _gmshop_model(2)
    foreign_err = try
        family_index(model, GMOrder.Fail)
        nothing
    catch e
        e
    end
    @test foreign_err isa ArgumentError
    @test occursin("not a family", foreign_err.msg)
    @test_throws ArgumentError model_binding(model, GMOrder.Fail)

    # simulate reads θ positionally against the names, so a length mismatch is
    # an immediate error, not a silent partial read.
    @test_throws ArgumentError simulate(Xoshiro(1), model, [1.0, 2.0]; horizon=1.0)
end

# =============================================================================
# Plan test 17: the two-front-doors equivalence obligation.
# =============================================================================

@testset "model value: simulate on the model value and a hand-built SimulationFSM produce byte-identical trajectories on the same seeds" begin
    n = 3
    θ = [1.3, 2.1, 0.6]
    horizon = 8.0
    model = _gmshop_model(n)

    # Front door one: the model value. The ONLY draw simulate takes from the
    # caller's rng is the master seed.
    rng = Xoshiro(20260712)
    rec = simulate(rng, model, θ; horizon=horizon)

    # Front door two: the hand-built twin, given the SAME master seed simulate
    # drew, the same key type, params, names, entries, law, policy, and stop.
    twin_rng = Xoshiro(20260712)
    seed = rand(twin_rng, UInt64)
    pol = RecordMinimal(; initializer=model_initial(model))
    sim = SimulationFSM(
        GMShop.Shop(n), model_events(model);
        seed=seed,
        key_type=model_keytype(model),
        params=θ,
        param_names=model_params(model),
        policy=pol,
    )
    ChronoSim.run(sim, model_initial(model), (p, i, e, w) -> w > horizon)
    rec_twin = minimal_record(pol; horizon=horizon)

    # Byte identity: instance keys compare by content (isbits structs) and the
    # firing times are Float64-equal, so == here is bit-for-bit agreement of
    # the whole firing sequence.
    @test length(rec.firings) > 20
    @test rec.firings == rec_twin.firings
    # The realized x₀ is the recipe's draw from the pinned init stream, which
    # depends only on the master seed — never on simulate's throwaway template.
    @test rec.initial_state !== nothing
    @test GMShop.ups(rec.initial_state) == GMShop.ups(rec_twin.initial_state)
    # Every remaining record field, including the isequal-compared initializer
    # (both records carry the model's one normalized law object).
    @test rec == rec_twin
    @test rec.horizon == rec_twin.horizon == horizon
    @test rec.coupling == rec_twin.coupling
    @test rec.fire_random == rec_twin.fire_random == false
    # Both families fired, so the identity covered both bindings.
    @test any(f -> f[1] isa GMShop.Fail, rec.firings)
    @test any(f -> f[1] isa GMShop.Repair, rec.firings)
end

# =============================================================================
# Plan test 12, completion (the renaming half deferred from OB-3a): the
# family-position key order.
# =============================================================================

@testset "model value: keys sort by family position then fields under model_key_order, and renaming an event type does not change the model-tuple order" begin
    # Two structurally identical models; alphabetical order of the first
    # family's name flips across them (Fail < Repair, but Zfail > Repair).
    modelA = GsmpModel(events=(GMOrder.Fail, GMOrder.Repair), initial=() -> 0)
    modelZ = GsmpModel(events=(GMOrderZ.Zfail, GMOrderZ.Repair), initial=() -> 0)

    keysA = [GMOrder.Repair(2), GMOrder.Fail(3), GMOrder.Repair(1), GMOrder.Fail(1)]
    keysZ = [GMOrderZ.Repair(2), GMOrderZ.Zfail(3), GMOrderZ.Repair(1),
             GMOrderZ.Zfail(1)]

    # model_key_order is a Base.Order.Ordering, so it plugs into plain sort.
    sortedA = sort(keysA; order=model_key_order(modelA))
    sortedZ = sort(keysZ; order=model_key_order(modelZ))

    # Family position leads, fields break ties within a family — and the
    # sorted FAMILY SEQUENCE is identical across the two models because both
    # declared the fail-like family first, whatever it is named.
    @test [family_index(modelA, k) for k in sortedA] == [1, 1, 2, 2]
    @test [family_index(modelZ, k) for k in sortedZ] == [1, 1, 2, 2]
    @test [k.idx for k in sortedA] == [1, 3, 1, 2]
    @test [k.idx for k in sortedZ] == [1, 3, 1, 2]

    # The model-free interim isless ((nameof, fields) order) is NOT rename-
    # robust: the same structural sort flips the family sequence between the
    # two models. This contrast is why the family order must be a model value.
    plainA = sort(keysA)
    plainZ = sort(keysZ)
    @test [family_index(modelA, k) for k in plainA] == [1, 1, 2, 2]
    @test [family_index(modelZ, k) for k in plainZ] == [2, 2, 1, 1]
end

# =============================================================================
# The smoke test: the model-value front door composes with the OB-2
# likelihood path through the self-contained record.
# =============================================================================

@testset "model value: simulate returns a self-contained record whose realized initial state scores through trace_likelihood with no seed relationship to the recording run" begin
    n = 3
    θ = [1.3, 2.1, 0.6]
    horizon = 6.0
    model = _gmshop_model(n)

    rec = simulate(Xoshiro(4711), model, θ; horizon=horizon)
    @test rec.initial_state !== nothing
    @test length(rec.firings) > 5
    @test eltype(rec.firings) == Tuple{model_keytype(model),Float64}

    # Score the record on an evaluation sim built at an UNRELATED seed: the
    # record carries its realized x₀, so the OB-2 record path initializes from
    # that state as a point mass and adds the law's density at it.
    eval_sim = SimulationFSM(
        GMShop.Shop(n), model_events(model);
        seed=99, key_type=model_keytype(model), step_likelihood=true,
        params=θ, param_names=model_params(model),
    )
    ev = trace_likelihood(eval_sim, model_initial(model), rec; params=θ)
    @test ev.feasible
    @test isfinite(ev.loglikelihood)

    # Decomposition check: the law-path likelihood is the point-mass walk of
    # the same firings plus the recipe's logdensity at the recorded x₀. Both
    # sides run the identical deterministic scoring arithmetic, so Float64 ==.
    pt_sim = SimulationFSM(
        GMShop.Shop(n), model_events(model);
        seed=7, key_type=model_keytype(model), step_likelihood=true,
        params=θ, param_names=model_params(model),
    )
    trace = [(when, ck) for (ck, when) in rec.firings]
    ev_pt = trace_likelihood(
        pt_sim, normalize_initial(rec.initial_state), trace; params=θ)
    init_term = initial_logdensity(model_initial(model), rec.initial_state, θ)
    @test ev.loglikelihood == ev_pt.loglikelihood + init_term
end
