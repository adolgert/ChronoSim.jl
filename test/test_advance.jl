using ReTest
using ChronoSim
using CompetingClocks: next
using Distributions
using Random

# ---------------------------------------------------------------------------
# Fixture: a small Weibull machines model, self-contained like test_clone.jl's.
# Weibull clocks make the sampler carry real per-clock schedule state, and the
# fire! draw makes the fire-stream state matter to any continuation, so a
# bit-for-bit comparison after advance! is a real coupling check, not a
# triviality. The break-only event set gives sampler exhaustion a natural
# endpoint: once every machine is broken, nothing is enabled.
# ---------------------------------------------------------------------------
module AdvanceModels
using ChronoSim, ChronoSim.ObservedState, Distributions, Random
import ChronoSim: precondition, enable, fire!, generators

@keyedby AdvMachine Int begin
    working::Bool
    repairs::Int
    severity::Int
end
@observedphysical AdvShop begin
    machine::ObservedVector{AdvMachine,Member}
end
function AdvShop(n::Int)
    m = ObservedArray{AdvMachine,Member}(undef, n)
    for i in eachindex(m)
        m[i] = AdvMachine(false, 0, 0)
    end
    return AdvShop(m)
end

struct AdvBreak <: SimEvent
    id::Int
end
struct AdvRepair <: SimEvent
    id::Int
end

@conditionsfor AdvBreak begin
    @reactto changed(machine[id].working) do s
        generate(AdvBreak(id))
    end
end
@conditionsfor AdvRepair begin
    @reactto changed(machine[id].working) do s
        generate(AdvRepair(id))
    end
end

precondition(e::AdvBreak, s) = s.machine[e.id].working
precondition(e::AdvRepair, s) = !s.machine[e.id].working
enable(::AdvBreak, s, when) = (Weibull(1.5, 2.0), when)
enable(::AdvRepair, s, when) = (Weibull(2.0, 1.0), when)

function fire!(e::AdvBreak, s, when, rng)
    m = s.machine[e.id]
    m.working = false
    m.severity = rand(rng, 1:5)
    return nothing
end
function fire!(e::AdvRepair, s, when, rng)
    m = s.machine[e.id]
    m.working = true
    m.repairs += 1
    m.severity = 0
    return nothing
end

init_shop!(s, when, rng) =
    (for i in eachindex(s.machine); s.machine[i].working = true; end; nothing)

end # module AdvanceModels

using .AdvanceModels: AdvanceModels

function build_advance_shop(n, seed; events=[AdvanceModels.AdvBreak, AdvanceModels.AdvRepair])
    physical = AdvanceModels.AdvShop(n)
    sim = SimulationFSM(physical, events; seed=seed)
    ChronoSim.initialize!(InitializeEvent(), AdvanceModels.init_shop!, sim)
    return sim
end

# The manual peek-and-fire loop advance! replaces (the hand-rolled pattern in
# estimator code); tie at the horizon fires, matching advance!'s contract.
function manual_advance!(sim, τ; record=nothing)
    while true
        (when, what) = next(sim.sampler)
        (isfinite(when) && !isnothing(what) && when <= τ) || break
        fire!(sim, when, what)
        record !== nothing && push!(record, (when, what))
    end
    return sim
end

@testset "advance: advance! fires exactly the events at or before tau and matches the manual peek-and-fire loop bit for bit" begin
    n = 4
    τ = 7.0
    seed = 0xADA0CE01
    a = build_advance_shop(n, seed)
    b = build_advance_shop(n, seed)
    fired = Tuple{Float64,Any}[]
    manual_advance!(b, τ; record=fired)
    nfired = advance!(a, τ)
    @test nfired == length(fired)
    @test nfired > 3                       # the window is nontrivial
    @test a.when == b.when
    @test a.when <= τ                       # the clock is the last firing, never faked to τ
    @test ChronoSim.ObservedState._state_equal(a.physical, b.physical)
    @test Set(keys(a.enabled_events)) == Set(keys(b.enabled_events))
    # The held reservation is the same event at the same time, and it is the
    # first event STRICTLY after τ (the tie at τ already fired).
    @test next(a.sampler) == next(b.sampler)
    @test next(a.sampler)[1] > τ
end

@testset "advance: advance! split at an intermediate time reproduces a single advance bit for bit, so stopping holds the sampler reservation" begin
    n = 4
    τ1, τ2 = 3.0, 9.0
    seed = 0xADA0CE02
    a = build_advance_shop(n, seed)
    b = build_advance_shop(n, seed)
    n1 = advance!(a, τ1)
    n2 = advance!(a, τ1)                    # τ == sim.when-adjacent re-advance is a no-op
    @test n2 == 0
    n3 = advance!(a, τ2)
    nb = advance!(b, τ2)
    @test n1 + n3 == nb
    @test a.when == b.when
    @test ChronoSim.ObservedState._state_equal(a.physical, b.physical)
    @test next(a.sampler) == next(b.sampler)
end

@testset "advance: advance! returns zero and leaves the simulation intact when no event precedes tau or the sampler is exhausted" begin
    # (a) No event in the window: the reservation, clock, and enabled set are
    # untouched, so a later advance still sees the same world.
    sim = build_advance_shop(3, 0xADA0CE03)
    reservation = next(sim.sampler)
    just_before = reservation[1] - eps(reservation[1])
    @test advance!(sim, just_before) == 0
    @test sim.when == 0.0
    @test next(sim.sampler) == reservation

    # (b) Sampler exhaustion: with break-only events every machine breaks once
    # and then nothing is enabled; advance! stops without error and a further
    # advance fires nothing.
    dead = build_advance_shop(3, 0xADA0CE04; events=[AdvanceModels.AdvBreak])
    @test advance!(dead, 1.0e6) == 3
    @test isempty(dead.enabled_events)
    @test advance!(dead, 2.0e6) == 0
end

@testset "advance: advance! throws when tau precedes the simulation clock" begin
    sim = build_advance_shop(3, 0xADA0CE05)
    advance!(sim, 5.0)
    @test sim.when > 0.0
    @test_throws ArgumentError advance!(sim, sim.when - 1.0)
    # The failed call must not have perturbed the world.
    reservation = next(sim.sampler)
    @test advance!(sim, sim.when) == 0
    @test next(sim.sampler) == reservation
end
