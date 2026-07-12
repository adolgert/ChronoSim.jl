using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: NextReactionMethod, FirstReactionMethod
using Distributions
using Random
import ChronoSim: precondition, generators, enable, reenable, fire!, memory_policy

# =============================================================================
# Guarantee G6: the re-evaluation coupling and the memory policy. These are two
# different kinds of declaration and they live in two different places:
#
#   * The re-evaluation COUPLING ∈ {:carry (default), :redraw} is a property of
#     HOW A SAMPLER GENERATES ITS NUMBERS, so it is chosen once, at sampler
#     construction, via `NextReactionMethod(coupling=...)` or
#     `FirstToFireMethod(coupling=...)`. When a still-enabled event's rate
#     dependencies change and `reenable` supplies a new distribution, :carry maps
#     the retained draw through the change by matching conditional survival
#     (consuming no randomness; the only IPA-safe coupling, and a bit-for-bit
#     no-op for an unchanged distribution), while :redraw discards the retained
#     draw and draws the remaining lifetime fresh conditioned on age. Both
#     produce the same law. The default :carry is the scheduling backends'
#     historical silent behavior.
#
#   * memory_policy(EventType) ∈ {:fresh (default), :resume} stays a per-EVENT
#     declaration because it is a distributional statement about the model: when
#     an event is disabled and later re-enabled, :fresh restarts its clock from
#     age zero while :resume banks the accumulated age across the disable and
#     conditions the re-enabling draw on it. Memory only shows up for a
#     NON-exponential clock.
#
# The tests below pin: (a) a model with no declarations produces the exact
# pre-change trajectory, and a default-constructed FSM is bit-identical to one
# built with an explicit coupling=:carry sampler; (b) the declarations and the
# sampler coupling accessor report the expected values; (c) :carry with an
# identical distribution is a structural no-op while :redraw is not; (d) the
# :resume and :fresh laws each match their own exact quadrature oracle and
# differ from each other; (e) the M1 effect check stays EXACTLY Float64-equal
# under either coupling with a resume cycle in the same run; (f) the record is
# labeled with the sampler's coupling; (g) requesting :carry from a sampler that
# cannot carry errors at construction.
# =============================================================================

# -----------------------------------------------------------------------------
# (a) The golden model: a draw-free machines shop with NO G6 declarations. Used to
#     pin that the defaults reproduce the exact pre-change trajectory.
# -----------------------------------------------------------------------------
module DeclGolden
using ChronoSim, ChronoSim.ObservedState, Distributions
import ChronoSim: precondition, generators, enable, fire!
@enum Status working broken
@keyedby Machine Int64 begin
    status::Status
end
@observedphysical Shop begin
    machine::ObservedVector{Machine,Member}
end
function Shop(n::Int)
    m = ObservedArray{Machine,Member}(undef, n)
    for i in eachindex(m); m[i] = Machine(working); end
    Shop(m)
end
struct Fail <: SimEvent; idx::Int64; end
@precondition precondition(e::Fail, s) = s.machine[e.idx].status == working
enable(::Fail, s, when) = (Exponential(1 / 1.5), when)
fire!(e::Fail, s, when, rng) = (s.machine[e.idx].status = broken; nothing)
struct Repair <: SimEvent; idx::Int64; end
@precondition precondition(e::Repair, s) = s.machine[e.idx].status == broken
enable(::Repair, s, when) = (Exponential(1 / 2.5), when)
fire!(e::Repair, s, when, rng) = (s.machine[e.idx].status = working; nothing)
init!(s, when, rng) = (for i in eachindex(s.machine); s.machine[i].status = working; end; nothing)
end # module

# -----------------------------------------------------------------------------
# (b) The re-evaluation model. A `Worker` runs a NON-exponential (Weibull)
#     completion clock whose `enable` reads a tick counter, so every `Tick` firing
#     re-evaluates the worker with an IDENTICAL distribution. The worker's
#     `reenable` returns the ORIGINAL enabling time (`firstenabled`), which is what
#     KEEPS the clock's age across the re-evaluation -- the case in which :carry is
#     a bit-for-bit no-op and :redraw is not. Which coupling a run uses is chosen
#     by the SAMPLER it is built with, not by anything in this model.
# -----------------------------------------------------------------------------
module Reeval
using ChronoSim, ChronoSim.ObservedState, Distributions
import ChronoSim: precondition, generators, enable, reenable, fire!
@enum WS active wdone
@keyedby Cell Int64 begin
    st::WS
    ticks::Int64
