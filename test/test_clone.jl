using ReTest
using ChronoSim
using ChronoSim.ObservedState
using ChronoSim.ObservedState: verify_clone
using CompetingClocks
using CompetingClocks: NextReactionMethod, clone, force_fire!, next, rekey_streams!
using Distributions
using Random

# The elevator is the richest physical fixture (ObservedVector of @keyedby
# Persons/Elevators, an ObservedDict of ElevatorCalls, and a plain Set inside a
# @keyedby Elevator). test_elevator.jl already includes it; guard so we do not
# redefine the module when this file happens to load first.
isdefined(@__MODULE__, :ElevatorExample) || include("elevator.jl")

# ---------------------------------------------------------------------------
# Fixtures. A rich physical state exercising every container kind for
# verify_clone, and a Weibull machines model (fire! draws, >=2 concurrent
# clocks, non-exponential schedule) for the re-entrancy and force_fire! tests.
# ---------------------------------------------------------------------------
module CloneModels
using ChronoSim, ChronoSim.ObservedState, Distributions, Random
import ChronoSim: precondition, enable, fire!, generators

# --- rich state for verify_clone -------------------------------------------
@keyedby CloneCell Tuple{Int,Int} begin
    load::Int
end
@keyedby CloneWidget Int begin
    level::Float64
    label::String
    knobs::Set{Int}          # plain mutable Set inside an addressed element
end
@observedphysical CloneWorld begin
    widgets::ObservedVector{CloneWidget,Member}                 # array of @keyedby
    cells::ObservedDict{Tuple{Int,Int},CloneCell,Member}        # dict of @keyedby
    floors::ObservedVector{ObservedSet{Symbol,Int},Member}      # array of ObservedSet (nested address)
    flags::ObservedSet{Symbol,Member}                           # top-level ObservedSet
    counter::Int64                                              # plain primitive
    config::Param{Dict{Symbol,Float64}}                        # Param config field
end

function make_world()
    widgets = ObservedArray{CloneWidget,Member}(undef, 3)
    for i in 1:3
        widgets[i] = CloneWidget(Float64(i), "w$i", Set{Int}([i, i + 10]))
    end
    cells = ObservedDict{Tuple{Int,Int},CloneCell,Member}()
    cells[(1, 1)] = CloneCell(5)
    cells[(2, 3)] = CloneCell(7)
    floors = ObservedArray{ObservedSet{Symbol,Int},Member}(undef, 2)
    floors[1] = ObservedSet{Symbol,Int}(Set([:a, :b]))
    floors[2] = ObservedSet{Symbol,Int}(Set([:c]))
    flags = ObservedSet{Symbol,Member}(Set([:x, :y]))
    return CloneWorld(widgets, cells, floors, flags, 42, Dict(:rate => 1.5))
end

# --- Weibull machines model ------------------------------------------------
@keyedby CloneMachine Int begin
    working::Bool
    repairs::Int    # deterministic bookkeeping
    severity::Int   # set from a fire! draw, so fire_streams state matters
end
@observedphysical CloneShop begin
    machine::ObservedVector{CloneMachine,Member}
end
function CloneShop(n::Int)
    m = ObservedArray{CloneMachine,Member}(undef, n)
    for i in eachindex(m)
        m[i] = CloneMachine(false, 0, 0)
    end
    return CloneShop(m)
end

struct MachineBreak <: SimEvent
    id::Int
end
struct MachineRepair <: SimEvent
    id::Int
end

@conditionsfor MachineBreak begin
    @reactto changed(machine[id].working) do s
        generate(MachineBreak(id))
    end
end
@conditionsfor MachineRepair begin
    @reactto changed(machine[id].working) do s
        generate(MachineRepair(id))
    end
end

precondition(e::MachineBreak, s) = s.machine[e.id].working
precondition(e::MachineRepair, s) = !s.machine[e.id].working
# Non-exponential clocks, so the sampler carries real per-clock schedule state.
enable(::MachineBreak, s, when) = (Weibull(1.5, 2.0), when)
enable(::MachineRepair, s, when) = (Weibull(2.0, 1.0), when)

