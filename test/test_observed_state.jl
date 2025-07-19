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

@testset "keyedby macro" begin
    using ChronoSim.ObservedState

    # Test 1D indexing
    @keyedby MyElement1D Int64 begin
        val::Int64
        name::String
    end

    arr1d = ObservedArray{MyElement1D}(undef, 5)
    for i in 1:5
        arr1d[i] = MyElement1D(i * 10, "item$i")
    end

    # Test that fields are properly set
    elem = arr1d[3]
    @test elem.val == 30
    @test elem.name == "item3"
    @test elem._index == 3
    @test elem._container === arr1d

    # Test 2D indexing
    @keyedby MyElement2D NTuple{2,Int64} begin
        value::Float64
        active::Bool
    end

    arr2d = ObservedArray{MyElement2D}(undef, 2, 3)
    for j in 1:3, i in 1:2
        arr2d[i, j] = MyElement2D(i + j * 0.1, iseven(i + j))
    end

    # Test Cartesian indexing
    elem2d = arr2d[2, 3]
    @test elem2d.value ≈ 2.3
    @test elem2d.active == false  # 2 + 3 = 5, which is odd
    @test elem2d._index == (2, 3)
    @test elem2d._container === arr2d

    # Test linear indexing on 2D array
    elem2d_linear = arr2d[4]  # Linear index 4 corresponds to [2, 2] in column-major order
    @test elem2d_linear._index == (2, 2)
    @test elem2d_linear.value ≈ 2.2
end

@testset "ObservedDict with keyedby" begin
    using ChronoSim.ObservedState

    # Define a struct with String keys
    @keyedby DictElement String begin
        value::Int
        label::String
    end

    # Create and populate the dictionary
    dict = ObservedDict{String,DictElement}()
    dict["first"] = DictElement(100, "First Item")
    dict["second"] = DictElement(200, "Second Item")
    dict["third"] = DictElement(300, "Third Item")

    # Test that _container and _index are set correctly on access
    elem = dict["second"]
    @test elem.value == 200
    @test elem.label == "Second Item"
    @test elem._index == "second"
    @test elem._container === dict

    # Test updating an existing key
    dict["second"] = DictElement(250, "Updated Second")
    elem2 = dict["second"]
    @test elem2.value == 250
    @test elem2._index == "second"
    @test elem2._container === dict

    # Test delete! clears _container
    to_delete = dict["first"]
    @test to_delete._container === dict
    delete!(dict, "first")
    @test to_delete._container === nothing
    @test !haskey(dict, "first")

    # Test iteration doesn't update fields
    for (k, v) in dict
        # Values returned by iteration don't have updated _container/_index
        @test v isa DictElement
    end

    # Test other dictionary operations
    @test length(dict) == 2
    @test "second" in keys(dict)
    @test "third" in keys(dict)

    # Test with symbol keys
    @keyedby SymbolData Symbol begin
        data::Float64
    end

    symdict = ObservedDict{Symbol,SymbolData}()
    symdict[:alpha] = SymbolData(1.5)
    symdict[:beta] = SymbolData(2.5)

    elem_sym = symdict[:alpha]
    @test elem_sym.data == 1.5
    @test elem_sym._index == :alpha
    @test elem_sym._container === symdict
end
