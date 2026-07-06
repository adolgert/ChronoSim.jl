using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

# The verified two-clock exponential race (design Appendix V2). Both clocks are
# perpetually enabled (preconditions are trivially true), so the trajectory is a
# competing exponential race with rates LA and LB. Firing an event increments its
# field, which re-proposes it through its derived generator so the survivor keeps
# running.
module TraceEvalRace
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

const LA = 2.0
const LB = 3.0

@keyedby RaceCell Int64 begin
    a::Int64
    b::Int64
end

@observedphysical RaceBoard begin
    cell::ObservedVector{RaceCell,Member}
end

function RaceBoard(n::Int)
    cells = ObservedArray{RaceCell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = RaceCell(0, 0)
    end
    return RaceBoard(cells)
end

struct FireA <: SimEvent
    idx::Int64
end
@precondition precondition(evt::FireA, state) = state.cell[evt.idx].a >= 0
enable(::FireA, state, when) = (Exponential(1 / LA), when)
fire!(evt::FireA, state, when, rng) = (state.cell[evt.idx].a += 1; nothing)

struct FireB <: SimEvent
    idx::Int64
end
@precondition precondition(evt::FireB, state) = state.cell[evt.idx].b >= 0
enable(::FireB, state, when) = (Exponential(1 / LB), when)
fire!(evt::FireB, state, when, rng) = (state.cell[evt.idx].b += 1; nothing)

function init!(state, when, rng)
    state.cell[1].a = 0
    state.cell[1].b = 0
    return nothing
end
end # module

using .TraceEvalRace: RaceBoard, FireA, FireB, LA, LB

# A one-shot-disable model: FireA runs forever, but FireC can fire only while its
# field `c` is zero (precondition `c == 0`). Once FireC fires, `c` becomes 1, its
# precondition turns false, and it is disabled and never re-enabled. This exercises
# the trace-likelihood survival bookkeeping for a clock that leaves the enabled set
# partway through the trace.
module TraceEvalDisable
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

const DA = 2.0
const DC = 1.5

@keyedby DCell Int64 begin
    a::Int64
    c::Int64
end

@observedphysical DBoard begin
    cell::ObservedVector{DCell,Member}
end

function DBoard(n::Int)
    cells = ObservedArray{DCell,Member}(undef, n)
    for i in eachindex(cells)
        cells[i] = DCell(0, 0)
    end
    return DBoard(cells)
end

struct DFireA <: SimEvent
    idx::Int64
end
@precondition precondition(evt::DFireA, state) = state.cell[evt.idx].a >= 0
enable(::DFireA, state, when) = (Exponential(1 / DA), when)
fire!(evt::DFireA, state, when, rng) = (state.cell[evt.idx].a += 1; nothing)

struct DFireC <: SimEvent
    idx::Int64
end
@precondition precondition(evt::DFireC, state) = state.cell[evt.idx].c == 0
enable(::DFireC, state, when) = (Exponential(1 / DC), when)
fire!(evt::DFireC, state, when, rng) = (state.cell[evt.idx].c += 1; nothing)

function init!(state, when, rng)
    state.cell[1].a = 0
    state.cell[1].c = 0
    return nothing
end
end # module

using .TraceEvalDisable: DBoard, DFireA, DFireC, DA, DC

# Run the forward executor for `n` steps and record the (when, clock_key) trace.
function _race_trace(n::Int; seed::Int)
    trace = Tuple{Float64,Tuple}[]
    observer = (p, when, evt, changed) -> begin
        evt isa ChronoSim.InitializeEvent && return nothing
        push!(trace, (when, clock_key(evt)))
    end
    sim = SimulationFSM(
        RaceBoard(1), [FireA, FireB];
        rng=Xoshiro(seed), key_type=Tuple, observer=observer,
    )
    stop = (p, i, e, w) -> i > n
    ChronoSim.run(sim, TraceEvalRace.init!, stop)
    return trace
end

# A fresh evaluation sim whose SamplingContext records the enabled-clock likelihood.
function _eval_sim()
    return SimulationFSM(
        RaceBoard(1), [FireA, FireB];
        rng=Xoshiro(7), key_type=Tuple, step_likelihood=true,
    )
end

# Evaluation sim for the one-shot-disable model.
function _disable_eval_sim()
    return SimulationFSM(
        DBoard(1), [DFireA, DFireC];
        rng=Xoshiro(7), key_type=Tuple, step_likelihood=true,
    )
end

_analytic(trace) = begin
    na = count(t -> t[2][1] == :FireA, trace)
    nb = count(t -> t[2][1] == :FireB, trace)
    tN = trace[end][1]
    na * log(LA) + nb * log(LB) - (LA + LB) * tN
end

@testset "trace_eval closed form matches analytic" begin
    trace = _race_trace(20; seed=424242)
    ev = trace_likelihood(_eval_sim(), TraceEvalRace.init!, trace)
    @test ev.loglikelihood ≈ _analytic(trace) atol = 1e-10
end

@testset "trace_eval closed form fixed trace" begin
    trace = Tuple{Float64,Tuple}[(0.3, (:FireA, 1)), (0.7, (:FireB, 1)), (1.1, (:FireA, 1))]
    ev = trace_likelihood(_eval_sim(), TraceEvalRace.init!, trace)
    expect = 2 * log(2) + log(3) - 5 * 1.1
    @test ev.loglikelihood ≈ expect atol = 1e-12
end

@testset "trace_eval round trip is feasible" begin
    trace = _race_trace(50; seed=99)
    ev = trace_likelihood(_eval_sim(), TraceEvalRace.init!, trace)
    @test ev.feasible == true
    @test isfinite(ev.loglikelihood)
    @test ev.steps_evaluated == 50
    @test ev.steps_evaluated == length(ev.steploglik)
    @test sum(ev.steploglik; init=0.0) == ev.loglikelihood
    @test ev.first_infeasible === nothing
end

@testset "trace_eval infeasible not_enabled" begin
    trace = _race_trace(20; seed=424242)
    trace[17] = (trace[17][1], (:FireA, 99))
    ev = trace_likelihood(_eval_sim(), TraceEvalRace.init!, trace)
    @test ev.loglikelihood == -Inf
    @test ev.feasible == false
    @test ev.first_infeasible == (17, (:FireA, 99), :not_enabled)
    @test ev.steps_evaluated == 16
end

@testset "trace_eval infeasible time_order" begin
    trace = _race_trace(20; seed=424242)
    k = 10
    key_k = trace[k][2]
    trace[k] = (trace[k - 1][1], key_k)   # equal time pins the strictness
    ev = trace_likelihood(_eval_sim(), TraceEvalRace.init!, trace)
    @test ev.first_infeasible == (k, key_k, :time_order)
    @test ev.loglikelihood == -Inf
    @test ev.steps_evaluated == k - 1
end

@testset "trace_eval empty trace" begin
    ev = trace_likelihood(_eval_sim(), TraceEvalRace.init!, Tuple{Float64,Tuple}[])
    @test ev.feasible == true
    @test ev.loglikelihood == 0.0
    @test ev.steps_evaluated == 0
end

@testset "trace_eval show verdict block" begin
    trace = _race_trace(20; seed=424242)
    trace[17] = (trace[17][1], (:FireA, 99))
    ev = trace_likelihood(_eval_sim(), TraceEvalRace.init!, trace)
    block = sprint(show, MIME"text/plain"(), ev)
    @test occursin("feasible", block)
    @test occursin("first infeasible : step 17", block)
    @test occursin("not_enabled", block)
    @test count(==('\n'), block) <= 5   # <= 6 lines
    oneline = sprint(show, ev)
    @test occursin("TraceEvaluation(feasible=false", oneline)
end

@testset "trace_eval rejects sim without step_likelihood" begin
    bare = SimulationFSM(
        RaceBoard(1), [FireA, FireB];
        rng=Xoshiro(7), key_type=Tuple,
    )
    trace = Tuple{Float64,Tuple}[(0.3, (:FireA, 1))]
    @test_throws ArgumentError trace_likelihood(bare, TraceEvalRace.init!, trace)
end

# An event (DFireC) fires partway through the trace and is never re-enabled, so
# its survival term must NOT appear in the log-likelihood of subsequent steps.
#
# Analytic value (exponential race, rates DA and DC):
#   step 1  DFireC fires at 0.4, enabled: {A, C}: log(DC) - (DA + DC)*0.4
#   step 2  DFireA fires at 0.9, enabled: {A}   : log(DA) - DA*(0.9 - 0.4)
#   step 3  DFireA fires at 1.5, enabled: {A}   : log(DA) - DA*(1.5 - 0.9)
#
# KNOWN UPSTREAM ISSUE: CombinedNextReaction's native steploglikelihood iterates
# stale (fired/disabled, heap_handle==0) transition entries, so with
# step_likelihood=true + Float64 eltype the context routes through that polluted
# native path and still subtracts DFireC's survival on steps 2 and 3. The
# discrepancy is exactly DC * ((0.9 - 0.4) + (1.5 - 0.9)) = DC * 1.1.
@testset "trace_eval event fires and is not re-enabled" begin
    trace = Tuple{Float64,Tuple}[
        (0.4, (:DFireC, 1)),
        (0.9, (:DFireA, 1)),
        (1.5, (:DFireA, 1)),
    ]
    ev = trace_likelihood(_disable_eval_sim(), TraceEvalDisable.init!, trace)
    expect = log(DC) - (DA + DC) * 0.4 +
             log(DA) - DA * (0.9 - 0.4) +
             log(DA) - DA * (1.5 - 0.9)
    @test ev.feasible == true
    @test ev.steps_evaluated == 3
    # BROKEN until CompetingClocks fixes stale-entry pollution in
    # CombinedNextReaction.steploglikelihood (fired/disabled clocks must be
    # filtered by heap_handle > 0). The polluted value is expect - DC * 1.1.
    @test_broken ev.loglikelihood ≈ expect atol = 1e-10
end