end
@observedphysical Board begin
    cell::ObservedVector{Cell,Member}
end
function Board(n::Int)
    m = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(m); m[i] = Cell(wdone, 0); end
    Board(m)
end
struct Worker <: SimEvent; idx::Int64; end
@precondition precondition(e::Worker, s) = s.cell[e.idx].st == active
# Reading `.ticks` establishes it as a rate dependency; the returned distribution
# is INDEPENDENT of the tick value, so every re-evaluation is an identical Weibull.
function enable(e::Worker, s, when)
    _ = s.cell[e.idx].ticks
    (Weibull(1.4, 2.0), when)
end
# Returning `fe` (the original enabling time) keeps the clock's age; this is the
# age-preserving re-evaluation under which :carry leaves the schedule unchanged.
reenable(e::Worker, s, fe, t) = (first(enable(e, s, t)), fe)
fire!(e::Worker, s, when, rng) = (s.cell[e.idx].st = wdone; nothing)
struct Tick <: SimEvent; idx::Int64; end
@precondition precondition(e::Tick, s) = s.cell[e.idx].st == active
enable(e::Tick, s, when) = (Exponential(1 / 3.0), when)
fire!(e::Tick, s, when, rng) = (s.cell[e.idx].ticks += 1; nothing)
init!(s, when, rng) = (s.cell[1].st = active; s.cell[1].ticks = 0; nothing)
end # module

# Run the re-evaluation model and return (worker firing time, the RecordMinimal
# policy that observed the run). Absent Tick from `events`, the worker is never
# re-evaluated -- the baseline against which the coupling behaviors are measured.
# `sampler=nothing` builds the default-constructed FSM; otherwise the given spec
# chooses the coupling.
function _reeval_worker_time(Mod, events; seed, sampler=nothing)
    wt = Ref(-1.0)
    obs = (p, w, e, c) -> (e isa Mod.Worker) ? (wt[] = w) : nothing
    pol = RecordMinimal(; initializer=Mod.init!)
    sim = SimulationFSM(
        Mod.Board(1), events;
        rng=Xoshiro(seed), sampler=sampler, key_type=Tuple, observer=obs, policy=pol,
    )
    ChronoSim.run(sim, Mod.init!, (p, i, e, w) -> w > 50.0)
    return wt[], pol
end

# -----------------------------------------------------------------------------
# (c) The pausable-job model, ported in shape from WorldTimer's VasScore
#     pausable_job. A single Weibull job can be interrupted at most once: `Pause`
#     disables the completion clock mid-flight and `Resume` re-enables it. Under
#     `memory_policy == :resume` the completion clock's age is carried across the
#     pause; under `:fresh` the work is lost and the job restarts. The two
#     completion event types differ ONLY in that declaration, so a run selects the
#     policy by choosing which completion event enters the event list.
# -----------------------------------------------------------------------------
module Pausable
using ChronoSim, ChronoSim.ObservedState, Distributions
import ChronoSim: precondition, generators, enable, fire!, memory_policy
const SHAPE = 1.6
const PAUSE_RATE = 0.7
const RESUME_RATE = 1.1
@enum Phase running paused jdone
@keyedby Job Int64 begin
    phase::Phase
    budget::Int64
end
@observedphysical World begin
    job::ObservedVector{Job,Member}
end
function World(n::Int)
    m = ObservedArray{Job,Member}(undef, n)
    for i in eachindex(m); m[i] = Job(jdone, 0); end
    World(m)
