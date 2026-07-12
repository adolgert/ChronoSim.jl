using ReTest
using ChronoSim
using ChronoSim.ObservedState
using CompetingClocks
using CompetingClocks: NextReactionMethod
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

# Phase OB-3a: the event instance is the sampler key. These tests certify the
# opt-in instance-key representation (`key_type=event_key_union(events)`)
# against the default tuple representation:
#
#   * trajectory identity — same seed, same firings, bit for bit, across the
#     two representations (the stream_hash seam at work);
#   * inline storage — the isbits event union is stored inline where the
#     mixed-arity tuple join degrades to an abstract, boxed key type;
#   * order identity — instances sort exactly as their tuple keys do, so
#     key-ordered iteration (candidate sorting, enabled_ages) is identical.

# A draw-free two-event-per-machine shop with EQUAL event arities (both events
# carry one Int64), the plain case where the default tuple join is already
# concrete. Mirrors test_minimal_record.jl's MinMachines.
module IKShop
using ChronoSim
using ChronoSim.ObservedState
using Distributions
import ChronoSim: precondition, generators, enable, fire!

@enum Status working broken
# The enum rides in the physical state only, never in an event field, so the
# enum-hash obligation on clock keys does not arise here.

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
enable(::Fail, s, when) = (Weibull(1.7, 0.8), when)
fire!(e::Fail, s, when, rng) = (s.machine[e.idx].status = broken; nothing)

struct Repair <: SimEvent
    idx::Int64
end
@precondition precondition(e::Repair, s) = s.machine[e.idx].status == broken
enable(::Repair, s, when) = (Gamma(2.0, 0.5), when)
fire!(e::Repair, s, when, rng) = (s.machine[e.idx].status = working; nothing)

function init!(s, when, rng)
    for i in eachindex(s.machine)
        s.machine[i].status = working
    end
    return nothing
end
end # module IKShop

# A model with UNEQUAL event arities (a fieldless event racing a one-field
# event) whose one-field event's fire! DRAWS from its per-key fire stream. This
# is the case the instance key exists for: `common_base_key_tuple` degrades to
# the abstract Tuple{Symbol,Vararg{Int64}} here, and the fire-side draw
# exercises the tuple-keyed fire-stream family under both representations.
module IKMixed
using ChronoSim
using ChronoSim.ObservedState
using Distributions
using Random
import ChronoSim: precondition, generators, enable, fire!

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

# Fieldless: clock key (:Surge,), arity 1.
struct Surge <: SimEvent end
@precondition precondition(e::Surge, s) = s.cell[1].a >= 0
enable(::Surge, s, when) = (Exponential(0.7), when)
fire!(e::Surge, s, when, rng) = (s.cell[1].a += 1; nothing)

# One field: clock key (:Kick, idx), arity 2. Its fire! draws, so the run is
# fire-random and every firing consumes from Kick(idx)'s own fire stream.
struct Kick <: SimEvent
    idx::Int64
end
@precondition precondition(e::Kick, s) = s.cell[e.idx].b >= 0
enable(::Kick, s, when) = (Exponential(0.4), when)
function fire!(e::Kick, s, when, rng)
    # The draw's VALUE feeds the state so a stream divergence between the two
    # key representations would change the trajectory, not just pass unnoticed.
    s.cell[e.idx].b += rand(rng, 1:3)
    return nothing
end

function init!(s, when, rng)
    for i in eachindex(s.cell)
        s.cell[i].a = 0
        s.cell[i].b = 0
    end
    return nothing
end
end # module IKMixed

# --- helpers -----------------------------------------------------------------

# Run a model and capture the firing sequence as (clock_key-content, when)
# pairs. The observer receives the fired EVENT, so recording clock_key(event)
# gives the same content-tuple sequence under either key representation --
# which is exactly what cross-representation trajectory identity must compare.
function _ik_firings(state, events, init!; key_type, seed, nsteps)
    fires = Tuple{Tuple,Float64}[]
    observer = (phys, when, event, changed) -> begin
        push!(fires, (clock_key(event), when))
        return nothing
    end
    sim = SimulationFSM(
        state, events;
        seed=seed, sampler=NextReactionMethod(), key_type=key_type, observer=observer,
    )
    ChronoSim.run(sim, init!, (p, i, e, w) -> i > nsteps)
    return fires, sim
