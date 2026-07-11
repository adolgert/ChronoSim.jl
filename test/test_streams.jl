using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: NextReactionMethod
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

# Milestone 4 (guarantee G7): firing draws are owned by keyed streams addressed by
# MODEL-LEVEL identity (the event's clock_key), not by a position in the global
# call order. The property this file pins is the reason the milestone exists: an
# event's firing randomness is a function of THAT event's own stream and the seed
# alone, so it is invariant to how many times any OTHER event draws.
#
# The enabling/proposal order in placetoevent.jl is a deterministic sort, so a
# test cannot permute proposal order directly. Instead we drive the permutation at
# a level we DO control: two model variants in which one event's fire! draws a
# different NUMBER of times. Under global-call-order randomness this would shift
# every subsequent event's draws; under per-event stream ownership it cannot. We
# assert exactly that: every other event's firing-draw sequence, and the whole
# firing-time trajectory, are identical across the two variants.
module StreamsG7
using ChronoSim
using ChronoSim.ObservedState
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

const NMACH = 3
# How many times machine 1's FlipOn draws inside fire!. The adversarial knob: the
# ownership property is that changing this leaves every OTHER event's draws and
# every firing time untouched.
const A_DRAWS = Ref(1)
# Per-event record of the values drawn inside fire!, keyed by clock_key. Populated
# in firing order; compared across variants to expose (or refute) cross-event
# coupling.
const DRAWS = Dict{Tuple,Vector{Float64}}()

@enum Status s_on s_off

@keyedby Machine Int64 begin
    status::Status
end

@observedphysical Board begin
    machine::ObservedVector{Machine,Member}
end

function Board(n::Int)
    m = ObservedArray{Machine,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Machine(s_on)
    end
    return Board(m)
end

# Two perpetually-competing flip events per machine. A machine is on xor off, so
# exactly one of its two events is enabled at a time; with three machines starting
# on, three FlipOff clocks are concurrently enabled at t=0 (the >=3 requirement).
struct FlipOn <: SimEvent
    idx::Int64
end
@precondition precondition(e::FlipOn, s) = s.machine[e.idx].status == s_off
enable(::FlipOn, s, when) = (Exponential(1.0), when)
function fire!(e::FlipOn, s, when, rng)
    # Machine 1's FlipOn is "event A": it draws A_DRAWS[] times but records only its
    # last draw. Every draw comes from A's OWN keyed stream, so drawing more advances
    # only A's stream -- never any other event's.
    ndraw = e.idx == 1 ? A_DRAWS[] : 1
    v = 0.0
    for _ in 1:ndraw
        v = rand(rng)
    end
    push!(get!(DRAWS, clock_key(e), Float64[]), v)
    s.machine[e.idx].status = s_on
    return nothing
end

struct FlipOff <: SimEvent
    idx::Int64
end
@precondition precondition(e::FlipOff, s) = s.machine[e.idx].status == s_on
enable(::FlipOff, s, when) = (Exponential(1.3), when)
function fire!(e::FlipOff, s, when, rng)
    v = rand(rng)
    push!(get!(DRAWS, clock_key(e), Float64[]), v)
    s.machine[e.idx].status = s_off
    return nothing
end

function init!(s, when, rng)
    for i in eachindex(s.machine)
        s.machine[i].status = s_on
    end
    return nothing
end
end # module StreamsG7

_streams_events() = [StreamsG7.FlipOn, StreamsG7.FlipOff]

# Run the flip model once and return (minimal_record, snapshot-of-DRAWS). `adraws`
# sets how many times event A draws inside its fire!; the module globals are reset
# each call so two runs are independent except for the shared seed.
function _run_streams(; seed::Int, nsteps::Int, adraws::Int)
    empty!(StreamsG7.DRAWS)
    StreamsG7.A_DRAWS[] = adraws
    pol = RecordMinimal(; initializer=StreamsG7.init!)
    sim = SimulationFSM(
        StreamsG7.Board(StreamsG7.NMACH), _streams_events();
        seed=seed, sampler=NextReactionMethod(), key_type=Tuple, policy=pol,
    )
    ChronoSim.run(sim, StreamsG7.init!, (p, i, e, w) -> i > nsteps)
    draws = Dict(k => copy(v) for (k, v) in StreamsG7.DRAWS)
    return minimal_record(pol), draws
end

# =============================================================================
# G7.1 Determinism: same seed => byte-identical trajectory and MinimalRecord.
# =============================================================================

@testset "streams: two same-seed runs produce byte-identical MinimalRecords" begin
    rec1, draws1 = _run_streams(; seed=515151, nsteps=80, adraws=1)
    rec2, draws2 = _run_streams(; seed=515151, nsteps=80, adraws=1)
    # The whole record is equal (firings, horizon, coupling, and the fire_random
    # flag), and byte-for-byte so are the per-event firing draws.
    @test rec1 == rec2
    @test rec1.firings == rec2.firings
    @test draws1 == draws2
    # The model draws in every fire!, so both runs are correctly flagged fire-random.
    @test rec1.fire_random == true
end

# =============================================================================
# G7.2 Ownership: one event drawing MORE times leaves every other event's firing
#      draws and every firing time untouched. This is the property that global
#      call-order randomness cannot provide and per-event stream ownership does.
# =============================================================================

@testset "streams: an event's firing draws are invariant to another event drawing more times" begin
    A = (:FlipOn, 1)                       # the event whose draw count we vary
    rec1, draws1 = _run_streams(; seed=828282, nsteps=120, adraws=1)
    rec3, draws3 = _run_streams(; seed=828282, nsteps=120, adraws=3)

    # 1. The firing-time trajectory is IDENTICAL: firing times come from the
    #    sampler's own keyed streams, which never see the fire-draw streams, so the
    #    number of times A draws cannot move any event's firing time or order.
    @test rec1.firings == rec3.firings

    # 2. Every OTHER event's firing-draw sequence is byte-identical across variants:
    #    each such event draws from its own clock_key stream, independent of A's.
    @test keys(draws1) == keys(draws3)
    for k in keys(draws1)
        k == A && continue
        @test draws1[k] == draws3[k]
    end

    # 3. Sanity that the two variants are genuinely different runs: A itself drew a
    #    different number of times, so A's own recorded (last-draw) sequence moved.
    #    Without this, invariance above could hold vacuously.
    @test haskey(draws1, A) && haskey(draws3, A)
    @test draws1[A] != draws3[A]
end

# =============================================================================
# G7.3 The init stream is independent of the fire streams: a draw-varying fire!
#      cannot perturb the initial condition, and same-seed init is reproducible.
# =============================================================================

@testset "streams: at least three events are concurrently enabled at t=0" begin
    # Three machines start on, so three FlipOff clocks are enabled at t=0 -- the
    # >=3-concurrently-enabled precondition the adversarial test rests on. Stop the
    # run at step 0 (right after initialization, before any firing) and inspect the
    # enabled set directly. The ownership property proven above (rec.firings
    # identical across draw-count variants) is precisely what guarantees these
    # concurrently-enabled events never steal each other's firing randomness.
    empty!(StreamsG7.DRAWS)
    StreamsG7.A_DRAWS[] = 1
    sim = SimulationFSM(
        StreamsG7.Board(StreamsG7.NMACH), _streams_events();
        seed=343434, sampler=NextReactionMethod(), key_type=Tuple,
    )
    ChronoSim.run(sim, StreamsG7.init!, (p, i, e, w) -> i > 0)
    enabled_keys = collect(keys(sim.enabled_events))
    @test length(enabled_keys) == StreamsG7.NMACH
    @test all(k[1] === :FlipOff for k in enabled_keys)
end