end
# Weibull completion, θ[1] is the scale; the two variants differ only in memory.
struct CompleteResume <: SimEvent; idx::Int64; end
@precondition precondition(e::CompleteResume, s) = s.job[e.idx].phase == running
enable(e::CompleteResume, s, θ, when) = (Weibull(SHAPE, θ[1]), when)
memory_policy(::Type{CompleteResume}) = :resume
fire!(e::CompleteResume, s, when, rng) = (s.job[e.idx].phase = jdone; nothing)
struct CompleteFresh <: SimEvent; idx::Int64; end
@precondition precondition(e::CompleteFresh, s) = s.job[e.idx].phase == running
enable(e::CompleteFresh, s, θ, when) = (Weibull(SHAPE, θ[1]), when)
memory_policy(::Type{CompleteFresh}) = :fresh
fire!(e::CompleteFresh, s, when, rng) = (s.job[e.idx].phase = jdone; nothing)
# One-shot pause: consumes the budget so it cannot pause a second time.
struct Pause <: SimEvent; idx::Int64; end
@precondition precondition(e::Pause, s) = s.job[e.idx].phase == running && s.job[e.idx].budget > 0
enable(e::Pause, s, when) = (Exponential(1 / PAUSE_RATE), when)
fire!(e::Pause, s, when, rng) = (s.job[e.idx].phase = paused; s.job[e.idx].budget -= 1; nothing)
struct Resume <: SimEvent; idx::Int64; end
@precondition precondition(e::Resume, s) = s.job[e.idx].phase == paused
enable(e::Resume, s, when) = (Exponential(1 / RESUME_RATE), when)
fire!(e::Resume, s, when, rng) = (s.job[e.idx].phase = running; nothing)
init!(s, when, rng) = (s.job[1].phase = running; s.job[1].budget = 1; nothing)
end # module

# One-dimensional trapezoidal quadrature (no external dependency): the test env
# does not carry QuadGK, and a fine grid is accurate to well under the Monte-Carlo
# standard error at this sample size.
function _trap(f, a, b, n)
    h = (b - a) / n
    s = 0.5 * (f(a) + f(b))
    for i in 1:(n - 1)
        s += f(a + i * h)
    end
    return s * h
end

# Exact P(job completes ≤ T) for the pausable job, from WorldTimer's oracle. With
# `d` the Weibull service, `dp` the pause clock, `dr` the resume clock:
#   :resume -- carried age composes the two service pieces into one total
#     requirement τ ~ d; a pause before τ merely inserts the resume delay:
#       P = ∫₀ᵀ pdf(d,τ)[ccdf(dp,τ) + cdf(dp,τ) cdf(dr, T−τ)] dτ
#   :fresh -- the interrupted work is lost and a NEW draw runs after the resume:
#       P = ∫₀ᵀ pdf(d,τ) ccdf(dp,τ) dτ
#         + ∫₀ᵀ pdf(dp,s) ccdf(d,s) ∫₀^{T−s} pdf(dr,r) cdf(d, T−s−r) dr ds
function _pause_completion_oracle(policy, θ, T)
    d = Weibull(Pausable.SHAPE, θ[1])
    dp = Exponential(1 / Pausable.PAUSE_RATE)
    dr = Exponential(1 / Pausable.RESUME_RATE)
    if policy === :resume
        return _trap(τ -> pdf(d, τ) * (ccdf(dp, τ) + cdf(dp, τ) * cdf(dr, T - τ)), 0.0, T, 20_000)
    else
        uninterrupted = _trap(τ -> pdf(d, τ) * ccdf(dp, τ), 0.0, T, 20_000)
        restarted = _trap(0.0, T, 2_000) do s
            inner = _trap(r -> pdf(dr, r) * cdf(d, T - s - r), 0.0, max(T - s, 1e-12), 2_000)
            pdf(dp, s) * ccdf(d, s) * inner
        end
        return uninterrupted + restarted
    end
end

# Monte-Carlo P(job completed by T) with its binomial standard error. The
# completion event is the only writer of `jdone`, so the final phase encodes the
# Bernoulli functional exactly.
function _completion_prob(CompleteType, θ, T; nrep, seed0)
    events = [CompleteType, Pausable.Pause, Pausable.Resume]
    base = Xoshiro(seed0)
    hits = 0
    for _ in 1:nrep
        sim = SimulationFSM(
            Pausable.World(1), events; seed=rand(base, UInt64), key_type=Tuple, params=θ,
        )
        ChronoSim.run(sim, Pausable.init!, (p, i, e, w) -> w > T)
        sim.physical.job[1].phase == Pausable.jdone && (hits += 1)
    end
    p = hits / nrep
    return p, sqrt(p * (1 - p) / nrep)