end

# =============================================================================
# Plan test 10: cross-representation trajectory identity.
# =============================================================================

@testset "instance key: an event-instance key and its tuple key produce identical stream hashes, so trajectories are byte-identical across key representations on the same seeds" begin
    events = [IKShop.Fail, IKShop.Repair]
    U = event_key_union(events)
    seed = 20260712
    tuple_fires, tuple_sim = _ik_firings(
        IKShop.Shop(3), events, IKShop.init!; key_type=Tuple, seed=seed, nsteps=80)
    inst_fires, inst_sim = _ik_firings(
        IKShop.Shop(3), events, IKShop.init!; key_type=U, seed=seed, nsteps=80)
    @test length(tuple_fires) > 40
    # Bit-for-bit: same clock-key contents AND Float64-equal firing times. The
    # non-exponential clocks (Weibull, Gamma) make the times sensitive to every
    # uniform the sampler consumed, so equality here certifies the stream_hash
    # seam reproduced each clock's stream exactly.
    @test inst_fires == tuple_fires
    @test inst_sim.when == tuple_sim.when
    # Both event types actually fired; a one-sided run would prove little.
    @test any(f -> f[1][1] === :Fail, tuple_fires)
    @test any(f -> f[1][1] === :Repair, tuple_fires)
end

@testset "instance key: a mixed-arity model whose fire! draws randomness is byte-identical across key representations, covering the tuple-keyed fire streams" begin
    events = [IKMixed.Surge, IKMixed.Kick]
    U = event_key_union(events)
    seed = 909090
    tuple_fires, tuple_sim = _ik_firings(
        IKMixed.Board(2), events, IKMixed.init!; key_type=Tuple, seed=seed, nsteps=80)
    inst_fires, inst_sim = _ik_firings(
        IKMixed.Board(2), events, IKMixed.init!; key_type=U, seed=seed, nsteps=80)
    # The Kick fire! draws feed the state, so the run must be flagged
    # fire-random -- proving the per-key fire streams were really consumed.
    @test tuple_sim.fire_random && inst_sim.fire_random
    @test length(tuple_fires) > 40
    @test inst_fires == tuple_fires
    # And the drawn values landed identically in the final states.
    @test all(inst_sim.physical.cell[i].b == tuple_sim.physical.cell[i].b
              for i in 1:2)
end

# =============================================================================
# Plan test 11: inline storage of the isbits union.
# =============================================================================

@testset "instance key: the union key type stores sampler tables inline for isbits event structs" begin
    U2 = event_key_union((IKShop.Fail, IKShop.Repair))
    @test Base.isbitsunion(U2)
    @test Base.allocatedinline(U2)
    # The mixed-arity union is just as inline...
    Umix = event_key_union((IKMixed.Surge, IKMixed.Kick))
    @test Base.isbitsunion(Umix)
    @test Base.allocatedinline(Umix)
    # ...while the motivating contrast, the default tuple join for the SAME
    # mixed-arity events, is an abstract type that every container must box.
    joined = ChronoSim.common_base_key_tuple([IKMixed.Surge, IKMixed.Kick])
    @test !isconcretetype(joined)
    @test !Base.allocatedinline(joined)

    # Poke the live simulation: the engine's tables and the sampler both carry
    # the union as their key type, so the inline layout is what actually runs.
    sim = SimulationFSM(
        IKMixed.Board(1), [IKMixed.Surge, IKMixed.Kick];
        seed=5, sampler=NextReactionMethod(), key_type=Umix,
    )
    @test keytype(sim.enabled_events) === Umix
    @test Base.allocatedinline(keytype(sim.enabled_events))
    @test CompetingClocks.keytype(sim.sampler) === Umix
end

