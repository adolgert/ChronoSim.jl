using ReTest
using ChronoSim
using ChronoSim.ObservedState

@testset "ObservedPhysical" begin
    # Define test types using the macros
    @keyedby PieceMacro Int begin
        speed::Float64
        kind::String
    end
    Address = ChronoSim.ObservedState.Address
    mutable struct Piece <: Addressed
        speed::Float64
        kind::String
        _address::Address{Int}
        Piece(speed, kind) = new(speed, kind, Address{Int}())
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
        @test board_state.board._address.index == Member(:board)
        @test board_state.board._address.container === board_state
        @test board_state.actor._address.index == Member(:actor)
        @test board_state.actor._address.container === board_state
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
        @test square._address.container === board_state.board
        @test square._address.index == (1, 2)

        # Test linear indexing
        square_linear = board_state.board[3]  # Linear index 3 corresponds to (1,2) in 2x2
        @test square_linear._address.container === board_state.board
        @test square_linear._address.index == (1, 2)

        # Test ObservedDict element pointers
        piece = board_state.actor[10]
        @test piece._address.container === board_state.actor
        @test piece._address.index == 10

        # Test modification updates pointers
        new_square = Square(0.9, 0.8)
        board_state.board[2, 1] = new_square
        @test new_square._address.container === board_state.board
        @test new_square._address.index == (2, 1)

        new_piece = Piece(4.0, "super")
        board_state.actor[30] = new_piece
        @test new_piece._address.container === board_state.actor
        @test new_piece._address.index == 30
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
        @test game.inventory._address.index == Member(:inventory)
        @test game.inventory._address.container === game
        @test game.pieces._address.index == Member(:pieces)
        @test game.pieces._address.container === game

        # Verify elements get correct container references
        item = game.inventory[:sword]
        @test item._address.container === game.inventory
        @test item._address.index == :sword

        piece = game.pieces[2]
        @test piece._address.container === game.pieces
        @test piece._address.index == 2
        @test piece.speed == 2.0
        @test piece.kind == "medium"
    end

    @testset "State tracking with capture functions" begin
        # Define a more comprehensive state for testing
        @keyedby VectorElement Int begin
            value::Float64
            label::String
        end

        @keyedby MatrixElement NTuple{2,Int64} begin
            value::Float64
            label::String
        end

        @keyedby SymbolElement Symbol begin
            value::Float64
            label::String
        end

        @observedphysical ComplexState begin
            grid1d::ObservedArray{VectorElement,1}
            grid2d::ObservedArray{MatrixElement,2}
            sym_dict::ObservedDict{Symbol,SymbolElement}
            int_dict::ObservedDict{Int,VectorElement}
            counter::Int
        end

        # Initialize the state
        grid1d = ObservedArray{VectorElement}(undef, 4)
        for i in 1:4
            grid1d[i] = VectorElement(i * 1.0, "elem$i")
        end

        grid2d = ObservedArray{MatrixElement}(undef, 2, 3)
        for i in 1:2, j in 1:3
            grid2d[i, j] = MatrixElement(i + j * 0.1, "grid_$(i)_$(j)")
        end

        sym_dict = ObservedDict{Symbol,SymbolElement}()
        sym_dict[:alpha] = SymbolElement(1.5, "alpha_elem")
        sym_dict[:beta] = SymbolElement(2.5, "beta_elem")
        sym_dict[:gamma] = SymbolElement(3.5, "gamma_elem")

        int_dict = ObservedDict{Int,VectorElement}()
        int_dict[100] = VectorElement(10.0, "hundred")
        int_dict[200] = VectorElement(20.0, "two_hundred")

        state = ComplexState(grid1d, grid2d, sym_dict, int_dict, 0)

        # Test capture_state_reads
        @testset "capture_state_reads" begin
            # Read from different containers
            reads_result = capture_state_reads(state) do
                # Read from 1D array
                val1 = state.grid1d[2].value

                # Read from 2D array
                val2 = state.grid2d[1, 2].label
                val3 = state.grid2d[2, 1].value

                # Read from symbol dict
                val4 = state.sym_dict[:alpha].value
                val5 = state.sym_dict[:beta].label

                # Read from int dict
                val6 = state.int_dict[100].value

                # Read non-observed field (should not be tracked)
                val7 = state.counter

                return val1 + val3 + val4 + val6
            end

            @test reads_result.result ≈ 2.0 + 2.1 + 1.5 + 10.0

            # Check that all reads were captured
            reads = reads_result.reads
            @test length(reads) == 7

            # Convert to set for easier testing (order doesn't matter)
            reads_set = Set(reads)
            @test (Member(:grid1d), 2, Member(:value)) in reads_set
            @test (Member(:grid2d), (1, 2), Member(:label)) in reads_set
            @test (Member(:grid2d), (2, 1), Member(:value)) in reads_set
            @test (Member(:sym_dict), :alpha, Member(:value)) in reads_set
            @test (Member(:sym_dict), :beta, Member(:label)) in reads_set
            @test (Member(:int_dict), 100, Member(:value)) in reads_set
            @test (Member(:counter),) in reads_set
        end

        # Test capture_state_changes
        @testset "capture_state_changes" begin
            # Modify different parts of the state
            changes_result = capture_state_changes(state) do
                # Modify 1D array
                state.grid1d[1].value = 99.0
                state.grid1d[3].label = "modified"

                # Modify 2D array
                state.grid2d[2, 2].value = 77.0

                # Modify symbol dict
                state.sym_dict[:alpha].label = "new_alpha"
                state.sym_dict[:gamma].value = 88.0

                # Modify int dict
                state.int_dict[200].value = 55.0

                # Modify non-observed field (should not be tracked)
                state.counter = 42

                return "modifications complete"
            end

            @test changes_result.result == "modifications complete"

            # Check that all modifications were captured
            changes = changes_result.changes
            @test length(changes) == 7

            # Convert to set for easier testing
            changes_set = Set(changes)
            @test (Member(:grid1d), 1, Member(:value)) in changes_set
            @test (Member(:grid1d), 3, Member(:label)) in changes_set
            @test (Member(:grid2d), (2, 2), Member(:value)) in changes_set
            @test (Member(:sym_dict), :alpha, Member(:label)) in changes_set
            @test (Member(:sym_dict), :gamma, Member(:value)) in changes_set
            @test (Member(:int_dict), 200, Member(:value)) in changes_set
            @test (Member(:counter),) in changes_set

            # Verify the actual values were changed
            @test state.grid1d[1].value ≈ 99.0
            @test state.grid1d[3].label == "modified"
            @test state.grid2d[2, 2].value ≈ 77.0
            @test state.sym_dict[:alpha].label == "new_alpha"
            @test state.sym_dict[:gamma].value ≈ 88.0
            @test state.int_dict[200].value ≈ 55.0
            @test state.counter == 42
        end

        # Test mixed reads and writes
        @testset "Mixed reads and writes" begin
            # Clear previous tracking
            empty!(state.obs_read)
            empty!(state.obs_modified)

            # Test that reads don't interfere with writes tracking
            changes_result = capture_state_changes(state) do
                # Read then write
                old_val = state.grid1d[4].value
                state.grid1d[4].value = old_val * 2

                # Write to one field after reading another
                label = state.sym_dict[:beta].label
                state.sym_dict[:beta].value = 123.0
            end

            changes = changes_result.changes
            @test length(changes) == 2
            changes_set = Set(changes)
            @test (Member(:grid1d), 4, Member(:value)) in changes_set
            @test (Member(:sym_dict), :beta, Member(:value)) in changes_set

            # Test that writes don't interfere with reads tracking
            reads_result = capture_state_reads(state) do
                # Just read, no writes
                v1 = state.grid2d[1, 3].value
                v2 = state.int_dict[100].label
                return (v1, v2)
            end

            reads = reads_result.reads
            @test length(reads) == 2
            reads_set = Set(reads)
            @test (Member(:grid2d), (1, 3), Member(:value)) in reads_set
            @test (Member(:int_dict), 100, Member(:label)) in reads_set
        end
    end
end
