using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks: NextReactionMethod, stream_for!
using Distributions
using ForwardDiff
using Random
import ChronoSim: precondition, generators, enable, fire!

# A draw-free machines model with a Bool `up` field, so an InitialRecipe can
# write Bernoulli draws straight into the state and its logdensity has a closed
# form. Fail/Repair alternate each machine under exponential clocks; fire! never
# draws, so trajectories are pure functions of the initial condition and the
# per-clock streams -- the setting where the old write-to-seed path and the new
# law path must agree bit for bit.
module LawShop
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

const FAIL_RATE = 1.5
const REPAIR_RATE = 2.5

@keyedby Machine Int64 begin
    up::Bool
end

@observedphysical Shop begin
    machine::ObservedVector{Machine,Member}
end

function Shop(n::Int, ups=trues(n))
    m = ObservedArray{Machine,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Machine(ups[i])
    end
    return Shop(m)
end

struct Fail <: SimEvent
    idx::Int64
end
@precondition precondition(e::Fail, s) = s.machine[e.idx].up
enable(::Fail, s, when) = (Exponential(1 / FAIL_RATE), when)
fire!(e::Fail, s, when, rng) = (s.machine[e.idx].up = false; nothing)

struct Repair <: SimEvent
    idx::Int64
end
@precondition precondition(e::Repair, s) = !s.machine[e.idx].up
enable(::Repair, s, when) = (Exponential(1 / REPAIR_RATE), when)
fire!(e::Repair, s, when, rng) = (s.machine[e.idx].up = true; nothing)

# The write-to-seed initializer: writes every machine's status, which is the
# discipline the initial law removes.
function init!(s, when, rng)
    for i in eachindex(s.machine)
        s.machine[i].up = true
    end
    return nothing
end

ups(s) = [s.machine[i].up for i in eachindex(s.machine)]
end # module LawShop

_lawshop_events() = [LawShop.Fail, LawShop.Repair]

function _lawshop_sim(n::Int; seed, policy=NoPolicy(), L::DataType=Float64, observer=nothing)
    return SimulationFSM(
        LawShop.Shop(n), _lawshop_events();
        seed=seed, sampler=NextReactionMethod(), key_type=Tuple,
        step_likelihood=true, likelihood_eltype=L, policy=policy, observer=observer,
    )
end

# =============================================================================
# The ladder: every form normalizes, with theta-dependence proved by form.
# =============================================================================

@testset "initial law: every rung of the ladder normalizes with the theta-dependence its form declares" begin
    # Rung 1: a state value is a point mass with a zero logdensity.
    point = normalize_initial(LawShop.Shop(2))
    @test !is_theta_dependent(point)
    @test has_logdensity(point)
    @test initial_logdensity(point, LawShop.Shop(2), Float64[]) == 0.0

    # Rung 2: a zero-arg thunk is a lazy point mass.
    thunk = normalize_initial(() -> LawShop.Shop(2))
    @test !is_theta_dependent(thunk)
    @test has_logdensity(thunk)

    # Rung 3: (rng) -> state is theta-free by arity, with no density.
    rngform = normalize_initial((rng) -> LawShop.Shop(2))
    @test !is_theta_dependent(rngform)
    @test !has_logdensity(rngform)

    # Rung 4: InitialLaw is the full theta-dependent law.
    full = normalize_initial(InitialLaw((rng, θ) -> LawShop.Shop(2), (s, θ) -> 0.0))
    @test is_theta_dependent(full)
    @test has_logdensity(full)

    # Rung 5: a recipe is theta-dependent and always carries a density.
    recipe = InitialRecipe(
        () -> LawShop.Shop(2),
        [(:machine, i, :up) => (θ -> Bernoulli(θ[1])) for i in 1:2],
    )
    nrec = normalize_initial(recipe)
    @test is_theta_dependent(nrec)
    @test has_logdensity(nrec)

    # A bare (rng, θ) sampler is accepted but density-less.
    bare = normalize_initial((rng, θ) -> LawShop.Shop(2))
    @test is_theta_dependent(bare)
    @test !has_logdensity(bare)

    # The old three-argument write-to-seed callback fits no rung and says so.
    @test_throws ArgumentError normalize_initial((physical, when, rng) -> nothing)
end

# =============================================================================
# Plan test 5: everything-changed seeding vs. the write-to-seed initializer.
# =============================================================================

@testset "initial law: the everything-changed seeding enables exactly the events the write-to-seed initializer enabled, and the two paths produce byte-identical trajectories on the same seeds" begin
    seed = 20260711

    # Same model, same master seed: one sim initialized the old way (the init
    # function writes all state), one via a point-mass law on the identical
    # state. Neither initializer draws, so the reserved init stream is consumed
    # identically (not at all) and the per-clock streams line up exactly.
    sim_old = _lawshop_sim(2; seed=seed)
    ChronoSim.initialize!(InitializeEvent(), LawShop.init!, sim_old)
    sim_law = _lawshop_sim(2; seed=seed)
    ChronoSim.initialize!(sim_law, LawShop.Shop(2))
    @test Set(keys(sim_law.enabled_events)) == Set(keys(sim_old.enabled_events))
    @test !isempty(sim_law.enabled_events)

    # Full trajectories on fresh sims at one master seed: the firing sequences
    # (clock keys AND Float64 times) must be bit-for-bit identical.
    stop = (p, i, e, w) -> i > 40
    pol_old = RecordMinimal(; initializer=LawShop.init!)
    run_old = _lawshop_sim(2; seed=seed, policy=pol_old)
    ChronoSim.run(run_old, LawShop.init!, stop)
    pol_law = RecordMinimal()
    run_law = _lawshop_sim(2; seed=seed, policy=pol_law)
    ChronoSim.run(run_law, normalize_initial(LawShop.Shop(2)), stop)
    rec_old = minimal_record(pol_old)
    rec_law = minimal_record(pol_law)
    @test length(rec_law.firings) == 40
    @test rec_law.firings == rec_old.firings
    @test rec_law.fire_random == false
    # The law-path record carries the realized initial state.
    @test rec_law.initial_state !== nothing
    @test LawShop.ups(rec_law.initial_state) == [true, true]
end

# =============================================================================
# Plan test 6: the (rng) rung is theta-free and needs no density for the score.
# =============================================================================

@testset "initial law: a rng-arity initializer is accepted as theta-free and the score gradient needs no density from it" begin
    # The rng form DRAWS from the reserved init stream (proving the stream is
    # wired through) but lands on a fixed state, so the trace below is feasible
    # under every evaluation sim regardless of its seed.
    rnglaw = normalize_initial((rng) -> begin
        rand(rng)
        LawShop.Shop(2)
    end)
    @test !is_theta_dependent(rnglaw)
    @test !has_logdensity(rnglaw)

    # Record a trajectory through the law path.
    stop = (p, i, e, w) -> i > 25
    pol = RecordMinimal()
    sim = _lawshop_sim(2; seed=4242, policy=pol)
    ChronoSim.run(sim, rnglaw, stop)
    rec = minimal_record(pol)
    trace = [(when, ck) for (ck, when) in rec.firings]

    # The law path evaluates the trace with NO logdensity, and its initial term
    # is exactly 0.0: the law-path likelihood is Float64-identical to the
    # write-to-seed evaluation of the same trace, at two different θ.
    ev_ref = trace_likelihood(_lawshop_sim(2; seed=1), LawShop.init!, trace)
    ev_a = trace_likelihood(_lawshop_sim(2; seed=2), rnglaw, trace; params=[1.0])
    ev_b = trace_likelihood(_lawshop_sim(2; seed=3), rnglaw, trace; params=[5.0])
    @test ev_a.feasible
    @test ev_a.loglikelihood === ev_ref.loglikelihood
    @test ev_b.loglikelihood === ev_a.loglikelihood
end

# =============================================================================
# Plan test 7: theta-dependent and density-less simulates; likelihood refuses.
# =============================================================================

@testset "initial law: a theta-dependent initial law without a density simulates but the likelihood refuses it by name" begin
    bare = normalize_initial((rng, θ) -> LawShop.Shop(2))
    @test is_theta_dependent(bare)
    @test !has_logdensity(bare)

    # Tier 0 is sacred: initialization and forward simulation never refuse.
    stop = (p, i, e, w) -> i > 15
    pol = RecordMinimal()
    sim = _lawshop_sim(2; seed=606, policy=pol)
    ChronoSim.run(sim, bare, stop)
    rec = minimal_record(pol)
    @test length(rec.firings) == 15

    # The likelihood refuses BY NAME.
    trace = [(when, ck) for (ck, when) in rec.firings]
    ex = try
        trace_likelihood(_lawshop_sim(2; seed=7), bare, trace)
        nothing
    catch e
        e
    end
    @test ex isa ArgumentError
    @test occursin("θ-dependent", ex.msg)
    @test occursin("logdensity", ex.msg)
end

# =============================================================================
# The recipe: one description feeds the draw, the density, and the gradient.
# =============================================================================

@testset "initial law: an InitialRecipe adds its initial logdensity to the trace likelihood and ForwardDiff recovers the analytic initial-state score" begin
    n = 3
    p0 = 0.3
    recipe = InitialRecipe(
        () -> LawShop.Shop(n),
        [(:machine, i, :up) => (θ -> Bernoulli(θ[1])) for i in 1:n],
    )

    # Record a run whose x₀ is drawn from the recipe.
    stop = (pp, i, e, w) -> i > 20
    pol = RecordMinimal()
    sim = _lawshop_sim(n; seed=31415, policy=pol)
    sim.params = [p0]
    ChronoSim.run(sim, recipe, stop)
    rec = minimal_record(pol)
    trace = [(when, ck) for (ck, when) in rec.firings]
    x0 = rec.initial_state
    @test x0 !== nothing
    k = count(LawShop.ups(x0))

    # The recipe's density is the Bernoulli product over the realized x₀.
    expected_init = k * log(p0) + (n - k) * log(1 - p0)
    @test initial_logdensity(recipe, x0, [p0]) ≈ expected_init

    # The law-path likelihood equals a write-to-seed evaluation of the same
    # trajectory (an initializer writing exactly the realized x₀) plus the
    # initial term -- the ThetaInit decomposition transferred to ChronoSim.
    ups0 = LawShop.ups(x0)
    reproduce_x0!(s, when, rng) = begin
        for i in eachindex(s.machine)
            s.machine[i].up = ups0[i]
        end
        nothing
    end
    # The evaluation sim must carry the SAME master seed as the recording run:
    # the law path re-DRAWS x₀ from the reserved init stream, and only the same
    # seeding redraws the recorded x₀ (a different seed gives a different x₀ and
    # an infeasible trace). The write-to-seed comparison sim needs no such care.
    ev_plain = trace_likelihood(_lawshop_sim(n; seed=8), reproduce_x0!, trace)
    ev_recipe = trace_likelihood(_lawshop_sim(n; seed=31415), recipe, trace; params=[p0])
    @test ev_recipe.feasible
    @test ev_recipe.loglikelihood ≈ ev_plain.loglikelihood + expected_init

    # Clock rates are θ-free in this model, so the whole θ-gradient of the
    # trajectory likelihood is the initial-state score k/p - (n-k)/(1-p).
    ll(θ) = trace_likelihood(
        _lawshop_sim(n; seed=31415, L=eltype(θ)), recipe, trace; params=θ,
    ).loglikelihood
    g = ForwardDiff.gradient(ll, [p0])
    @test g[1] ≈ k / p0 - (n - k) / (1 - p0)
end

# =============================================================================
# OB-2 self-containment: a MinimalRecord carrying its realized x₀ scores
# without any seed relationship to the recording run.
# =============================================================================

@testset "initial law: a record carrying its realized initial state is scored from that state so evaluation needs no seed relationship to the recording run and the record-based gradient is the initial-state score" begin
    n = 3
    p0 = 0.3
    recipe = InitialRecipe(
        () -> LawShop.Shop(n),
        [(:machine, i, :up) => (θ -> Bernoulli(θ[1])) for i in 1:n],
    )

    stop = (pp, i, e, w) -> i > 20
    pol = RecordMinimal()
    sim = _lawshop_sim(n; seed=31415, policy=pol)
    sim.params = [p0]
    ChronoSim.run(sim, recipe, stop)
    rec = minimal_record(pol)
    @test rec.initial_state !== nothing
    k = count(LawShop.ups(rec.initial_state))

    # The reference: a seed-MATCHED vector-trace evaluation, whose redraw is the
    # recorded x₀ by construction.
    trace = [(when, ck) for (ck, when) in rec.firings]
    ev_matched = trace_likelihood(_lawshop_sim(n; seed=31415), recipe, trace; params=[p0])
    @test ev_matched.feasible

    # The record path with a DIFFERENT master seed: before OB-2 self-containment
    # this either came back infeasible (a different redraw breaks the trace) or,
    # worse, feasibly scored the wrong x₀. Now it initializes from the recorded
    # state, so any seed evaluates to the identical likelihood.
    ev_rec = trace_likelihood(_lawshop_sim(n; seed=8), recipe, rec; params=[p0])
    @test ev_rec.feasible
    @test ev_rec.loglikelihood == ev_matched.loglikelihood

    # The gradient of the record-based likelihood at a dual θ is the density of
    # the RECORDED draw, not of a dual-θ redraw: clock rates are θ-free in this
    # model, so the whole gradient is the analytic initial-state score.
    ll(θ) = trace_likelihood(
        _lawshop_sim(n; seed=99, L=eltype(θ)), recipe, rec; params=θ,
    ).loglikelihood
    g = ForwardDiff.gradient(ll, [p0])
    @test g[1] ≈ k / p0 - (n - k) / (1 - p0)

    # A record WITHOUT a realized state (the pre-OB-2 shape) falls back to the
    # redraw path: the seed-matched evaluation still reproduces the likelihood.
    bare_rec = MinimalRecord(nothing, rec.firings, rec.horizon, rec.coupling,
        rec.fire_random)
    ev_bare = trace_likelihood(_lawshop_sim(n; seed=31415), recipe, bare_rec;
        params=[p0])
    @test ev_bare.loglikelihood == ev_matched.loglikelihood

    # The θ-dependence refusal fires on the record path too: a density-less
    # θ-dependent law must not slip through the point-mass installation.
    bare_law = normalize_initial((rng, θ) -> LawShop.Shop(n))
    @test_throws ArgumentError trace_likelihood(
        _lawshop_sim(n; seed=8), bare_law, rec; params=[p0])
end

# =============================================================================
# Plan test 9: the audit.
# =============================================================================

@testset "initial law: the sample/logdensity audit passes a consistent pair and fails a deliberately inconsistent one" begin
    θ = [0.3]
    consistent = InitialLaw(
        (rng, t) -> rand(rng) < t[1] ? 1 : 0,
        (s, t) -> log(s == 1 ? t[1] : 1 - t[1]),
    )
    res = audit_initial_law(consistent, Xoshiro(11), θ; nsamples=4000)
    @test res.passed
    @test res.support == 2

    # The density CLAIMS p=0.7 while the sampler draws at p=0.3: the audit must
    # reject it loudly.
    inconsistent = InitialLaw(
        (rng, t) -> rand(rng) < t[1] ? 1 : 0,
        (s, t) -> log(s == 1 ? 0.7 : 0.3),
    )
    res2 = audit_initial_law(inconsistent, Xoshiro(11), θ; nsamples=4000)
    @test !res2.passed

    # A density that assigns an observed state probability zero is an automatic
    # failure, not a statistical borderline.
    impossible = InitialLaw(
        (rng, t) -> rand(rng) < t[1] ? 1 : 0,
        (s, t) -> s == 1 ? 0.0 : -Inf,
    )
    res3 = audit_initial_law(impossible, Xoshiro(11), θ; nsamples=200)
    @test !res3.passed

    # The audit needs a density to compare against.
    @test_throws ArgumentError audit_initial_law((rng) -> 1, Xoshiro(1), θ)

    # An observed physical state digests through its scalar leaves, so the audit
    # also runs over real model states.
    shoplaw = InitialLaw(
        (rng, t) -> LawShop.Shop(1, [rand(rng) < t[1]]),
        (s, t) -> log(s.machine[1].up ? t[1] : 1 - t[1]),
    )
    res4 = audit_initial_law(shoplaw, Xoshiro(21), θ; nsamples=2000)
    @test res4.passed
    @test res4.support == 2
end

# =============================================================================
# The pinned init stream: clones share x₀ across a divergence rekey.
# =============================================================================

@testset "initial law: the pinned init stream survives rekey_streams! so a rekeyed clone re-initialized from the same law redraws the same initial state while non-pinned fire streams change" begin
    nmach = 8
    rnglaw = normalize_initial(
        (rng) -> LawShop.Shop(nmach, [rand(rng) < 0.5 for _ in 1:nmach]),
    )

    # Clone the pristine template, then diverge the clone with a new master
    # seed. Initializing both from the same law must give the SAME x₀ (the init
    # stream is pinned to the seeding that created the world), while the
    # clone's other fire streams derive from the new seed.
    sim = _lawshop_sim(nmach; seed=1001)
    c = ChronoSim.clone(sim)
    ChronoSim.rekey_streams!(c, 0xABCDEF01)

    ChronoSim.initialize!(sim, rnglaw)
    ChronoSim.initialize!(c, rnglaw)
    @test LawShop.ups(c.physical) == LawShop.ups(sim.physical)

    # A clone taken after initialization behaves the same: rekey + re-init
    # redraws the identical x₀ because the pinned key re-derives its stream
    # from the original seeding.
    c2 = ChronoSim.clone(sim)
    ChronoSim.rekey_streams!(c2, 0xFEEDBEEF)
    ChronoSim.initialize!(c2, rnglaw)
    @test LawShop.ups(c2.physical) == LawShop.ups(sim.physical)

    # Non-pinned fire streams DID move to the new family: a probe key's first
    # draw differs between the original and the rekeyed clone. Draw from copies
    # so the probe does not perturb either stream family.
    probe = (:probe_key,)
    @test rand(copy(stream_for!(c.fire_streams, probe))) !=
          rand(copy(stream_for!(sim.fire_streams, probe)))

    # And a DIFFERENT template seed gives a different x₀ (the law is really
    # random; 8 fair coins collide with probability 2^-8 per pair, and these
    # fixed seeds do not collide).
    other = _lawshop_sim(nmach; seed=1002)
    ChronoSim.initialize!(other, rnglaw)
    @test LawShop.ups(other.physical) != LawShop.ups(sim.physical)
end

# =============================================================================
# OB-1 compatibility: states_at folds a law-initialized run from the record's
# realized initial state.
# =============================================================================

@testset "initial law: states_at reproduces a law-initialized run from the record's realized initial state field" begin
    nmach = 3
    snaps = Vector{Vector{Bool}}()
    observer = (p, when, evt, changed) -> push!(snaps, LawShop.ups(p))
    rnglaw = normalize_initial(
        (rng) -> LawShop.Shop(nmach, [rand(rng) < 0.5 for _ in 1:nmach]),
    )
    stop = (p, i, e, w) -> i > 25
    pol = RecordMinimal()
    sim = _lawshop_sim(nmach; seed=909, policy=pol, observer=observer)
    ChronoSim.run(sim, rnglaw, stop)
    rec = minimal_record(pol)
    @test rec.initial_state !== nothing

    # The observer saw the initial state once (the init callback) and then one
    # snapshot per firing; the fold must match every one of them.
    @test length(snaps) == length(rec.firings) + 1
    fold = states_at(sim, rec.initial_state, rec)
    @test length(fold) == length(rec.firings) + 1
    @test LawShop.ups(fold[1]) == snaps[1]
    for k in eachindex(rec.firings)
        @test LawShop.ups(fold[k + 1]) == snaps[k + 1]
    end
    # This model's fire! never draws, so the fold is not fire-random.
    @test fold.fire_random == false
end
