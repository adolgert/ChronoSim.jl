using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: NextReactionMethod
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

# The DYNAMIC-CAPTURE audit tier of guarantee G1 (coverage.jl). These two models
# are identical EXCEPT in how the `Trip` event declares its read dependencies. In
# both, `Trip` fires when a cell is armed AND powered, so its precondition reads
# two fields: `armed` and `power`.
#
#  * GoodLatch declares `Trip` with `@precondition`, which DERIVES a spec covering
#    both reads -- read verification passes.
#  * BadLatch declares `Trip` by hand: a `@conditionsfor` generator that reacts only
#    to `armed`, and a manual `derivation_spec` covering only `armed`. The
#    precondition still reads `power`, so the DECLARATION is under-covered. Because
#    the generator over-proposes on every `armed` change, the run is still CORRECT
#    -- the under-coverage is silent -- which is exactly the drift read verification
#    exists to expose loudly.

module GoodLatch
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

@keyedby Cell Int64 begin
    armed::Int64
    power::Int64
end

@observedphysical Panel begin
    cell::ObservedVector{Cell,Member}
end

function Panel(n::Int)
    cells = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = Cell(0, 1)
    end
    return Panel(cells)
end

# Reads BOTH armed and power; @precondition derives a spec covering both.
struct Trip <: SimEvent
    idx::Int64
end
@precondition function precondition(e::Trip, s)
    c = s.cell[e.idx]
    return c.armed > 0 && c.power > 0
end
enable(::Trip, s, when) = (Exponential(1.0), when)
fire!(e::Trip, s, when, rng) = (s.cell[e.idx].armed = 0; nothing)

struct Arm <: SimEvent
    idx::Int64
end
@precondition precondition(e::Arm, s) = s.cell[e.idx].armed == 0
enable(::Arm, s, when) = (Exponential(1.0), when)
fire!(e::Arm, s, when, rng) = (s.cell[e.idx].armed = 1; nothing)

function init!(s, when, rng)
    for i in eachindex(s.cell)
        s.cell[i].armed = 0
        s.cell[i].power = 1
    end
    return nothing
end
end # module GoodLatch

module BadLatch
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

@keyedby Cell Int64 begin
    armed::Int64
    power::Int64
end

@observedphysical Panel begin
    cell::ObservedVector{Cell,Member}
end

function Panel(n::Int)
    cells = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = Cell(0, 1)
    end
    return Panel(cells)
end

# PLAIN precondition (no @precondition macro): reads BOTH armed and power.
struct Trip <: SimEvent
    idx::Int64
end
precondition(e::Trip, s) = s.cell[e.idx].armed > 0 && s.cell[e.idx].power > 0
enable(::Trip, s, when) = (Exponential(1.0), when)
fire!(e::Trip, s, when, rng) = (s.cell[e.idx].armed = 0; nothing)

# Hand-written generator reacting ONLY to `armed`: it over-proposes (so the run
# stays correct) but the model never declares that Trip also depends on `power`.
@conditionsfor Trip begin
    @reactto changed(cell[i].armed) do s
        generate(Trip(i))
    end
end

# Manual derivation_spec covering ONLY `armed` -- the declaration that drifts from
# the precondition, which also reads `power`. Only `matchstr` is consulted by the
# oracle, so `indices` is left empty (matching the coverage-test fixtures).
function ChronoSim.derivation_spec(::Type{Trip})
    ChronoSim.ReadSpec[ChronoSim.ReadSpec(
        Any[Member(:cell), ChronoSim.MEMBERINDEX, Member(:armed)], Any[], "hand-armed-only",
    )]
end

struct Arm <: SimEvent
    idx::Int64
end
@precondition precondition(e::Arm, s) = s.cell[e.idx].armed == 0
enable(::Arm, s, when) = (Exponential(1.0), when)
fire!(e::Arm, s, when, rng) = (s.cell[e.idx].armed = 1; nothing)

function init!(s, when, rng)
    for i in eachindex(s.cell)
        s.cell[i].armed = 0
        s.cell[i].power = 1
    end
    return nothing
end
end # module BadLatch

_good_sim() = SimulationFSM(
    GoodLatch.Panel(1), [GoodLatch.Arm, GoodLatch.Trip];
    rng=Xoshiro(4242), sampler=NextReactionMethod(), key_type=Tuple,
)
_bad_sim() = SimulationFSM(
    BadLatch.Panel(1), [BadLatch.Arm, BadLatch.Trip];
    rng=Xoshiro(4242), sampler=NextReactionMethod(), key_type=Tuple,
)

# =============================================================================
# The verify-mode API: off by default, scoped, and round-trips.
# =============================================================================

@testset "verify: read verification is off by default" begin
    # A production run must pay nothing and assert nothing unless asked.
    @test ChronoSim.read_verification_enabled() == false
end

@testset "verify: the enable/disable pair toggles the audit and restores cleanly" begin
    @test ChronoSim.read_verification_enabled() == false
    ChronoSim.enable_read_verification!()
    try
        @test ChronoSim.read_verification_enabled() == true
    finally
        ChronoSim.disable_read_verification!()
    end
    @test ChronoSim.read_verification_enabled() == false
end

@testset "verify: with_read_verification restores the prior state even on error" begin
    # Whatever the block does, the toggle it flipped must not leak to later tests.
    @test ChronoSim.read_verification_enabled() == false
    @test_throws ErrorException ChronoSim.with_read_verification(() -> error("boom"))
    @test ChronoSim.read_verification_enabled() == false
end

# =============================================================================
# The two-tier demonstration: a correct model passes; an under-declared model
# errors loudly under verification yet runs silently without it.
# =============================================================================

@testset "verify: a correctly-declared model runs to completion under read verification" begin
    sim = _good_sim()
    stop = (p, i, e, w) -> i > 20
    ChronoSim.with_read_verification() do
        ChronoSim.run(sim, GoodLatch.init!, stop)
    end
    @test sim.when > 0.0
    @test ChronoSim.read_verification_enabled() == false   # scope restored
end

@testset "verify: an under-declared read throws a loud DerivationCoverageError under verification" begin
    sim = _bad_sim()
    stop = (p, i, e, w) -> i > 20
    err = ChronoSim.with_read_verification() do
        @test_throws ChronoSim.DerivationCoverageError ChronoSim.run(sim, BadLatch.init!, stop)
    end
    e = err.value
    @test e.event_type === BadLatch.Trip
    # The uncovered place is the `power` read the declaration omits, and the message
    # names both the event and the field so the failure points at the drift.
    msg = sprint(showerror, e)
    @test occursin("Trip", msg)
    @test occursin("power", string(e.address)) || occursin("power", msg)
    @test ChronoSim.read_verification_enabled() == false   # scope restored despite throw
end

@testset "verify: the same under-declared model runs silently without verification" begin
    # The silent-wrongness demonstration in miniature: identical model and seed,
    # no error, a full trajectory -- the drift is invisible without the audit.
    sim = _bad_sim()
    stop = (p, i, e, w) -> i > 20
    @test ChronoSim.read_verification_enabled() == false
    ChronoSim.run(sim, BadLatch.init!, stop)   # must NOT throw
    @test sim.when > 0.0
end
