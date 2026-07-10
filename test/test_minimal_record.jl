using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: NextReactionMethod
using Distributions
using ForwardDiff
using Random
using Logging: Logging
import ChronoSim: precondition, generators, enable, fire!

# A draw-free machines model: each machine alternates working <-> broken under two
# perpetually-competing exponential clocks. `fire!` only flips a status field and
# never touches `rng`, so the trajectory is a pure function of the initial
# condition and the sampler's random stream -- the setting where the pure-replay
# effect check must hold with EXACT Float64 equality.
module MinMachines
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

const FAIL_RATE = 1.5
const REPAIR_RATE = 2.5

@enum Status working broken

@keyedby Machine Int64 begin
    status::Status
end

@observedphysical Shop begin
    machine::ObservedVector{Machine,Member}
end

function Shop(n::Int)
    m = ObservedArray{Machine,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Machine(working)
    end
    return Shop(m)
end

struct Fail <: SimEvent
    idx::Int64
end
@precondition precondition(e::Fail, s) = s.machine[e.idx].status == working
enable(::Fail, s, when) = (Exponential(1 / FAIL_RATE), when)
fire!(e::Fail, s, when, rng) = (s.machine[e.idx].status = broken; nothing)

struct Repair <: SimEvent
    idx::Int64
end
@precondition precondition(e::Repair, s) = s.machine[e.idx].status == broken
enable(::Repair, s, when) = (Exponential(1 / REPAIR_RATE), when)
fire!(e::Repair, s, when, rng) = (s.machine[e.idx].status = working; nothing)

function init!(s, when, rng)
    for i in eachindex(s.machine)
        s.machine[i].status = working
    end
    return nothing
end
end # module

# The same shop, but Repair's `fire!` draws a random number from `rng`. The draw
# does not change which state transition happens, yet it advances the shared rng,
# so the framework must flag the run fire-random: the recorded firing sequence is
# no longer a deterministic function of the initial condition alone.
module MinMachinesDraw
using ChronoSim
using ChronoSim.ObservedState
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

const FAIL_RATE = 1.5
const REPAIR_RATE = 2.5

@enum Status working broken

@keyedby Machine Int64 begin
    status::Status
end

@observedphysical Shop begin
    machine::ObservedVector{Machine,Member}
end

function Shop(n::Int)
    m = ObservedArray{Machine,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Machine(working)
    end
    return Shop(m)
end

struct Fail <: SimEvent
    idx::Int64
end
@precondition precondition(e::Fail, s) = s.machine[e.idx].status == working
enable(::Fail, s, when) = (Exponential(1 / FAIL_RATE), when)
fire!(e::Fail, s, when, rng) = (s.machine[e.idx].status = broken; nothing)

struct Repair <: SimEvent
    idx::Int64
end
@precondition precondition(e::Repair, s) = s.machine[e.idx].status == broken
enable(::Repair, s, when) = (Exponential(1 / REPAIR_RATE), when)
function fire!(e::Repair, s, when, rng)
    rand(rng)                       # the offending draw: harmless value, real rng advance
    s.machine[e.idx].status = working
    return nothing
end

function init!(s, when, rng)
    for i in eachindex(s.machine)
        s.machine[i].status = working
    end
    return nothing
end
end # module

# --- helpers -----------------------------------------------------------------

_machines_events() = [MinMachines.Fail, MinMachines.Repair]

function _run_minimal(n::Int; seed::Int, initializer=MinMachines.init!)
    pol = RecordMinimal(; initializer=initializer)
    sim = SimulationFSM(
        MinMachines.Shop(2), _machines_events();
        rng=Xoshiro(seed), sampler=NextReactionMethod(), key_type=Tuple,
        step_likelihood=true, policy=pol,
    )
    stop = (p, i, e, w) -> i > n
    ChronoSim.run(sim, initializer, stop)
    return sim, pol
end

# =============================================================================
# 6a. CountingRNG counts every draw style, byte-identically to the inner rng.
# =============================================================================

@testset "minimal: CountingRNG reproduces the inner stream and counts a plain rand" begin
    a = Xoshiro(12345)
    b = CountingRNG(Xoshiro(12345))
    # Same seed must yield the same draw, because the proxy only observes.
    @test rand(a) == rand(b)
    @test b.count == 1
end

@testset "minimal: CountingRNG counts a ranged integer draw" begin
    a = Xoshiro(999)
    b = CountingRNG(Xoshiro(999))
    @test rand(a, 1:6) == rand(b, 1:6)
    @test b.count >= 1        # a rejection-sampled range may consume >1 native word
end

@testset "minimal: CountingRNG counts a normal draw" begin
    a = Xoshiro(7)
    b = CountingRNG(Xoshiro(7))
    @test randn(a) == randn(b)
    @test b.count >= 1
end

@testset "minimal: CountingRNG counts a draw from a Distributions distribution" begin
    a = Xoshiro(2024)
    b = CountingRNG(Xoshiro(2024))
    @test rand(a, Exponential(2.0)) == rand(b, Exponential(2.0))
    c1 = b.count
    @test c1 >= 1
    @test rand(a, Categorical([0.2, 0.3, 0.5])) == rand(b, Categorical([0.2, 0.3, 0.5]))
    @test b.count > c1        # the second distribution draw advanced the count again
end

@testset "minimal: CountingRNG leaves the underlying state identical after a mixed sequence" begin
    a = Xoshiro(555)
    b = CountingRNG(Xoshiro(555))
    for _ in 1:20
        rand(a); rand(b)
        randn(a); randn(b)
        rand(a, 1:1000); rand(b, 1:1000)
        rand(a, Gamma(2.0, 3.0)); rand(b, Gamma(2.0, 3.0))
    end
    # If the proxy reproduced the stream exactly, the inner Xoshiro ended in the
    # same state as the bare one -- otherwise later sampler draws would diverge.
    @test a == b.rng
    @test b.count > 0
end

# =============================================================================
# 6b. Draw-free model: the pure-replay effect check passes with EXACT equality.
# =============================================================================

@testset "minimal: a draw-free run is not flagged fire-random" begin
    sim, _ = _run_minimal(40; seed=424242)
    @test sim.fire_random == false
end

@testset "minimal: effect_check reproduces the forward log-likelihood exactly for a draw-free model" begin
    sim, pol = _run_minimal(40; seed=424242)
    # A fresh, independent sim with the SAME model and step_likelihood=true.
    factory = () -> SimulationFSM(
        MinMachines.Shop(2), _machines_events();
        seed=1, sampler=NextReactionMethod(), key_type=Tuple, step_likelihood=true,
    )
    res = effect_check(factory, MinMachines.init!, pol)
    @test res.applicable
    @test res.passed
    @test res.forward === res.replay        # exact Float64 identity, not ≈
    @test isfinite(res.forward)
    @test res.evaluation.feasible
    @test res.evaluation.steps_evaluated == length(minimal_record(pol).firings)
end

@testset "minimal: forward_loglikelihood equals the replayed trace likelihood exactly" begin
    sim, pol = _run_minimal(30; seed=99)
    rec = minimal_record(pol)
    evalsim = SimulationFSM(
        MinMachines.Shop(2), _machines_events();
        seed=2, sampler=NextReactionMethod(), key_type=Tuple, step_likelihood=true,
    )
    ev = trace_likelihood(evalsim, MinMachines.init!, rec)
    @test ev.loglikelihood === forward_loglikelihood(pol)
end

# =============================================================================
# 6c. A model whose fire! draws: the FSM flags it and consumers warn.
# =============================================================================

@testset "minimal: the FSM flags a run whose fire! draws randomness" begin
    pol = RecordMinimal(; initializer=MinMachinesDraw.init!)
    sim = SimulationFSM(
        MinMachinesDraw.Shop(2), [MinMachinesDraw.Fail, MinMachinesDraw.Repair];
        rng=Xoshiro(31337), sampler=NextReactionMethod(), key_type=Tuple,
        step_likelihood=true, policy=pol,
    )
    stop = (p, i, e, w) -> i > 40
    ChronoSim.run(sim, MinMachinesDraw.init!, stop)
    @test sim.fire_random == true
    @test minimal_record(pol).fire_random == true
end

@testset "minimal: consuming a fire-random record via trace_likelihood warns" begin
    pol = RecordMinimal(; initializer=MinMachinesDraw.init!)
    sim = SimulationFSM(
        MinMachinesDraw.Shop(2), [MinMachinesDraw.Fail, MinMachinesDraw.Repair];
        rng=Xoshiro(31337), sampler=NextReactionMethod(), key_type=Tuple,
        step_likelihood=true, policy=pol,
    )
    stop = (p, i, e, w) -> i > 40
    ChronoSim.run(sim, MinMachinesDraw.init!, stop)
    rec = minimal_record(pol)
    evalsim = SimulationFSM(
        MinMachinesDraw.Shop(2), [MinMachinesDraw.Fail, MinMachinesDraw.Repair];
        seed=1, sampler=NextReactionMethod(), key_type=Tuple, step_likelihood=true,
    )
    # match_mode=:any: trace evaluation may also emit an @info on exhaustion.
    @test_logs (:warn,) match_mode = :any trace_likelihood(evalsim, MinMachinesDraw.init!, rec)
end

@testset "minimal: effect_check reports not-applicable and warns on a fire-random record" begin
    pol = RecordMinimal(; initializer=MinMachinesDraw.init!)
    sim = SimulationFSM(
        MinMachinesDraw.Shop(2), [MinMachinesDraw.Fail, MinMachinesDraw.Repair];
        rng=Xoshiro(31337), sampler=NextReactionMethod(), key_type=Tuple,
        step_likelihood=true, policy=pol,
    )
    stop = (p, i, e, w) -> i > 40
    ChronoSim.run(sim, MinMachinesDraw.init!, stop)
    factory = () -> SimulationFSM(
        MinMachinesDraw.Shop(2), [MinMachinesDraw.Fail, MinMachinesDraw.Repair];
        seed=1, sampler=NextReactionMethod(), key_type=Tuple, step_likelihood=true,
    )
    local res
    @test_logs (:warn,) match_mode = :any begin
        res = effect_check(factory, MinMachinesDraw.init!, pol)
    end
    @test res.applicable == false
    @test res.passed == false
end

# =============================================================================
# 6d. The skeleton projection equals the record captured directly by the policy.
# =============================================================================

@testset "minimal: projecting a skeleton yields the same record the policy captured" begin
    seed = 20260709
    horizon = 12.5
    initid = MinMachines.init!

    # Run once recording the rich skeleton.
    skelpol = RecordSkeleton()
    sim1 = SimulationFSM(
        MinMachines.Shop(2), _machines_events();
        rng=Xoshiro(seed), sampler=NextReactionMethod(), key_type=Tuple, policy=skelpol,
    )
    stop = (p, i, e, w) -> i > 35
    ChronoSim.run(sim1, initid, stop)
    skel = recorded_skeleton(skelpol)

    # Run again at the same seed recording the minimal record directly. The model
    # is draw-free, so the two trajectories are identical (same seed, same code).
    minpol = RecordMinimal(; initializer=initid)
    sim2 = SimulationFSM(
        MinMachines.Shop(2), _machines_events();
        rng=Xoshiro(seed), sampler=NextReactionMethod(), key_type=Tuple,
        step_likelihood=true, policy=minpol,
    )
    ChronoSim.run(sim2, initid, stop)

    from_skeleton = minimal_record(
        skel; horizon=horizon, initializer=initid, fire_random=false,
    )
    from_policy = minimal_record(minpol; horizon=horizon)
    @test from_skeleton.firings == from_policy.firings
    @test from_skeleton == from_policy
end

# =============================================================================
# 6e. Horizon-aware (finite-horizon censored) trace evaluation (milestone 7).
# =============================================================================

# A perpetually-enabled exponential race with an Any-typed RATES Ref so a Float64
# and a Dual θ both reach enable() (matching the AD race in the docs). Both clocks
# stay enabled throughout and each firing re-proposes its own clock, so the censored
# likelihood has a closed form checkable by hand.
module CensorRace
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

const RATES = Ref{NTuple{2,Any}}((2.0, 3.0))

@keyedby Cell Int64 begin
    a::Int64
    b::Int64
end

@observedphysical Board begin
    cell::ObservedVector{Cell,Member}
end

function Board(n::Int)
    cells = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = Cell(0, 0)
    end
    return Board(cells)
end

struct FireA <: SimEvent
    idx::Int64
end
@precondition precondition(e::FireA, s) = s.cell[e.idx].a >= 0
enable(::FireA, s, when) = (Exponential(1 / RATES[][1]), when)
fire!(e::FireA, s, when, rng) = (s.cell[e.idx].a += 1; nothing)

struct FireB <: SimEvent
    idx::Int64
end
@precondition precondition(e::FireB, s) = s.cell[e.idx].b >= 0
enable(::FireB, s, when) = (Exponential(1 / RATES[][2]), when)
fire!(e::FireB, s, when, rng) = (s.cell[e.idx].b += 1; nothing)

function init!(s, when, rng)
    s.cell[1].a = 0
    s.cell[1].b = 0
    return nothing
end
end # module CensorRace

# A hand-constructed two-event trace: FireA at t1, FireB at t2, horizon T > t2.
const _CR_T1 = 0.4
const _CR_T2 = 0.9
const _CR_T = 2.0

_censor_record() = MinimalRecord(
    CensorRace.init!,
    Tuple{Tuple,Float64}[((:FireA, 1), _CR_T1), ((:FireB, 1), _CR_T2)],
    _CR_T, :redraw, false,
)

function _censor_sim(θ=(2.0, 3.0); L::DataType=Float64)
    CensorRace.RATES[] = θ
    return SimulationFSM(
        CensorRace.Board(1), [CensorRace.FireA, CensorRace.FireB];
        seed=7, sampler=NextReactionMethod(), key_type=Tuple,
        step_likelihood=true, likelihood_eltype=L,
    )
end

@testset "minimal: the horizon-censored likelihood of a two-event exponential race matches the hand-computed value" begin
    λA, λB = 2.0, 3.0
    rec = _censor_record()

    # Uncensored, both clocks always enabled: each gap contributes winner density x
    # loser survival, and the survival exponents telescope to the LAST event t2:
    #   log λA + log λB - (λA + λB) t2.
    plain = trace_likelihood(_censor_sim((λA, λB)), CensorRace.init!, rec)
    @test plain.feasible
    @test plain.loglikelihood ≈ log(λA) + log(λB) - (λA + λB) * _CR_T2

    # Censoring to horizon T adds each still-enabled clock's survival from t2 to T,
    # telescoping the exponent the rest of the way out to T:
    #   log λA + log λB - (λA + λB) T.
    censored = trace_likelihood(_censor_sim((λA, λB)), CensorRace.init!, rec; censor=true)
    @test censored.loglikelihood ≈ log(λA) + log(λB) - (λA + λB) * _CR_T
    # The tail is exactly the survival over (t2, T] for both clocks.
    @test censored.loglikelihood - plain.loglikelihood ≈ -(λA + λB) * (_CR_T - _CR_T2)
end

@testset "minimal: censoring_loglikelihood returns the survival tail from the last event to the horizon" begin
    λA, λB = 2.0, 3.0
    rec = _censor_record()
    sim = _censor_sim((λA, λB))
    ev = trace_likelihood(sim, CensorRace.init!, rec)   # positions sim at t2
    @test ev.feasible
    @test censoring_loglikelihood(sim, rec.horizon) ≈ -(λA + λB) * (_CR_T - _CR_T2)
    # At horizon == last event the tail is exactly zero (no interval to survive).
    @test censoring_loglikelihood(sim, sim.when) == 0.0
    # A horizon before the last event is a caller error, not a silent negative time.
    @test_throws ArgumentError censoring_loglikelihood(sim, sim.when - 0.1)
end

@testset "minimal: ForwardDiff through the horizon-censored likelihood matches the analytic score" begin
    rec = _censor_record()
    # censored = log λA + log λB - (λA + λB) T, with one FireA and one FireB, so the
    # score is d/dλk = n_k/λk - T -- the horizon T replaces the last event time that
    # the uncensored score n_k/λk - t_N would use. That difference is the whole point.
    censored_loglik(θ) =
        trace_likelihood(_censor_sim((θ[1], θ[2]); L=eltype(θ)), CensorRace.init!, rec;
            censor=true).loglikelihood
    g = ForwardDiff.gradient(censored_loglik, [2.0, 3.0])
    @test g ≈ [1 / 2.0 - _CR_T, 1 / 3.0 - _CR_T]
    CensorRace.RATES[] = (2.0, 3.0)   # leave the Ref primal for any later use
end

@testset "minimal: horizon censoring is opt-in so the default record likelihood and effect check are unchanged" begin
    # The M1 pure-replay effect check compares forward accumulation (which has no
    # censoring term) against replay; the horizon opt-in must not touch the default
    # path, so the default record likelihood stays byte-identical to the forward run.
    sim, pol = _run_minimal(30; seed=99)
    tlast = minimal_record(pol).horizon
    H = tlast + 5.0
    rec = minimal_record(pol; horizon=H)

    factory = () -> SimulationFSM(
        MinMachines.Shop(2), _machines_events();
        seed=2, sampler=NextReactionMethod(), key_type=Tuple, step_likelihood=true,
    )
    plain = trace_likelihood(factory(), MinMachines.init!, rec)
    @test plain.loglikelihood === forward_loglikelihood(pol)   # exact, unchanged

    censored = trace_likelihood(factory(), MinMachines.init!, rec; censor=true)
    # Two clocks are always enabled in the fail/repair shop, so surviving past the
    # last event to H costs strictly positive hazard: the censored number is smaller.
    @test censored.loglikelihood < plain.loglikelihood
    # And it equals the default likelihood plus the standalone tail on the same sim.
    s3 = factory()
    p3 = trace_likelihood(s3, MinMachines.init!, rec)
    @test censored.loglikelihood ≈ p3.loglikelihood + censoring_loglikelihood(s3, H)
end