end

# -----------------------------------------------------------------------------
# (d) A combined draw-free model that exercises re-evaluation and memory in one
#     run: two Weibull workers whose clocks are re-evaluated by tick firings
#     (cells 1 and 2) and a :resume disable/re-enable cycle (cell 3). Which
#     coupling the re-evaluations use is the SAMPLER's, so the model is run once
#     under each coupling. Used for the M1 effect check, which must stay EXACTLY
#     Float64-equal.
# -----------------------------------------------------------------------------
module Combined
using ChronoSim, ChronoSim.ObservedState, Distributions
import ChronoSim: precondition, generators, enable, reenable, fire!, memory_policy
@enum WS active wdone
@enum Phase running paused jdone
@keyedby Cell Int64 begin
    wst::WS
    ticks::Int64
    phase::Phase
    budget::Int64
end
@observedphysical Grid begin
    cell::ObservedVector{Cell,Member}
end
function Grid(n::Int)
    m = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(m); m[i] = Cell(wdone, 0, jdone, 0); end
    Grid(m)
end
struct Worker <: SimEvent; idx::Int64; end
@precondition precondition(e::Worker, s) = s.cell[e.idx].wst == active
function enable(e::Worker, s, when); _ = s.cell[e.idx].ticks; (Weibull(1.4, 2.0), when); end
reenable(e::Worker, s, fe, t) = (first(enable(e, s, t)), fe)
fire!(e::Worker, s, when, rng) = (s.cell[e.idx].wst = wdone; nothing)
struct Tick <: SimEvent; idx::Int64; end
@precondition precondition(e::Tick, s) = s.cell[e.idx].wst == active
enable(e::Tick, s, when) = (Exponential(1 / 3.0), when)
fire!(e::Tick, s, when, rng) = (s.cell[e.idx].ticks += 1; nothing)
struct Complete <: SimEvent; idx::Int64; end
@precondition precondition(e::Complete, s) = s.cell[e.idx].phase == running
enable(e::Complete, s, when) = (Weibull(1.6, 1.5), when)
memory_policy(::Type{Complete}) = :resume
fire!(e::Complete, s, when, rng) = (s.cell[e.idx].phase = jdone; nothing)
struct Pause <: SimEvent; idx::Int64; end
@precondition precondition(e::Pause, s) = s.cell[e.idx].phase == running && s.cell[e.idx].budget > 0
enable(e::Pause, s, when) = (Exponential(1 / 0.9), when)
fire!(e::Pause, s, when, rng) = (s.cell[e.idx].phase = paused; s.cell[e.idx].budget -= 1; nothing)
struct Resume <: SimEvent; idx::Int64; end
@precondition precondition(e::Resume, s) = s.cell[e.idx].phase == paused
enable(e::Resume, s, when) = (Exponential(1 / 1.3), when)
fire!(e::Resume, s, when, rng) = (s.cell[e.idx].phase = running; nothing)
function init!(s, when, rng)
    s.cell[1].wst = active; s.cell[1].ticks = 0
    s.cell[2].wst = active; s.cell[2].ticks = 0
    s.cell[3].phase = running; s.cell[3].budget = 1
    return nothing
end
end # module

const COMBINED_EVENTS = [
    Combined.Worker, Combined.Tick,
    Combined.Complete, Combined.Pause, Combined.Resume,
]

# =============================================================================
# (a) The defaults reproduce the pre-change trajectory bit-for-bit, and the
#     default-constructed FSM equals an explicit coupling=:carry FSM.
# =============================================================================

