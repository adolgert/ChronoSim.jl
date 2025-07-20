using ReTest
using ChronoSim

# Test data builders for creating EventGenerator instances easily
module TestGenerators
using ChronoSim

# Simple mock event types for testing
struct TestEvent1 end
struct TestEvent2 end
struct TestEventWithArgs
    name::String
    count::Int
end

# Builder functions for different generator types
function make_place_generator(matchstr, name="gen")
    EventGenerator(ChronoSim.ToPlace, matchstr, function (f, physical, indices...)
        # Track that this generator was called
        f(TestEventWithArgs(name, length(indices)))
    end)
end

function make_event_generator(event_type::Symbol, name="gen")
    EventGenerator(ChronoSim.ToEvent, [event_type], function (f, physical, args...)
        # Track that this generator was called
        f(TestEventWithArgs(name, length(args)))
    end)
end

# Helper to create common patterns
function board_piece_generator(name="board")
    make_place_generator([Member(:board), ChronoSim.MEMBERINDEX, Member(:piece)], name)
end

function agent_health_generator(name="agent")
    make_place_generator([Member(:agent), ChronoSim.MEMBERINDEX, Member(:health)], name)
end

function simple_field_generator(obj::Symbol, field::Symbol, name=string(obj))
    make_place_generator([Member(obj), Member(field)], name)
end
end

@testset "GeneratorSearch Construction" begin
    using .TestGenerators

    @testset "Empty generators" begin
        gs = GeneratorSearch(EventGenerator[])
        @test isempty(gs.event_to_event)
        @test isempty(gs.byarray)
        @test isempty(ChronoSim.event_types(gs))
        @test isempty(ChronoSim.place_patterns(gs))
    end

    @testset "Single event generator" begin
        gen = TestGenerators.make_event_generator(:TestEvent, "evt1")
        gs = GeneratorSearch([gen])

        @test length(gs.event_to_event) == 1
        @test haskey(gs.event_to_event, :TestEvent)
        @test length(gs.event_to_event[:TestEvent]) == 1
        @test isempty(gs.byarray)
    end

    @testset "Multiple event generators for same event" begin
        gen1 = TestGenerators.make_event_generator(:TestEvent, "evt1")
        gen2 = TestGenerators.make_event_generator(:TestEvent, "evt2")
        gen3 = TestGenerators.make_event_generator(:OtherEvent, "evt3")

        gs = GeneratorSearch([gen1, gen2, gen3])

        @test length(gs.event_to_event) == 2
        @test length(gs.event_to_event[:TestEvent]) == 2
        @test length(gs.event_to_event[:OtherEvent]) == 1
    end

    @testset "Single place generator" begin
        gen = TestGenerators.board_piece_generator("board1")
        gs = GeneratorSearch([gen])

        @test isempty(gs.event_to_event)
        @test length(gs.byarray) == 1

        expected_key = (Member(:board), ChronoSim.MEMBERINDEX, Member(:piece))
        @test haskey(gs.byarray, expected_key)
        @test length(gs.byarray[expected_key]) == 1
    end

    @testset "Mixed place generators with same length" begin
        gen1 = TestGenerators.board_piece_generator("board1")
        gen2 = TestGenerators.agent_health_generator("agent1")
        gen3 = TestGenerators.board_piece_generator("board2")  # Same pattern as gen1

        gs = GeneratorSearch([gen1, gen2, gen3])

        @test length(gs.byarray) == 2

        board_key = (Member(:board), ChronoSim.MEMBERINDEX, Member(:piece))
        agent_key = (Member(:agent), ChronoSim.MEMBERINDEX, Member(:health))

        @test haskey(gs.byarray, board_key)
        @test haskey(gs.byarray, agent_key)
        @test length(gs.byarray[board_key]) == 2  # gen1 and gen3
        @test length(gs.byarray[agent_key]) == 1   # gen2
    end

    @testset "Mixed place generators with different lengths" begin
        gen1 = TestGenerators.simple_field_generator(:obj, :field, "simple")
        gen2 = TestGenerators.board_piece_generator("board")
        gen3 = TestGenerators.make_place_generator(
            [
                Member(:deep),
                ChronoSim.MEMBERINDEX,
                ChronoSim.MEMBERINDEX,
                Member(:nested),
                Member(:field),
            ],
            "deep",
        )

        gs = GeneratorSearch([gen1, gen2, gen3])

        # Check that dictionary can handle variable-length tuples
        @test length(gs.byarray) == 3

        # Each pattern should be findable
        @test haskey(gs.byarray, (Member(:obj), Member(:field)))
        @test haskey(gs.byarray, (Member(:board), ChronoSim.MEMBERINDEX, Member(:piece)))
        @test haskey(
            gs.byarray,
            (
                Member(:deep),
                ChronoSim.MEMBERINDEX,
                ChronoSim.MEMBERINDEX,
                Member(:nested),
                Member(:field),
            ),
        )
    end

    @testset "Mixed event and place generators" begin
        event_gen1 = TestGenerators.make_event_generator(:Event1, "e1")
        event_gen2 = TestGenerators.make_event_generator(:Event2, "e2")
        place_gen1 = TestGenerators.board_piece_generator("p1")
        place_gen2 = TestGenerators.agent_health_generator("p2")

        gs = GeneratorSearch([event_gen1, place_gen1, event_gen2, place_gen2])

        @test length(gs.event_to_event) == 2
        @test length(gs.byarray) == 2
        @test haskey(gs.event_to_event, :Event1)
        @test haskey(gs.event_to_event, :Event2)
        @test haskey(gs.byarray, (Member(:board), ChronoSim.MEMBERINDEX, Member(:piece)))
        @test haskey(gs.byarray, (Member(:agent), ChronoSim.MEMBERINDEX, Member(:health)))
    end