function fire!(e::MachineBreak, s, when, rng)
    m = s.machine[e.id]
    m.working = false
    m.severity = rand(rng, 1:5)   # draws -> fire-stream state matters to the continuation
    return nothing
end
function fire!(e::MachineRepair, s, when, rng)
    m = s.machine[e.id]
    m.working = true
    m.repairs += 1
    m.severity = 0
    return nothing
end

init_shop!(s, when, rng) = (for i in eachindex(s.machine); s.machine[i].working = true; end; nothing)

end # module CloneModels

using .CloneModels: CloneModels

# ---------------------------------------------------------------------------
# Test helpers.
# ---------------------------------------------------------------------------
_shop_events() = [CloneModels.MachineBreak, CloneModels.MachineRepair]

function build_shop(n, seed)
    physical = CloneModels.CloneShop(n)
    sim = SimulationFSM(physical, _shop_events(); seed=seed)
    ChronoSim.initialize!(InitializeEvent(), CloneModels.init_shop!, sim)
    return sim
end

# Step by drawing from the sampler, recording (when, clock_key), until the next
# event would pass the horizon. Mirrors the forward executor's loop.
function step_to!(sim, horizon; record=nothing)
    while true
        (when, what) = next(sim.sampler)
        (isfinite(when) && !isnothing(what)) || break
        when > horizon && break
        fire!(sim, when, what)
        record !== nothing && push!(record, (when, what))
    end
    return sim
end

function scratch_enabled(physical, n)
    expected = Set{Tuple{Symbol,Int}}()
    for i in 1:n
        precondition(CloneModels.MachineBreak(i), physical) && push!(expected, (:MachineBreak, i))
        precondition(CloneModels.MachineRepair(i), physical) && push!(expected, (:MachineRepair, i))
    end
    return expected
end

_key_set(sim) = Set(keys(sim.enabled_events))

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

@testset "clone: verify_clone passes on a rich multi-container physical state" begin
    # The rich fixture exercises an ObservedVector of @keyedby elements, an
    # ObservedDict of @keyedby elements, an ObservedVector of ObservedSet, a
    # top-level ObservedSet, a plain Set inside an element, a plain primitive,
    # and a Param field -- every container kind the clone walk must handle.
    world = CloneModels.make_world()
    twin = clone(world)
    ok, diags = verify_clone(world, twin)
    @test ok
    @test isempty(diags)
end

@testset "clone: verify_clone passes on the elevator physical after a run" begin
    # The elevator populates buttons_pressed (a plain Set inside a @keyedby
    # Elevator) and person/elevator/call state, so this checks the clone on a
    # realistically-populated instance of the project's canonical fixture.
    physical = ElevatorExample.ElevatorSystem(2, 1, 3)
    events = [
        ElevatorExample.PickNewDestination, ElevatorExample.CallElevator,
        ElevatorExample.OpenElevatorDoors, ElevatorExample.EnterElevator,
        ElevatorExample.ExitElevator, ElevatorExample.CloseElevatorDoors,
        ElevatorExample.MoveElevator, ElevatorExample.StopElevator,
        ElevatorExample.DispatchElevator,
    ]
    sim = SimulationFSM(physical, events; rng=Xoshiro(0xB0A710))
    ChronoSim.run(sim, ElevatorExample.init_physical,
        (p, i, e, w) -> w > 40.0)
    ok, diags = verify_clone(sim.physical, clone(sim.physical))
    @test ok
    @test isempty(diags)
end

@testset "clone: a tracked write on the clone never notifies the original's buffers" begin
    # The notify-isolation property in isolation: after cloning, a write through
    # the observed API on the clone must land only in the clone's obs_modified.
    world = CloneModels.make_world()
    twin = clone(world)
    empty!(getfield(world, :obs_modified))
    empty!(getfield(twin, :obs_modified))
    # A compound-element field write on the clone.
    twin.widgets[1].level = 99.0
    @test !isempty(getfield(twin, :obs_modified))
    @test isempty(getfield(world, :obs_modified))
    @test world.widgets[1].level == 1.0    # original value untouched
end

@testset "clone: the clone's tracking buffers start empty" begin
    # A clone is taken between firings, so it must carry no pending captures.
    world = CloneModels.make_world()
    twin = clone(world)
    @test isempty(getfield(twin, :obs_modified))
    @test isempty(getfield(twin, :obs_read))
