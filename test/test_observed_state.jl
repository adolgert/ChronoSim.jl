using ReTest
using ChronoSim

mutable struct ObserveContained{T}
    val::Int
    _container::Any
    _index::T
    ObserveContained{T}(v) where T = new{T}(v)
end

@testset "ObservedState smoke 1D" begin
    using ChronoSim.ObservedState
    Contained = ObserveContained{Int}
    cnt = 32
    arr = ObservedArray{Contained}(undef, cnt)
    for init in eachindex(arr)
        arr[init] = Contained(-init)
    end
    for i in eachindex(arr)
        @test getproperty(arr[i], :_index) == i
        @test getproperty(arr[i], :_container) == arr
        @test arr[i].val == -i
    end
    @test length(arr) == cnt
    @test size(arr, 1) == cnt
    @test size(arr) == (cnt,)
end


# @testset "ObservedState smoke 2D" begin
#     using ChronoSim.ObservedState
#     Contained = ObserveContained{Int}
#     dims = (4, 2)
#     arr = ObservedArray{Contained}(undef, dims...)
#     for init in eachindex(arr)
#         arr[init] = Contained(-init)
#     end
#     for i in eachindex(arr)
#         @test getproperty(arr[i], :_index) == i
#         @test getproperty(arr[i], :_container) == arr
#         @test arr[i].val == -i
#     end
#     @test length(arr) == cnt
#     @test size(arr, 1) == cnt
#     @test size(arr) == (cnt,)
# end
