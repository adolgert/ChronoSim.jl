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

@testset "EventGenerator construction" begin
    struct EGCMoveEvent
        xloc::Int64
        yloc::Int64
        agent::String
        kind::Symbol
    end
    gen = EventGenerator(
        ToPlace,
        [Member(:board), ChronoSim.MEMBERINDEX, Member(:piece)],
        function (generate, physical, i)
            return generate(EGCMoveEvent(i, 2, "hi", :there))
        end,
    )

    @test gen.match_what == ToPlace
    @test gen.matchstr == [Member(:board), ChronoSim.MEMBERINDEX, Member(:piece)]
    @test gen.generator isa Function
    physical = ()
    gen.generator(physical, 3) do arg
        @test arg == EGCMoveEvent(3, 2, "hi", :there)
    end
end

@testset "access_to_searchkey" begin
    # Test simple field access
    expr = :(obj.field)
    result = ChronoSim.access_to_searchkey(expr)
    @test result == [Member(:obj), Member(:field)]

    # Test array access with field
    expr = :(arr[i].field)
    result = ChronoSim.access_to_searchkey(expr)
    @test result == [Member(:arr), ChronoSim.MEMBERINDEX, Member(:field)]

    # Test nested field access
    expr = :(obj.field1.field2)
    result = ChronoSim.access_to_searchkey(expr)
    @test result == [Member(:obj), Member(:field1), Member(:field2)]

    # Test complex nested access
    expr = :(board[i][j].piece)
    result = ChronoSim.access_to_searchkey(expr)
    @test result == [Member(:board), ChronoSim.MEMBERINDEX, ChronoSim.MEMBERINDEX, Member(:piece)]
end

@testset "access_to_argnames" begin
    examples = [
        (:(arr[i]), [:i]),
        (:(arr[i].field), [:i]),
        (:(board[i][j].piece), [:i, :j]),
        (:(obj.field1.field2), []),
        (:(obj.field1[i].field2[j]), [:i, :j]),
        # This is meant to represent a function argument that is destructured into (i, j).
        (:(sim.places[i, j].val), Any[:(i, j)]),
    ]
    for (input, output) in examples
        result = ChronoSim.access_to_argnames(input)
        @test result == output
    end
end

@testset "@reactto macro expansion" begin
    struct EMCMoveEvent
        xloc::Int64
        yloc::Int64
        agent::String
        kind::Symbol
    end
    expanded = @macroexpand @reactto changed(agent[i].health) begin
        physical
        generate(EMCMoveEvent(i, 2, "hi", :there))
    end

    @test expanded isa Expr
    @test expanded.head == :call
    @test expanded.args[1] in [:EventGenerator, GlobalRef(ChronoSim, :EventGenerator)]
    @test expanded.args[2] in [ChronoSim.ToPlace, GlobalRef(ChronoSim, :ToPlace)]
    @test expanded.args[3] == [Member(:agent), ChronoSim.MEMBERINDEX, Member(:health)]

    # Test that the function has correct signature
    @test expanded.args[4] isa Expr
    @test expanded.args[4].head == :function
    func_sig = expanded.args[4].args[1]
    @test func_sig.args[1] isa Expr && func_sig.args[1].head == :(::)

    eg = eval(expanded)
    @test eg.match_what == ChronoSim.ToPlace
    @test eg.matchstr == [Member(:agent), ChronoSim.MEMBERINDEX, Member(:health)]
    @test eg.generator isa Function

    # Test calling the generator
    physical = nothing  # Define physical variable
    result = nothing
    eg.generator((evt) -> (result = evt), physical, 3)
    @test result == EMCMoveEvent(3, 2, "hi", :there)
end