end

@testset "clone: a coupled clone continues bit-identically to the original" begin
    # G2 re-entrancy acceptance. Weibull clocks and >=2 concurrent machines, so
    # both the sampler schedule and the fire streams must be carried.
    n = 4
    horizon = 60.0
    t1 = 5.0
    seed = 0x5EED01

    sim = build_shop(n, seed)
    pre = Tuple{Float64,Any}[]
    step_to!(sim, t1; record=pre)

    coupled = clone(sim)          # (b) coupled continuation
    diverge = clone(sim)          # (c) divergence sanity

    cont_orig = Tuple{Float64,Any}[]
    step_to!(sim, horizon; record=cont_orig)

    cont_coupled = Tuple{Float64,Any}[]
    step_to!(coupled, horizon; record=cont_coupled)

    # (b) The clone shares the original's stream state at the clone point, so the
    # continuations are the same world: same firings, same times, same state.
    @test cont_coupled == cont_orig
    @test ChronoSim.ObservedState._state_equal(sim.physical, coupled.physical)
    @test length(cont_orig) > 5   # the continuation is nontrivial

    # (c) Re-keying the clone reseeds every stream family, so once a clock is
    # re-drawn the continuation diverges -- proof the coupling was real.
    rekey_streams!(diverge, 0xD1F0)
    cont_div = Tuple{Float64,Any}[]
    step_to!(diverge, horizon; record=cont_div)
    @test cont_div != cont_orig

    # (d) An uninterrupted same-seed run reproduces the original's full
    # trajectory, so taking the clone perturbed nothing.
    sim_full = build_shop(n, seed)
    full = Tuple{Float64,Any}[]
    step_to!(sim_full, horizon; record=full)
    @test full == vcat(pre, cont_orig)
end

@testset "clone: a mid-flight Weibull clone reserves the same next firing as the original" begin
    # The sampler's per-clock Weibull schedule state must survive the clone: the
    # very next reservation on the clone equals the original's.
    sim = build_shop(3, 0xA5A5)
    step_to!(sim, 4.0)
    twin = clone(sim)
    @test next(sim.sampler) == next(twin.sampler)
end

@testset "clone: forcing the natural next event equals the natural step" begin
    # Driving next() then force_fire! at exactly that (event, time) reproduces
    # the natural firing: identical resulting state and enabled set.
    sim = build_shop(4, 0x1234)
    step_to!(sim, 6.0)
    a = clone(sim)
    b = clone(sim)
    (when, what) = next(a.sampler)
    fire!(a, when, what)
    force_fire!(b, what, when)
    @test ChronoSim.ObservedState._state_equal(a.physical, b.physical)
    @test _key_set(a) == _key_set(b)
end

@testset "clone: forcing a different event yields a consistent, correctly-enabled world" begin
    # force_fire! runs the chosen transition through the natural state-update
    # path, so the resulting enabled set matches a from-scratch precondition scan.
    n = 4
    sim = build_shop(n, 0x9F9F)
    step_to!(sim, 6.0)
    c = clone(sim)
    (when, what) = next(c.sampler)
    # Pick a different enabled event to force.
    other = first(k for k in keys(c.enabled_events) if k != what)
    force_fire!(c, other, when)   # checksim inside _fire! asserts consistency
    @test _key_set(c) == scratch_enabled(c.physical, n)
end

@testset "clone: force_fire! rejects a disabled event or a past time" begin
    sim = build_shop(3, 0x2222)
    step_to!(sim, 4.0)
    (when, what) = next(sim.sampler)
    # A past time is rejected.
    @test_throws ArgumentError force_fire!(sim, what, sim.when - 1.0)
    # A key that is not enabled is rejected. Repair of a working machine is not
    # enabled at this point unless it broke; find one guaranteed disabled key.
    disabled = first(
        k for k in ((:MachineBreak, i) for i in 1:3) ∪ ((:MachineRepair, i) for i in 1:3)
        if !haskey(sim.enabled_events, k))
    @test_throws ArgumentError force_fire!(sim, disabled, sim.when + 1.0)
end
