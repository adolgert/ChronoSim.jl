using ReTest
using Distributions
using ChronoSim
using CompetingClocks: FirstReaction, enable!

const TestDealClockKey = Tuple{Int,Int}
const TestDealAddressType = Symbol

mutable struct TestDealEvent <: SimEvent
    key::TestDealClockKey
    prev_enabled::Bool
    enabled::Bool
    prev_invariant::Set{TestDealAddressType}
    invariant::Set{TestDealAddressType}
    prev_rate::Set{TestDealAddressType}
    rate::Set{TestDealAddressType}
    rerate::Set{TestDealAddressType}
    called_precondition::Int
    called_event_enable::Int
    called_event_reenable::Int
end


ChronoSim.clock_key(event::TestDealEvent) = event.key

function ChronoSim.generators(::Type{TestDealEvent})
    [EventGenerator(ChronoSim.ToPlace, Any[], x -> nothing)]
end

"""
The three `sim_event_*` functions call user-defined code, so we separate this
out in order to check the calls and return values.
"""
function ChronoSim.sim_event_precondition(event::TestDealEvent, physical)
    event.called_precondition += 1
    return (; result=event.enabled, reads=event.invariant)
end


function ChronoSim.sim_event_enable(event::TestDealEvent, event_key, sim, when)
    event.called_event_enable += 1
    return (; reads=event.rate)
end


function ChronoSim.sim_event_reenable(event::TestDealEvent, event_key, sim)
    event.called_event_reenable += 1
    return event.rate
end

ChronoSim.ObservedState.@observedphysical TestDealSystem begin
    car::Int
    truck::Int
    bicycle::Int
    moped::Int
    skateboard::Int
end

const TestDealAddType = Tuple{Set{TestDealAddressType},Set{TestDealAddressType}}

struct TestDealEventDependency
    invariants::Vector{TestDealEvent}
    rates::Vector{TestDealEvent}
    added::Dict{TestDealClockKey,TestDealAddType}
    removed::Set{TestDealClockKey}
end

function ChronoSim.over_event_invariants(
    f::Function, event_dependency, sim, fired_event_keys, changed_places
)
    for v in event_dependency.invariants
        f(v)
    end
end

function ChronoSim.over_event_rates(
    f::Function, event_dependency, sim, fired_event_keys, changed_places
)
    for r in event_dependency.rates
        f(r)
    end
end

function ChronoSim.add_event!(
    event_dependency::TestDealEventDependency, evt_key, enplaces, raplaces
)
    event_dependency.added[evt_key] = (enplaces, raplaces)
end

ChronoSim.remove_event!(net::TestDealEventDependency, evtkeys) = union!(net.removed, evtkeys)

ChronoSim.getevent_enable(net::TestDealEventDependency, event) = nothing

ChronoSim.getevent_rate(net::TestDealEventDependency, event) = nothing

@testset "framework deal_with_changes first time enable" begin
    event = TestDealEvent(
        (3, 7),
        false,
        true,
        Set(Symbol[]),
        Set([:car, :truck]),
        Set(Symbol[]),
        Set([:car, :moped]),
        Set([:nope]),
        0,
        0,
        0,
    )
    event_dependency = TestDealEventDependency(
        TestDealEvent[event],
        TestDealEvent[],
        Dict{TestDealClockKey,TestDealAddType}(),
        Set{TestDealClockKey}(),
    )
    physical = TestDealSystem(0, 0, 0, 0, 0)
    event_list = [TestDealEvent]
    sampler = FirstReaction{TestDealClockKey,Float64}()
    sim = SimulationFSM(physical, event_list; sampler=sampler)
    changed_places = Set([:car])
    ChronoSim.deal_with_changes(sim, event_dependency, [], changed_places)
    @test event.called_precondition == 1
    @test event.called_event_enable == 1
    @test event.called_event_reenable == 0
    @test event_dependency.added[(3, 7)][1] == Set([:car, :truck])
    @test event_dependency.added[(3, 7)][2] == Set([:car, :moped])
end

@testset "framework deal_with_changes disable" begin
    event = TestDealEvent(
        (3, 7),
        true,
        false,
        Set(Symbol[]),
        Set([:car, :truck]),
        Set(Symbol[]),
        Set([:car, :moped]),
        Set([:nope]),
        0,
        0,
        0,
    )
    event_dependency = TestDealEventDependency(
        TestDealEvent[event],
        TestDealEvent[],
        Dict{TestDealClockKey,TestDealAddType}(),
        Set{TestDealClockKey}(),
    )
    physical = TestDealSystem(0, 0, 0, 0, 0)
    event_list = [TestDealEvent]
    sampler = FirstReaction{TestDealClockKey,Float64}()
    sim = SimulationFSM(physical, event_list; sampler=sampler)
    if event.prev_enabled
        enable!(sampler, clock_key(event), Exponential(), 0.0, 0.0, sim.rng)
        sim.enabled_events[clock_key(event)] = event
        sim.enabling_times[clock_key(event)] = sim.when
    end
    changed_places = Set([:car])
    ChronoSim.deal_with_changes(sim, event_dependency, [], changed_places)
    @test event.called_precondition == 1
    @test event.called_event_enable == 0
    @test event.called_event_reenable == 0
    @test (3, 7) ∉ keys(event_dependency.added)
    @test (3, 7) ∈ event_dependency.removed
end