@testset "declare: a model with no G6 declarations produces the exact pre-change trajectory" begin
    # WHY exact literals: this golden trajectory was recorded from the tree BEFORE
    # the G6 declarations existed. The default sampler coupling (:carry) IS the
    # backends' historical silent behavior, the memory default (:fresh) is the
    # historical age handling, and this draw-free machines model triggers no
    # re-evaluation and no resume cycle, so the trajectory must be byte-identical.
    # A re-pin here would signal the defaults silently changed behavior -- exactly
    # what G6 must not do.
    expected = Tuple{Float64,Tuple}[
        (0.4946630986705336, (:Fail, 1)),
        (0.6272601577961257, (:Repair, 1)),
        (0.6453611152510109, (:Fail, 1)),
        (0.7173686753181516, (:Repair, 1)),
        (0.8377088735609275, (:Fail, 2)),
        (1.1184394170896022, (:Repair, 2)),
        (1.707032498877458, (:Fail, 1)),
        (1.8055775913620011, (:Repair, 1)),
        (2.422407833264998, (:Fail, 1)),
        (2.643818291764826, (:Repair, 1)),
        (3.257305654328303, (:Fail, 1)),
        (3.2703969102485746, (:Repair, 1)),
    ]
    trace = Tuple{Float64,Tuple}[]
    obs = (p, w, e, c) -> (e isa ChronoSim.InitializeEvent) ? nothing :
          push!(trace, (w, clock_key(e)))
    sim = SimulationFSM(
        DeclGolden.Shop(3), [DeclGolden.Fail, DeclGolden.Repair];
        rng=Xoshiro(9182734), key_type=Tuple, observer=obs,
    )
    ChronoSim.run(sim, DeclGolden.init!, (p, i, e, w) -> i > 12)
    if VERSION < v"1.13-"
        @test trace == expected
    else
        # The golden literals are a function of Xoshiro(9182734)'s stream on the
        # Julia version where they were recorded (1.12). Julia does not promise
        # random streams stay stable across minor releases, and 1.13 changed the
        # draws, so the exact comparison is only meaningful on the recording
        # version. The next testset carries the behavior-preservation claim in a
        # version-independent form (default FSM == explicit :carry FSM).
        @test_skip trace == expected
    end
end

@testset "declare: a default-constructed FSM is bit-identical to one built with an explicit carry sampler" begin
    # THE behavior-preservation claim of the construction-time coupling: the
    # default sampler coupling is :carry, so a default-constructed FSM must
    # reproduce, bit for bit, an FSM built with sampler=NextReactionMethod(
    # coupling=:carry). The model re-evaluates the worker at every tick, so the
    # coupling genuinely acts during this run -- the identity is not vacuous.
    seed = 20260710
    t_default, pol_default = _reeval_worker_time(
        Reeval, [Reeval.Worker, Reeval.Tick]; seed=seed)
    t_carry, pol_carry = _reeval_worker_time(
        Reeval, [Reeval.Worker, Reeval.Tick]; seed=seed,
        sampler=NextReactionMethod(coupling=:carry))
    @test t_default === t_carry
    @test minimal_record(pol_default) == minimal_record(pol_carry)
    @test minimal_record(pol_default).coupling == :carry
end

@testset "declare: the memory declaration and the sampler coupling report the expected values" begin
    # memory_policy stays a per-event declaration and defaults to the historical
    # :fresh. The re-evaluation coupling lives on the sampler: a default-built
    # simulation carries the scheduling backends' historical :carry, and an
    # explicit coupling=:redraw request is stored and reported by the accessor.
    @test memory_policy(DeclGolden.Fail) == :fresh
    @test memory_policy(Pausable.CompleteResume) == :resume
    @test memory_policy(Pausable.CompleteFresh) == :fresh
    sim_default = SimulationFSM(
        Reeval.Board(1), [Reeval.Worker]; seed=1, key_type=Tuple,
    )
    @test CompetingClocks.coupling(sim_default.sampler) == :carry
    sim_redraw = SimulationFSM(
        Reeval.Board(1), [Reeval.Worker];
        seed=1, sampler=NextReactionMethod(coupling=:redraw), key_type=Tuple,
    )
    @test CompetingClocks.coupling(sim_redraw.sampler) == :redraw
end

# =============================================================================
# (b) :carry with an identical distribution is a structural no-op; :redraw is not.
# =============================================================================

