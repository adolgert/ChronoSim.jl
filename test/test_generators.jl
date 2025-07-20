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
