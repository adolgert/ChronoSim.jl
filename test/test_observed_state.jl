using ReTest
using ChronoSim

mutable struct ObserveContained{T}
    val::Int
    _container::Any
    _index::T
    ObserveContained{T}(v) where {T} = new{T}(v)
end

@testset "ObservedState smoke 1D" begin
    using ChronoSim.ObservedState
    Contained1D = ObserveContained{Int}
    cnt = 32
    arr = ObservedArray{Contained1D}(undef, cnt)
    for init in eachindex(arr)
        arr[init] = Contained1D(-init)
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

@testset "ObservedState smoke 2D" begin
    using ChronoSim.ObservedState
    Contained2D = ObserveContained{NTuple{2,Int64}}
    dims = (4, 2)
    arr = ObservedArray{Contained2D}(undef, dims...)
    # for init in eachindex(arr)
    init = 1
    for idx in CartesianIndices(arr)
        arr[idx] = Contained2D(-init)
        init += 1
    end
    # This is linear indexing.
    for i in eachindex(arr)
        @test typeof(i) == Int64
        @test getproperty(arr[i], :_container) == arr
        @test arr[i].val == -i
    end
    # This gives you the 2D indices.
    for idx in CartesianIndices(arr)
        @test getproperty(arr[idx], :_index) == Tuple(idx)
    end
    @test arr[1, 2].val == -5
    @test length(arr) == dims[1] * dims[2]
    @test size(arr, 1) == dims[1]
    @test size(arr, 2) == dims[2]
    @test size(arr) == dims
end