@testset "declare: a :carry re-evaluation with an identical distribution leaves the schedule bit-for-bit unchanged" begin
    # The worker and tick clocks share their random streams across the three runs
    # (same clock keys => same per-clock streams at a common seed). The baseline
    # run omits Tick, so the worker is never re-evaluated. Under a coupling=:carry
    # sampler an age-preserving re-evaluation with an identical Weibull must reuse
    # the retained draw, so the worker fires at EXACTLY the baseline time; under a
    # coupling=:redraw sampler the draw is discarded and the firing time moves.
    seed = 20260710
    t_base, _ = _reeval_worker_time(Reeval, [Reeval.Worker]; seed=seed)
    t_carry, pol_carry = _reeval_worker_time(
        Reeval, [Reeval.Worker, Reeval.Tick]; seed=seed,
        sampler=NextReactionMethod(coupling=:carry))
    t_redraw, _ = _reeval_worker_time(
        Reeval, [Reeval.Worker, Reeval.Tick]; seed=seed,
        sampler=NextReactionMethod(coupling=:redraw))
    @test t_base > 0.0                               # the worker did fire in the baseline
    @test t_carry === t_base                         # carry is a structural no-op (exact)
    @test t_redraw != t_base                         # redraw generally moves the schedule
    # The carry run must actually HAVE re-evaluated (else the no-op is vacuous):
    # the record labels the sampler's coupling and the run saw tick firings.
    @test minimal_record(pol_carry).coupling == :carry
    @test any(f -> f[1][1] == :Tick, minimal_record(pol_carry).firings)
end

# =============================================================================
# (c) The :resume and :fresh laws each match their own exact oracle and differ.
# =============================================================================

@testset "declare: the resume and fresh memory policies each match their own quadrature oracle and differ" begin
    # WHY a Weibull clock: memory is invisible for a memoryless exponential, so the
    # two policies would coincide. With a Weibull service the carried age changes the
    # completion law, and the two oracles are genuinely different -- which the last
    # assertion enforces so the per-policy matches are not vacuous.
    θ = [1.0]
    T = 2.0
    or_resume = _pause_completion_oracle(:resume, θ, T)
    or_fresh = _pause_completion_oracle(:fresh, θ, T)
    p_resume, se_resume = _completion_prob(Pausable.CompleteResume, θ, T; nrep=20_000, seed0=41)
    p_fresh, se_fresh = _completion_prob(Pausable.CompleteFresh, θ, T; nrep=20_000, seed0=42)
    # Standard errors small enough that a 4-SE band is a meaningful test.
    @test se_resume < 0.006
    @test se_fresh < 0.006
    # Each estimate matches its OWN oracle within four standard errors.
    @test abs(p_resume - or_resume) < 4 * se_resume
    @test abs(p_fresh - or_fresh) < 4 * se_fresh
    # The two oracles are distinguishable at this sample size, so the policies are
    # genuinely different laws and the matches above discriminate between them.
    @test abs(or_resume - or_fresh) > 4 * sqrt(se_resume^2 + se_fresh^2)
end

# =============================================================================
# (d) The M1 effect check stays EXACTLY Float64-equal under either coupling.
# =============================================================================

# One seeded run of the combined draw-free model under the given sampler spec:
# tick firings re-evaluate both workers with the sampler's coupling, and cell 3
# runs a :resume pause/resume cycle. Returns the effect-check result, the record,
# and the observed trace.
function _combined_effect_check(; seed, sampler)
    trace = Tuple{Float64,Tuple}[]
    obs = (p, w, e, c) -> (e isa ChronoSim.InitializeEvent) ? nothing :
          push!(trace, (w, clock_key(e)))
    pol = RecordMinimal(; initializer=Combined.init!)
    sim = SimulationFSM(
        Combined.Grid(3), COMBINED_EVENTS;
        seed=seed, sampler=sampler, key_type=Tuple, step_likelihood=true,
        policy=pol, observer=obs,
    )
    ChronoSim.run(sim, Combined.init!, (p, i, e, w) -> w > 30.0)
    factory = () -> SimulationFSM(
        Combined.Grid(3), COMBINED_EVENTS;
        seed=1, sampler=sampler, key_type=Tuple, step_likelihood=true,
    )
    return effect_check(factory, Combined.init!, pol), pol, trace
end