# =============================================================================
# Plan test 12, model-free half: order identity across representations.
#
# The other half of plan test 12 -- ordering by the event type's POSITION in
# the model's declared event tuple, so the order is robust to RENAMING a type
# -- landed in phase OB-3c as `model_key_order(model)` (a model-derived
# Ordering value; see test_gsmp_model.jl). The model-free order below is the
# tuple order, chosen precisely so that instance and tuple representations of
# one model iterate keys identically.
# =============================================================================

@testset "instance key: instance keys sort in the same order their tuple keys sort, so key-ordered iteration is identical across representations" begin
    evts = [IKShop.Repair(2), IKShop.Fail(3), IKShop.Repair(1), IKShop.Fail(1),
            IKShop.Fail(2)]
    # Pairwise: Base.isless on instances agrees with isless on their tuples,
    # within a type and across types.
    for a in evts, b in evts
        @test isless(a, b) == isless(clock_key(a), clock_key(b))
    end
    # Mixed arity too: (:Kick, 1) sorts before (:Surge,) because the type-name
    # Symbol leads the tuple.
    @test isless(IKMixed.Kick(1), IKMixed.Surge()) ==
          isless(clock_key(IKMixed.Kick(1)), clock_key(IKMixed.Surge()))
    # Whole-vector: sorting instances directly equals sorting by their tuples.
    @test sort(evts) == sort(evts; by=clock_key)
end

@testset "instance key: enabled_ages returns the same clocks in the same positions mid-run under both key representations" begin
    events = [IKShop.Fail, IKShop.Repair]
    U = event_key_union(events)
    seed = 445566

    function run_partial(key_type)
        sim = SimulationFSM(
            IKShop.Shop(4), events;
            seed=seed, sampler=NextReactionMethod(), key_type=key_type,
        )
        ChronoSim.run(sim, IKShop.init!, (p, i, e, w) -> i > 15)
        return sim
    end
    tuple_sim = run_partial(Tuple)
    inst_sim = run_partial(U)
    @test inst_sim.when == tuple_sim.when

    # enabled_ages sorts by key (CompetingClocks capabilities.jl); a branching
    # estimator indexes a selection pmf by position in this order, so the two
    # representations must present the same clocks in the same slots.
    ages_tuple = CompetingClocks.enabled_ages(tuple_sim.sampler.sampler, tuple_sim.when)
    ages_inst = CompetingClocks.enabled_ages(inst_sim.sampler.sampler, inst_sim.when)
    @test length(ages_tuple) == length(ages_inst)
    @test length(ages_tuple) > 1
    @test [clock_key(k) for (k, _) in ages_inst] == [k for (k, _) in ages_tuple]
    @test [age for (_, age) in ages_inst] == [age for (_, age) in ages_tuple]
end

# =============================================================================
# Consumer round trips that must keep working under instance keys.
# =============================================================================

@testset "instance key: key_clock is the identity on an instance key, so the states_at fold replays an instance-keyed record" begin
    events = [IKMixed.Surge, IKMixed.Kick]
    U = event_key_union(events)
    pol = RecordMinimal(; initializer=IKMixed.init!)
    fires = Tuple{Tuple,Float64}[]
    sim = SimulationFSM(
        IKMixed.Board(2), events;
        seed=777, sampler=NextReactionMethod(), key_type=U, step_likelihood=true,
        policy=pol,
        observer=(p, w, e, c) -> (push!(fires, (clock_key(e), w)); nothing),
    )
    ChronoSim.run(sim, IKMixed.init!, (p, i, e, w) -> i > 30)
    rec = minimal_record(pol)
    # The record's firings carry instance keys.
    @test eltype(rec.firings) == Tuple{U,Float64}
    # key_clock resolves an instance key to itself.
    first_key = rec.firings[1][1]
    @test key_clock(first_key, sim.event_types) === first_key
    # The fold replays the instance-keyed record to the run's own final state
    # (fire draws included: the fold re-derives the tuple-keyed fire streams).
    fold = states_at(sim, rec.initial_state, rec)
    @test length(fold) == length(rec.firings) + 1
    final = fold[end]
    @test all(final.cell[i].a == sim.physical.cell[i].a &&
              final.cell[i].b == sim.physical.cell[i].b for i in 1:2)
end
