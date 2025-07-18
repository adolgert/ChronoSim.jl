using ReTest
using ChronoSim
using ChronoSim.ObservedState

@testset "ObservedPhysical" begin
    # Define test types using the macros
    @keyedby Piece Int begin
        speed::Float64
        kind::String
    end

    @keyedby Square NTuple{2,Int64} begin
        grass::Float64
        food::Float64
    end

    @observedphysical Board begin
        board::ObservedArray{Square,2}
        actor::ObservedDict{Int,Piece}
        params::Dict{Symbol,Float64}
        actors_max::Int64
    end

    @testset "Basic structure" begin
        # Create some test data
        board_data = ObservedArray{Square}(undef, 3, 3)
        for i in 1:3, j in 1:3
            board_data[i, j] = Square(0.5, 1.0)
        end

        actor_data = ObservedDict{Int,Piece}()
        actor_data[1] = Piece(2.5, "walker")
        actor_data[2] = Piece(3.0, "runner")

        params = Dict(:gravity => 9.8, :friction => 0.1)

        # Create the Board instance
        board_state = Board(board_data, actor_data, params, 10)

        # Test basic properties
        @test board_state isa Board
        @test board_state isa ObservedPhysical
        @test board_state isa ChronoSim.PhysicalState

        # Test that tracking vectors are initialized
        @test board_state.obs_modified == []
        @test board_state.obs_read == []

        # Test that observed fields have correct owner references
        @test board_state.board.array_name == :board
        @test board_state.board.owner === board_state
        @test board_state.actor.array_name == :actor
        @test board_state.actor.owner === board_state
    end

    @testset "Container and index pointers" begin
        # Create a Board instance
        board_data = ObservedArray{Square}(undef, 2, 2)
        for i in 1:2, j in 1:2
            board_data[i, j] = Square(i * 0.1, j * 0.2)
        end

        actor_data = ObservedDict{Int,Piece}()
        actor_data[10] = Piece(1.5, "fast")
        actor_data[20] = Piece(0.5, "slow")

        board_state = Board(board_data, actor_data, Dict{Symbol,Float64}(), 50)

        # Test ObservedArray element pointers
        square = board_state.board[1, 2]
        @test square._container === board_state.board
        @test square._index == (1, 2)

        # Test linear indexing
        square_linear = board_state.board[3]  # Linear index 3 corresponds to (1,2) in 2x2
        @test square_linear._container === board_state.board
        @test square_linear._index == (1, 2)

        # Test ObservedDict element pointers
        piece = board_state.actor[10]
        @test piece._container === board_state.actor
        @test piece._index == 10

        # Test modification updates pointers
        new_square = Square(0.9, 0.8)
        board_state.board[2, 1] = new_square
        @test new_square._container === board_state.board
        @test new_square._index == (2, 1)

        new_piece = Piece(4.0, "super")
        board_state.actor[30] = new_piece
        @test new_piece._container === board_state.actor
        @test new_piece._index == 30
    end

    @testset "Multiple observed fields" begin
        # Test with multiple observed containers
        @keyedby Item Symbol begin
            value::Float64
            count::Int
        end

        @observedphysical GameState begin
            inventory::ObservedDict{Symbol,Item}
            pieces::ObservedArray{Piece,1}
            config::String
        end

        inventory = ObservedDict{Symbol,Item}()
        inventory[:sword] = Item(100.0, 1)
        inventory[:potion] = Item(50.0, 3)

        pieces = ObservedArray{Piece}(undef, 3)
        pieces[1] = Piece(1.0, "slow")
        pieces[2] = Piece(2.0, "medium")
        pieces[3] = Piece(3.0, "fast")

        game = GameState(inventory, pieces, "default")

        # Verify all observed fields have correct owner references
        @test game.inventory.array_name == :inventory
        @test game.inventory.owner === game
        @test game.pieces.array_name == :pieces
        @test game.pieces.owner === game

        # Verify elements get correct container references
        item = game.inventory[:sword]
        @test item._container === game.inventory
        @test item._index == :sword

        piece = game.pieces[2]
        @test piece._container === game.pieces
        @test piece._index == 2
        @test piece.speed == 2.0
        @test piece.kind == "medium"
    end
end
