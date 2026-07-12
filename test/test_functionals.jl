using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks: NextReactionMethod
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!, isimmediate

# A draw-free machines model WITH an immediate event, so the fold's composite
# step is exercised: `Fail` bumps `nbroken` and the immediate `Tally` fires
# inline to catch `ntallied` up. "Fire Fail(i)" therefore means the whole
# composite change (design doc Section 4), and the fold must reproduce it.
module FnShop
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!, isimmediate

@enum Status working broken

@keyedby Machine Int64 begin
    status::Status
    nbroken::Int64
    ntallied::Int64
end

@observedphysical Shop begin
    machine::ObservedVector{Machine,Member}
end

function Shop(n::Int)
    m = ObservedArray{Machine,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Machine(working, 0, 0)
    end
    return Shop(m)
end

struct Fail <: SimEvent
    idx::Int64
end
@precondition precondition(e::Fail, s) = s.machine[e.idx].status == working
enable(::Fail, s, when) = (Exponential(1 / 1.5), when)
function fire!(e::Fail, s, when, rng)
    s.machine[e.idx].status = broken
    s.machine[e.idx].nbroken += 1
    return nothing
end

struct Repair <: SimEvent
    idx::Int64
end
@precondition precondition(e::Repair, s) = s.machine[e.idx].status == broken
enable(::Repair, s, when) = (Exponential(1 / 2.5), when)
fire!(e::Repair, s, when, rng) = (s.machine[e.idx].status = working; nothing)

# The immediate event: its precondition goes false once it fires, so it runs
# exactly once per break, inline within the breaking firing's step.
struct Tally <: SimEvent
    idx::Int64
end
isimmediate(::Type{Tally}) = true
@precondition precondition(e::Tally, s) =
    s.machine[e.idx].nbroken > s.machine[e.idx].ntallied
fire!(e::Tally, s, when, rng) = (s.machine[e.idx].ntallied += 1; nothing)

function init!(s, when, rng)
    for i in eachindex(s.machine)
        s.machine[i].status = working
    end
    return nothing
end

nbroken_now(s) = count(s.machine[i].status == broken for i in eachindex(s.machine))
end # module FnShop

# The same shop where Repair's `fire!` DRAWS and the draw lands in the state
# (`quality = rand(rng)`), so reproducing the fold field-for-field requires the
# fold to rebuild the identical per-clock firing streams — a value-less draw
# would make the reproduction check vacuous.
module FnShopDraw
using ChronoSim
using ChronoSim.ObservedState
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

@enum Status working broken

@keyedby Machine Int64 begin
    status::Status
    quality::Float64
end

@observedphysical Shop begin
    machine::ObservedVector{Machine,Member}
end

function Shop(n::Int)
    m = ObservedArray{Machine,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Machine(working, 1.0)
    end
    return Shop(m)
end

struct Fail <: SimEvent
    idx::Int64
end
@precondition precondition(e::Fail, s) = s.machine[e.idx].status == working
enable(::Fail, s, when) = (Exponential(1 / 1.5), when)
fire!(e::Fail, s, when, rng) = (s.machine[e.idx].status = broken; nothing)

struct Repair <: SimEvent
    idx::Int64
end
@precondition precondition(e::Repair, s) = s.machine[e.idx].status == broken
enable(::Repair, s, when) = (Exponential(1 / 2.5), when)
function fire!(e::Repair, s, when, rng)
    # The offending draw carries into the state, so a fold that fails to
    # reproduce the stream shows up as a field mismatch, not just a flag.
    s.machine[e.idx].quality = rand(rng)
    s.machine[e.idx].status = working
    return nothing
end

function init!(s, when, rng)
    for i in eachindex(s.machine)
        s.machine[i].status = working
    end
    return nothing
end
end # module FnShopDraw

# --- helpers -----------------------------------------------------------------

# Field-for-field equality on the test models' machine records, read through
# getproperty (tracked reads are harmless on snapshots).
function _fnshop_equal(a, b)
    length(a.machine) == length(b.machine) || return false
    return all(
        a.machine[i].status == b.machine[i].status &&
        a.machine[i].nbroken == b.machine[i].nbroken &&
        a.machine[i].ntallied == b.machine[i].ntallied
        for i in eachindex(a.machine)
    )
end

function _fnshopdraw_equal(a, b)
    length(a.machine) == length(b.machine) || return false
    return all(
        a.machine[i].status == b.machine[i].status &&
        a.machine[i].quality === b.machine[i].quality   # exact Float64 identity
        for i in eachindex(a.machine)
    )
end

# Run a forward trajectory capturing, through the observer, the realized
# initial state, the (when, clock_key) trace, and a post-firing snapshot clone
# per step -- the reference the fold must reproduce.
function _observed_run(shop, events, init!; seed, nsteps)
    initial = Ref{Any}(nothing)
    trace = Tuple{Float64,Tuple}[]
    snapshots = Any[]
    observer = (p, when, evt, changed) -> begin
        if evt isa ChronoSim.InitializeEvent
            initial[] = clone(p)
        else
            push!(trace, (when, clock_key(evt)))
            push!(snapshots, clone(p))
        end
        return nothing
    end
    pol = RecordMinimal(; initializer=init!)
    sim = SimulationFSM(
        shop, events;
        seed=seed, sampler=NextReactionMethod(), key_type=Tuple,
        observer=observer, policy=pol,
    )
    ChronoSim.run(sim, init!, (p, i, e, w) -> i > nsteps)
    return (sim=sim, pol=pol, initial=initial[], trace=trace, snapshots=snapshots)
end

# An initialized (but not yet run) FnShop sim plus a clone of its realized
# initial state, for folding hand-built traces.
function _fnshop_initialized(; seed)
    sim = SimulationFSM(
        FnShop.Shop(2), [FnShop.Fail, FnShop.Repair, FnShop.Tally];
        seed=seed, sampler=NextReactionMethod(), key_type=Tuple,
    )
    ChronoSim.initialize!(ChronoSim.InitializeEvent(), FnShop.init!, sim)
    return sim, clone(sim.physical)
end

# Fail(1)@0.5, Fail(2)@1.2, Repair(1)@2.0: broken-count level is 0, 1, 2, 1.
_hand_trace() = Tuple{Float64,Tuple}[
    (0.5, (:Fail, 1)), (1.2, (:Fail, 2)), (2.0, (:Repair, 1)),
]

@testset "functionals: states_at reproduces the forward run's state snapshots exactly, so the fold is the same delta the engine applied" begin
    run = _observed_run(
        FnShop.Shop(2), [FnShop.Fail, FnShop.Repair, FnShop.Tally], FnShop.init!;
        seed=20260711, nsteps=25,
    )
    @test length(run.trace) >= 25
    # The immediate Tally really ran inline during the forward run; otherwise
    # this test would not exercise the fold's composite (cascade) step.
    @test any(s.machine[i].ntallied > 0 for s in run.snapshots for i in 1:2)

    fold = states_at(run.sim, run.initial, run.trace)
    @test fold isa StateFold
    @test length(fold) == length(run.trace) + 1     # initial state is element 1
    @test fold.fire_random == false
    @test _fnshop_equal(fold[1], run.initial)
    @test all(_fnshop_equal(fold[k + 1], run.snapshots[k]) for k in eachindex(run.snapshots))

    # The MinimalRecord form transposes the record's (clock, when) firings into
    # the same fold.
    rec = minimal_record(run.pol)
    recfold = states_at(run.sim, run.initial, rec)
    @test length(recfold) == length(fold)
    @test all(_fnshop_equal(recfold[k], fold[k]) for k in eachindex(fold))
end

@testset "functionals: an integrated occupancy over the fold matches the hand-integrated piecewise-constant value on a three-event hand-checked trajectory" begin
    sim, initial = _fnshop_initialized(; seed=42)
    trace = _hand_trace()
    fn = IntegratedOccupancy(FnShop.nbroken_now)
    # Levels between firings: 0 on [0,0.5), 1 on [0.5,1.2), 2 on [1.2,2.0),
    # 1 on [2.0,3.0]. Hand integral: 0(.5) + 1(.7) + 2(.8) + 1(1.0) = 3.3.
    byhand = 0.0 * 0.5 + 1.0 * 0.7 + 2.0 * 0.8 + 1.0 * 1.0

    fold = states_at(sim, initial, trace)
    times = [t for (t, k) in trace]
    @test value(fn, fold, times, 3.0) ≈ byhand atol = 1e-12
    # The convenience form folds and reads times off the trace itself.
    @test value(fn, sim, initial, trace; horizon=3.0) ≈ byhand atol = 1e-12

    # The window contract is loud, not silent: an occupancy needs a finite
    # horizon at or after the last firing.
    @test_throws ArgumentError value(fn, fold, times, 1.0)
    @test_throws ArgumentError value(fn, fold, times, Inf)
end

@testset "functionals: a first-passage functional returns the recorded firing time of the hitting step and throws when the trajectory never hits" begin
    sim, initial = _fnshop_initialized(; seed=43)
    trace = _hand_trace()
    # Both machines are first simultaneously broken right after the second
    # firing, so the hitting time is that firing's recorded time.
    hits = FirstPassageTime(s -> FnShop.nbroken_now(s) == 2)
    @test value(hits, sim, initial, trace) == 1.2
    # Two machines can never yield three broken: a clear error, not a sentinel.
    never = FirstPassageTime(s -> FnShop.nbroken_now(s) >= 3)
    @test_throws ArgumentError value(never, sim, initial, trace)
end

@testset "functionals: states_at flags a trajectory whose fire! drew randomness and reproduces it anyway when the same seeds are supplied" begin
    run = _observed_run(
        FnShopDraw.Shop(2), [FnShopDraw.Fail, FnShopDraw.Repair], FnShopDraw.init!;
        seed=31337, nsteps=30,
    )
    @test run.sim.fire_random == true
    # At least one Repair fired, so at least one drawn quality is in the state.
    @test any(k[1] === :Repair for (t, k) in run.trace)

    fold = states_at(run.sim, run.initial, run.trace)
    @test fold.fire_random == true
    # The fold rebuilt the per-clock fire streams from the sim's master seed, so
    # every drawn quality reproduces bit-for-bit against the forward snapshots.
    @test _fnshopdraw_equal(fold[1], run.initial)
    @test all(_fnshopdraw_equal(fold[k + 1], run.snapshots[k]) for k in eachindex(run.snapshots))
end
