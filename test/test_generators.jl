using ReTest
using ChronoSim

@testset "Generator maskindex" begin
    IDX = ChronoSim.MEMBERINDEX
    examples = [
        ((Member(:foo), (3, 7), Member(:bar)), (Member(:foo), IDX, Member(:bar))),
        ((Member(:foo),), (Member(:foo),)),
        (((37),), (IDX,)),
        ((Member(:foo), Member(:bar), Member(:baz)), (Member(:foo), Member(:bar), Member(:baz))),
    ]
    for (a, b) in examples
        @test ChronoSim.placekey_mask_index(a) == b
    end
end

@testset "access_to_searchkey" begin
    # Test simple field access
    expr = :(obj.field)
    result = ChronoSim.access_to_searchkey(expr)
    @test result == [Member(:field)]

    # Test array access with field
    expr = :(arr[i].field)
    result = ChronoSim.access_to_searchkey(expr)
    @test result == [ChronoSim.MEMBERINDEX, Member(:field)]

    # Test nested field access
    expr = :(obj.field1.field2)
    result = ChronoSim.access_to_searchkey(expr)
    @test result == [Member(:field1), Member(:field2)]

    # Test complex nested access
    expr = :(board[i][j].piece)
    result = ChronoSim.access_to_searchkey(expr)
    @test result == [ChronoSim.MEMBERINDEX, ChronoSim.MEMBERINDEX, Member(:piece)]
end

@testset "access_to_argnames" begin
    examples = [
        (:(arr[i]), [:i]),
        (:(arr[i].field), [:i]),
        (:(board[i][j].piece), [:i, :j]),
        (:(obj.field1.field2), []),
        (:(obj.field1[i].field2[j]), [:i, :j]),
        # This is meant to represent a function argument that is destructured into (i, j).
        (:(sim.places[i, j].val), [(:i, :j)]),
    ]
    for (input, output) in examples
        result = ChronoSim.access_to_argnames(input)
        @test result == output
    end
end

@testset "@reactto macro expansion" begin
    # Test changed() syntax
    expanded = @macroexpand @reactto changed(agent[i].health) begin
        physical
        # body
    end

    @test expanded isa Expr
    @test expanded.head == :call
    @test expanded.args[1] == :EventGenerator
    @test expanded.args[2] == ChronoSim.ToPlace
    @test expanded.args[3] == [:agent, ChronoSim.MEMBERINDEX, Member(:health)]

    # Test that the function has correct signature
    @test expanded.args[4] isa Expr
    @test expanded.args[4].head == :function
    func_sig = expanded.args[4].args[1]
    @test func_sig.args[1] == :(f::Function)
    # The rest depends on escaping
end

@testset "EventGenerator construction" begin
    # Create a simple generator
    gen = EventGenerator(
        ChronoSim.ToPlace,
        [:board, ChronoSim.MEMBERINDEX, Member(:piece)],
        function (f, physical, i)
            # Generator body
        end,
    )

    @test gen.match_what == ChronoSim.ToPlace
    @test gen.matchstr == [:board, ChronoSim.MEMBERINDEX, Member(:piece)]
    @test gen.generator isa Function
end
