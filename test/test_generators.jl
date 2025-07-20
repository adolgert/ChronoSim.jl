using Random
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

@testset "@reactto generated tests" begin
    rng = Xoshiro(34234)
    # We want to ensure all kinds of placekeys work.
    function random_placekey(rng)
        genint() = rand(rng, 1:10)
        genstr() = join(rand(rng, 'a':'z', 5))
        easysym() = Symbol(join(rand(rng, 'A':'Z', 5)))
        genindex() =
            if rand(rng) > 0.1
                argkind = rand(rng, 1:3)
                if argkind == 1
                    return genint()
                elseif argkind == 2
                    return genstr()
                else
                    return gensym()
                end
            elseif rand(rng) > 0.5
                return (genint(), genint())
            else
                return (genint(), genstr(), genint())
            end
        piece_cnt = rand(rng, 1:5)
        pieces = [Member(easysym()) for _ in 1:piece_cnt]
        idx_cnt = rand(rng, 0:3)
        indices = [genindex() for _ in 1:idx_cnt]
        placekey = shuffle(rng, vcat(pieces, indices))
        return placekey
    end
    # While placekeys have values, we want to replicate what a user types, as in
    # board[i, j].value, so this creates the string version with variables.
    function placekey_to_access_str(placekey)
        result = ""
        varlist = String[]
        accessor_idx = 0
        accessor() = (accessor_idx += 1; "k" * string(accessor_idx))
        for (i, piece) in enumerate(placekey)
            if piece isa Member
                # Member access uses dot notation
                if i == 1
                    result = string(piece.name)
                else
                    result *= "." * string(piece.name)
                end
            else
                # Index access uses bracket notation
                if piece isa Tuple
                    # Multi-dimensional index like [i, j] or [i, "str", k]
                    index_parts = [accessor() for v in piece]
                    for ipart in index_parts
                        push!(varlist, ipart)
                    end
                    result *= "[" * join(index_parts, ", ") * "]"
                else
                    # Single index like [i] or ["str"] or [sym]
                    singlevar = accessor()
                    result *= "[" * singlevar * "]"
                    push!(varlist, singlevar)
                end
            end
        end

        return result, varlist
    end

    @testset "placekey_to_access_str examples" begin
        # Test simple member access
        pk1 = [Member(:board)]
        @test placekey_to_access_str(pk1) == ("board", String[])

        # Test member with single index
        pk2 = [Member(:board), 5]
        @test placekey_to_access_str(pk2) == ("board[k1]", ["k1"])

        # Test member with string index
        pk3 = [Member(:game), "player1"]
        @test placekey_to_access_str(pk3) == ("game[k1]", ["k1"])

        # Test member with symbol index
        pk4 = [Member(:config), :debug]
        @test placekey_to_access_str(pk4) == ("config[k1]", ["k1"])

        # Test multiple members (nested object access)
        pk5 = [Member(:player), Member(:health)]
        @test placekey_to_access_str(pk5) == ("player.health", String[])

        # Test multi-dimensional index
        pk6 = [Member(:board), (3, 4)]
        @test placekey_to_access_str(pk6) == ("board[k1, k2]", ["k1", "k2"])

        # Test complex example: board[i, j].piece
        pk7 = [Member(:board), (1, 2), Member(:piece)]
        @test placekey_to_access_str(pk7) == ("board[k1, k2].piece", ["k1", "k2"])

        # Test mixed types in tuple
        pk8 = [Member(:data), (5, "key", :sym)]
        @test placekey_to_access_str(pk8) == ("data[k1, k2, k3]", ["k1", "k2", "k3"])

        # Test empty placekey
        @test placekey_to_access_str([]) == ("", String[])
    end

    @testset "Generated @reactto macro test" begin
        # Skip if no indices in placekey (can't test properly)
        for attempt in 1:10
            pk = random_placekey(rng)
            pkindices = [val for val in pk if !isa(val, Member)]

            if isempty(pkindices)
                continue
            end

            matchstr, varnames = placekey_to_access_str(pk)

            # The generate function normall accepts an event, but for testing
            # it can accept a list of variable values so that we can test that
            # the variable values were defined and in the right order for the
            # function.
            code = """
            @reactto changed($matchstr) begin physical
                generate([$(join(varnames, ", "))])
            end
            """
            println("Testing this: \n$code")
            eventgen = eval(Meta.parse(code))

            @test eventgen isa EventGenerator
            @test eventgen.match_what == ChronoSim.ToPlace

            physical = nothing
            eventgen.generator(physical, pkindices...) do argvals
                argidx = 1
                for pkidx in pkindices
                    @test length(argvals) >= argidx
                    if isa(pkidx, Tuple)
                        for val in pkidx
                            @test argvals[argidx] == val
                            argidx += 1
                        end
                    else
                        @test argvals[argidx] == pkidx
                        argidx += 1
                    end
                end
            end
        end
    end
end