end

@testset "over_generated_events" begin
    using .TestGenerators

    # Create a variety of generators
    evt_gen1 = TestGenerators.make_event_generator(:MoveEvent, "move1")
    evt_gen2 = TestGenerators.make_event_generator(:MoveEvent, "move2")
    evt_gen3 = TestGenerators.make_event_generator(:AttackEvent, "attack1")

    place_gen1 = TestGenerators.board_piece_generator("board1")
    place_gen2 = TestGenerators.agent_health_generator("agent1")
    place_gen3 = TestGenerators.simple_field_generator(:player, :score, "score1")

    all_generators = [evt_gen1, evt_gen2, evt_gen3, place_gen1, place_gen2, place_gen3]
    gs = GeneratorSearch(all_generators)

    @testset "Event-triggered generators" begin
        collected_events = []
        physical = nothing

        # Test MoveEvent triggers both move generators
        ChronoSim.over_generated_events(
            evt -> push!(collected_events, evt),
            gs,
            physical,
            [:MoveEvent, 10, 20],  # event_key with args
            [],  # no changed places
        )

        @test length(collected_events) == 2
        @test all(evt -> evt isa TestGenerators.TestEventWithArgs, collected_events)
        @test Set([evt.name for evt in collected_events]) == Set(["move1", "move2"])
        @test all(evt -> evt.count == 2, collected_events)  # 2 args passed
    end

    @testset "Place-triggered generators" begin
        collected_events = []
        physical = nothing

        # Test board change triggers board generator
        ChronoSim.over_generated_events(
            evt -> push!(collected_events, evt),
            gs,
            physical,
            Symbol[],  # no event
            [(Member(:board), 5, Member(:piece)), (Member(:board), 7, Member(:piece))],
        )

        # Should trigger board generator twice (once per place)
        @test length(collected_events) == 2
        @test all(evt -> evt.name == "board1", collected_events)
        @test all(evt -> evt.count == 1, collected_events)  # 1 index passed
    end

    @testset "Mixed event and place triggers" begin
        collected_events = []
        physical = nothing

        ChronoSim.over_generated_events(
            evt -> push!(collected_events, evt),
            gs,
            physical,
            [:AttackEvent, "sword"],
            [(Member(:agent), 3, Member(:health)), (Member(:player), Member(:score))],
        )

        # Should trigger: 1 attack event + 1 agent health + 1 player score
        @test length(collected_events) == 3
        names = Set([evt.name for evt in collected_events])
        @test names == Set(["attack1", "agent1", "score1"])
    end

    @testset "No matching generators" begin
        collected_events = []
        physical = nothing

        ChronoSim.over_generated_events(
            evt -> push!(collected_events, evt),
            gs,
            physical,
            [:UnknownEvent],
            [(Member(:unknown), Member(:field))],
        )

        @test isempty(collected_events)
    end
