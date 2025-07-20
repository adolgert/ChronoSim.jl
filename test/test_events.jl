using ReTest
using ChronoSim

@testset "Event stuff" begin
    struct GoEvent <: SimEvent end
    struct StopEvent <: SimEvent
        when::Int
    end
    struct BounceEvent <: SimEvent
        when::Int
        howhigh::String
    end
    abstract type FlyEvent <: SimEvent end
    struct FloatEvent <: FlyEvent
        when::Int
        who::Symbol
        kind::Char
    end

    event_list = [GoEvent, StopEvent, BounceEvent, FloatEvent]
    event_dict = Dict(nameof(ename) => ename for ename in event_list)

    go = GoEvent()
    @test clock_key(go) == (:GoEvent,)
    @test key_clock((:GoEvent,), event_dict) == go
    @test key_clock(clock_key(go), event_dict) == go

    stop = StopEvent(3)
    @test key_clock(clock_key(stop), event_dict) == stop

    bounce = BounceEvent(7, "high")
    @test key_clock(clock_key(bounce), event_dict) == bounce

    float = FloatEvent(-2, :brown, 'c')
    @test key_clock(clock_key(float), event_dict) == float
end