@testset "declare: effect_check stays exactly Float64-equal under carry and redraw with a resume cycle in the run" begin
    # The coupling is one per run now (a sampler property), so the model is run
    # once under each coupling. If the likelihood accounting for a resumed clock's
    # shifted enabling time -- or for either re-evaluation coupling -- were wrong
    # anywhere, forward accumulation and trace replay would diverge and this
    # exact-equality check -- the whole reason M1 exists -- would catch it.
    seed = 999
    for coupling in (:carry, :redraw)
        res, pol, trace = _combined_effect_check(
            seed=seed, sampler=NextReactionMethod(coupling=coupling))
        @test res.applicable
        @test res.passed
        @test res.forward === res.replay          # exact Float64 identity, not ≈
        @test isfinite(res.forward)
        # The record is labeled with THIS run's sampler coupling.
        @test minimal_record(pol).coupling == coupling
        # The run really did traverse both paths: ticks re-evaluated the workers,
        # and a full pause -> resume -> complete cycle happened on the resume clock.
        saw_tick = any(t -> t[2][1] == :Tick, trace)
        saw_pause = any(t -> t[2][1] == :Pause, trace)
        saw_resume = any(t -> t[2][1] == :Resume, trace)
        saw_complete = any(t -> t[2][1] == :Complete, trace)
        @test saw_tick && saw_pause && saw_resume && saw_complete
    end
end

# =============================================================================
# (e) The record's coupling label is the sampler's coupling.
# =============================================================================

@testset "declare: the record labels the run with its sampler's coupling" begin
    # The coupling is a construction-time property of the sampler, so within one
    # run exactly one coupling can act and the record's label is the sampler's --
    # read from the sampler, not tallied per re-evaluation. In particular a run in
    # which NO re-evaluation happened still labels the sampler's coupling, because
    # that is the coupling any re-evaluation WOULD have used. A mixed label is
    # impossible: one sampler, one coupling, one run.
    seed = 20260710
    # No Tick => no re-evaluation ran; the label is still the sampler's coupling.
    _, pol_none = _reeval_worker_time(Reeval, [Reeval.Worker]; seed=seed)
    @test minimal_record(pol_none).coupling == :carry
    _, pol_none_rd = _reeval_worker_time(
        Reeval, [Reeval.Worker]; seed=seed,
        sampler=NextReactionMethod(coupling=:redraw))
    @test minimal_record(pol_none_rd).coupling == :redraw
    # Re-evaluations ran; the label is unchanged: the sampler's coupling.
    _, pol_carry = _reeval_worker_time(
        Reeval, [Reeval.Worker, Reeval.Tick]; seed=seed,
        sampler=NextReactionMethod(coupling=:carry))
    @test minimal_record(pol_carry).coupling == :carry
    _, pol_redraw = _reeval_worker_time(
        Reeval, [Reeval.Worker, Reeval.Tick]; seed=seed,
        sampler=NextReactionMethod(coupling=:redraw))
    @test minimal_record(pol_redraw).coupling == :redraw
end

# =============================================================================
# (f) Requesting :carry from a sampler that cannot carry errors at construction.
# =============================================================================

@testset "declare: requesting carry from a sampler that cannot carry errors at construction naming supports_carry" begin
    # FirstReaction retains no schedule to move continuously in a parameter, so its
    # supports_carry is false and it can only redraw. Requesting coupling=:carry
    # must fail AT CONSTRUCTION -- before any simulation is built, earlier and
    # clearer than the old per-call guard at the re-evaluation site -- with a
    # message that names the capability and the sampler, not a MethodError deep in
    # a backend.
    err = nothing
    try
        CompetingClocks.FirstReaction{Tuple,Float64}(coupling=:carry)
    catch e
        err = e
    end
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin("carry", msg)
    @test occursin("supports_carry", msg)
    @test occursin("FirstReaction", msg)
    # The redraw-only sampler still accepts an explicit :redraw request, and a
    # bogus coupling symbol is rejected by the same construction-time validation.
    @test CompetingClocks.coupling(
        CompetingClocks.FirstReaction{Tuple,Float64}(coupling=:redraw)) == :redraw
    @test_throws ArgumentError NextReactionMethod(coupling=:sideways)
end