end

# Test the dictionary type logic specifically
@testset "GeneratorSearch dictionary typing" begin
    using .TestGenerators

    @testset "Uniform length place generators" begin
        # All generators have length 3
        gen1 = TestGenerators.board_piece_generator()
        gen2 = TestGenerators.agent_health_generator()
        gen3 = TestGenerators.make_place_generator(
            [Member(:item), ChronoSim.MEMBERINDEX, Member(:count)], "item"
        )

        gs = GeneratorSearch([gen1, gen2, gen3])

        # The dictionary should have keys typed as NTuple{3,Member}
        @test gs isa GeneratorSearch{<:Dict{NTuple{3,Member},Vector{Function}}}
    end

    @testset "Variable length place generators" begin
        # Different lengths: 2, 3, 5
        gen1 = TestGenerators.simple_field_generator(:obj, :field)
        gen2 = TestGenerators.board_piece_generator()
        gen3 = TestGenerators.make_place_generator(
            [Member(:a), ChronoSim.MEMBERINDEX, ChronoSim.MEMBERINDEX, Member(:b), Member(:c)],
            "long",
        )

        gs = GeneratorSearch([gen1, gen2, gen3])

        # The dictionary should have keys typed as Tuple{Vararg{Member}}
        @test gs isa GeneratorSearch{<:Dict{Tuple{Vararg{Member}},Vector{Function}}}
    end

    @testset "Only event generators" begin
        gen1 = TestGenerators.make_event_generator(:Event1)
        gen2 = TestGenerators.make_event_generator(:Event2)

        gs = GeneratorSearch([gen1, gen2])

        # Should still work even with no place generators
        @test isempty(gs.byarray)
    end
end

@testset "GeneratorSearch inspection methods" begin
    using .TestGenerators

    # Create a mixed set of generators
    evt1 = TestGenerators.make_event_generator(:MoveEvent, "m1")
    evt2 = TestGenerators.make_event_generator(:MoveEvent, "m2")
    evt3 = TestGenerators.make_event_generator(:AttackEvent, "a1")

    place1 = TestGenerators.board_piece_generator("b1")
    place2 = TestGenerators.board_piece_generator("b2")
    place3 = TestGenerators.agent_health_generator("h1")

    gs = GeneratorSearch([evt1, evt2, evt3, place1, place2, place3])

    @testset "Event generator queries" begin
        @test ChronoSim.has_event_generator(gs, :MoveEvent) == true
        @test ChronoSim.has_event_generator(gs, :AttackEvent) == true
        @test ChronoSim.has_event_generator(gs, :UnknownEvent) == false

        @test ChronoSim.count_event_generators(gs, :MoveEvent) == 2
        @test ChronoSim.count_event_generators(gs, :AttackEvent) == 1
        @test ChronoSim.count_event_generators(gs, :UnknownEvent) == 0

        event_list = ChronoSim.event_types(gs)
        @test Set(event_list) == Set([:MoveEvent, :AttackEvent])
    end

    @testset "Place generator queries" begin
        board_pattern = (Member(:board), 5, Member(:piece))
        agent_pattern = (Member(:agent), 3, Member(:health))
        unknown_pattern = (Member(:unknown), Member(:field))

        @test ChronoSim.has_place_generator(gs, board_pattern) == true
        @test ChronoSim.has_place_generator(gs, agent_pattern) == true
        @test ChronoSim.has_place_generator(gs, unknown_pattern) == false

        @test ChronoSim.count_place_generators(gs, board_pattern) == 2
        @test ChronoSim.count_place_generators(gs, agent_pattern) == 1
        @test ChronoSim.count_place_generators(gs, unknown_pattern) == 0

        place_list = ChronoSim.place_patterns(gs)
        expected_patterns = Set([
            (Member(:board), ChronoSim.MEMBERINDEX, Member(:piece)),
            (Member(:agent), ChronoSim.MEMBERINDEX, Member(:health)),
        ])
        @test Set(place_list) == expected_patterns
    end
end
