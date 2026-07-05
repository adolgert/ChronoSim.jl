using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

# The in-repo ElevatorExample (test/elevator.jl) has only hand-written generators
# (no derivation_spec), so it exercises the "skip" path of the oracle but cannot
# exercise a violation. This tiny @precondition-derived model gives the oracle and
# the counters a model with real derivation_specs to check against.
module TinyDerived
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: CombinedNextReaction
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

@enum Phase idle active

@keyedby Cell Int64 begin
    phase::Phase
    fuel::Int64
end

@observedphysical Board begin
    cell::ObservedVector{Cell,Member}
end

function Board(n::Int)
    cells = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = Cell(idle, 3)
    end
    return Board(cells)
end

# Two clean reads bind idx -> triggers [cell, ℤ, phase] and [cell, ℤ, fuel]; the
# fuel trigger over-approximates (proposes Wake on a fuel change that leaves phase
# non-idle), which the precondition then filters.
struct Wake <: SimEvent
    idx::Int64
end
@precondition function precondition(evt::Wake, state)
    c = state.cell[evt.idx]
    return c.phase == idle && c.fuel > 0
end
enable(::Wake, state, when) = (Exponential(1.0), when)
function fire!(evt::Wake, state, when, rng)
    state.cell[evt.idx].phase = active
    return nothing
end

struct Sleep <: SimEvent
    idx::Int64
end
@precondition precondition(evt::Sleep, state) = state.cell[evt.idx].phase == active
enable(::Sleep, state, when) = (Exponential(1.0), when)
function fire!(evt::Sleep, state, when, rng)
    state.cell[evt.idx].phase = idle
    state.cell[evt.idx].fuel -= 1
    return nothing
end

# Writing every cell's fields inside the initialize! callback registers changes so
# the derived generators propose the initial Wake candidates.
function initialize!(state, rng)
    for i in eachindex(state.cell)
        state.cell[i].fuel = 3
        state.cell[i].phase = idle
    end
    return nothing
end

function run_tiny(; seed=12345, ncell=3)
    physical = Board(ncell)
    sim = SimulationFSM(
        physical, [Wake, Sleep]; rng=Xoshiro(seed), sampler=CombinedNextReaction{Tuple,Float64}()
    )
    init = (p, when, rng) -> initialize!(p, rng)
    # No time bound is needed: the model exhausts its fuel and stops on its own.
    stop = (p, i, e, w) -> w > 1.0e9
    ChronoSim.run(sim, init, stop)
    return sim
end

end # module TinyDerived

############################ Broken-spec fixtures ############################

# A read whose container IS named by the (wrong) spec but at a different shape:
# the spec stops at the element level [cell, ℤ] while the real read is a leaf
# [cell, ℤ, phase]. Classified :shape_mismatch.
struct BrokenShape <: SimEvent
    idx::Int64
end
function ChronoSim.derivation_spec(::Type{BrokenShape})
    ChronoSim.ReadSpec[ChronoSim.ReadSpec(
        Any[Member(:cell), ChronoSim.MEMBERINDEX], Any[], "deliberately-wrong-shape"
    )]
end

# A spec that names a container the precondition never touches: the real read's
# top field :cell appears in no spec. Classified :missing_field.
struct BrokenMissing <: SimEvent
    idx::Int64
end
function ChronoSim.derivation_spec(::Type{BrokenMissing})
    ChronoSim.ReadSpec[ChronoSim.ReadSpec(
        Any[Member(:ghost), ChronoSim.MEMBERINDEX, Member(:x)], Any[], "deliberately-wrong-field"
    )]
end

_capture_wake_reads() = begin
    board = TinyDerived.Board(3)
    rr = ChronoSim.capture_state_reads(board) do
        ChronoSim.precondition(TinyDerived.Wake(1), board)
    end
    rr.reads
end

############################ Tests ############################

@testset "coverage oracle passes over a full run of a derived model" begin
    ChronoSim.check_derivation_coverage(true)
    try
        sim = TinyDerived.run_tiny(; seed=101)
        @test sim.when > 0.0
    finally
        ChronoSim.check_derivation_coverage(false)
    end
end

@testset "coverage oracle admits the correct derivation_spec for captured reads" begin
    reads = _capture_wake_reads()
    @test !isempty(reads)
    @test ChronoSim.verify_read_coverage(TinyDerived.Wake, reads) === nothing
end

@testset "coverage oracle classifies a wrong-shape spec as a shape mismatch" begin
    reads = _capture_wake_reads()
    err = @test_throws ChronoSim.DerivationCoverageError ChronoSim.verify_read_coverage(
        BrokenShape, reads
    )
    @test err.value.classification === :shape_mismatch
    msg = sprint(showerror, err.value)
    @test occursin("BrokenShape", msg)
    @test occursin("shape_mismatch", msg)
end

@testset "coverage oracle classifies an unmentioned container as a missing field" begin
    reads = _capture_wake_reads()
    err = @test_throws ChronoSim.DerivationCoverageError ChronoSim.verify_read_coverage(
        BrokenMissing, reads
    )
    @test err.value.classification === :missing_field
    msg = sprint(showerror, err.value)
    @test occursin("missing_field", msg)
end

@testset "coverage oracle skips events without a derivation_spec" begin
    # A hand-written event (no derivation_spec) must pass regardless of reads.
    reads = _capture_wake_reads()
    @test ChronoSim.verify_read_coverage(ChronoSim.InitializeEvent, reads) === nothing
end

@testset "coverage metric: generation stats count proposed >= admitted > 0 and reset clears them" begin
    ChronoSim.reset_generation_stats!()
    ChronoSim.collect_generation_stats(true)
    try
        TinyDerived.run_tiny(; seed=202)
    finally
        ChronoSim.collect_generation_stats(false)
    end
    stats = ChronoSim.generation_stats()
    @test !isempty(stats)
    total_admitted = 0
    for (_T, c) in stats
        @test c.proposed >= c.admitted
        total_admitted += c.admitted
    end
    @test total_admitted > 0
    @test haskey(stats, :Wake)
    @test stats[:Wake].admitted > 0
    ChronoSim.reset_generation_stats!()
    @test isempty(ChronoSim.generation_stats())
end

@testset "coverage metric: generation stats stay empty when collection is disabled by default" begin
    ChronoSim.collect_generation_stats(false)
    ChronoSim.reset_generation_stats!()
    TinyDerived.run_tiny(; seed=303)
    @test isempty(ChronoSim.generation_stats())
end
