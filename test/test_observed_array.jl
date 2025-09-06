using ReTest
using ChronoSim
using ChronoSim.ObservedState

@testset "ObservedArray" begin
    struct ObsArrayListen
        seen::Vector{Any}
    end
    ChronoSim.ObservedState.observed_notify(osl::ObsArrayListen, address, readwrite) = push!(
        osl.seen, (address, readwrite)
    )


    @testset "ObservedArray construct int undef" begin
        using ChronoSim.ObservedState
        cnt = 5
        arr = ObservedArray{Int,Member}(undef, cnt)
        for idx in 1:cnt
            arr[idx] = -idx
        end
        for ridx in 1:cnt
            @test arr[ridx] == -ridx
        end
    end

    @testset "ObservedVector construct int undef" begin
        using ChronoSim.ObservedState
        cnt = 5
        arr = ObservedVector{Int,Member}(undef, cnt)
        for idx in 1:cnt
            arr[idx] = -idx
        end
        for ridx in 1:cnt
            @test arr[ridx] == -ridx
        end
    end

    @testset "ObservedMatrix construct int undef" begin
        using ChronoSim.ObservedState
        cnt = 5
        arr = ObservedMatrix{Int,Member}(undef, cnt, cnt)
        for idx in 1:cnt, jdx in 1:cnt
            arr[idx, jdx] = -idx
        end
        for ridx in 1:cnt, sidx in 1:cnt
            @test arr[ridx, sidx] == -ridx
        end
    end

    @testset "ObservedArray smoke 1D" begin
        using ChronoSim.ObservedState
        Contained1D = ObserveContained{Int}
        cnt = 32
        arr = ObservedArray{Contained1D,Member}(undef, cnt)
        for init in eachindex(arr)
            arr[init] = Contained1D(-init)
        end
        for i in eachindex(arr)
            @test getproperty(arr[i], :_address).index == i
            @test getproperty(arr[i], :_address).container == arr
            @test arr[i].val == -i
        end
        @test length(arr) == cnt
        @test size(arr, 1) == cnt
        @test size(arr) == (cnt,)
    end

    @testset "ObservedArray smoke 2D" begin
        using ChronoSim.ObservedState
        Contained2D = ObserveContained{NTuple{2,Int64}}
        dims = (4, 2)
        arr = ObservedArray{Contained2D,Member}(undef, dims...)
        # for init in eachindex(arr)
        init = 1
        for idx in CartesianIndices(arr)
            arr[idx] = Contained2D(-init)
            init += 1
        end
        # This is linear indexing.
        for i in eachindex(arr)
            @test typeof(i) == Int64
            @test getproperty(arr[i], :_address).container == arr
            @test arr[i].val == -i
        end
        # This gives you the 2D indices.
        for idx in CartesianIndices(arr)
            @test getproperty(arr[idx], :_address).index == Tuple(idx)
        end
        @test arr[1, 2].val == -5
        @test length(arr) == dims[1] * dims[2]
        @test size(arr, 1) == dims[1]
        @test size(arr, 2) == dims[2]
        @test size(arr) == dims
    end


    @testset "ObservedState 1D push!" begin
        using ChronoSim.ObservedState
        Contained1D = ObserveContained{Int}
        cnt = 32
        arr = ObservedArray{Contained1D,Member}(undef, cnt)
        for init in eachindex(arr)
            arr[init] = Contained1D(-init)
        end
        push!(arr, Contained1D(42))
        @assert length(arr) == cnt + 1
        @assert arr[cnt + 1]._address.index == cnt + 1
        @assert arr[cnt + 1].val == 42
    end


    @testset "ObservedState 1D pop!" begin
        using ChronoSim.ObservedState
        Contained1D = ObserveContained{Int}
        cnt = 32
        arr = ObservedArray{Contained1D,Member}(undef, cnt)
        for init in eachindex(arr)
            arr[init] = Contained1D(-init)
        end
        pop!(arr)
        @assert length(arr) == cnt - 1
    end


    @testset "keyedby macro" begin
        using ChronoSim.ObservedState

        # Test 1D indexing
        @keyedby MyElement1D Int64 begin
            val::Int64
            name::String
        end

        arr1d = ObservedArray{MyElement1D,Member}(undef, 5)
        for i in 1:5
            arr1d[i] = MyElement1D(i * 10, "item$i")
        end

        # Test that fields are properly set
        elem = arr1d[3]
        @test elem.val == 30
        @test elem.name == "item3"
        @test elem._address.index == 3
        @test elem._address.container === arr1d

        # Test 2D indexing
        @keyedby MyElement2D NTuple{2,Int64} begin
            value::Float64
            active::Bool
        end

        arr2d = ObservedArray{MyElement2D,Member}(undef, 2, 3)
        for j in 1:3, i in 1:2
            arr2d[i, j] = MyElement2D(i + j * 0.1, iseven(i + j))
        end

        # Test Cartesian indexing
        elem2d = arr2d[2, 3]
        @test elem2d.value ≈ 2.3
        @test elem2d.active == false  # 2 + 3 = 5, which is odd
        @test elem2d._address.index == (2, 3)
        @test elem2d._address.container === arr2d

        # Test linear indexing on 2D array
        elem2d_linear = arr2d[4]  # Linear index 4 corresponds to [2, 2] in column-major order
        @test elem2d_linear._address.index == (2, 2)
        @test elem2d_linear.value ≈ 2.2
    end

    @testset "ObservedVector push!" begin
        arr = ObservedVector{Int,Member}(undef, 0)
        base = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(arr._address, base, Member(:myarray))

        push!(arr, 20)
        @test base.seen[1][1] == (Member(:myarray), 1)
        @test base.seen[1][2] == :write
    end

    @testset "ObservedVector pop!" begin
        arr = ObservedVector{Int,Member}([100, 200, 300, 400])
        base = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(arr._address, base, Member(:myarray))

        initial_notifications = length(base.seen)

        for expected_value in [400, 300, 200]
            current_length = length(arr)
            result = pop!(arr)
            @test result == expected_value
            @test length(arr) == current_length - 1
            # Check that pop! triggered a write notification
            @test base.seen[end][1] == (Member(:myarray), current_length)
            @test base.seen[end][2] == :write
        end

        @test length(arr) == 1
        @test arr[1] == 100
    end

    @testset "ObservedVector pushfirst!" begin
        arr = ObservedVector{Int,Member}()
        base = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(arr._address, base, Member(:myarray))

        pushfirst!(arr, 24)
        @test base.seen[1][2] == :write
        @test arr[1] == 24
        @test base.seen[2][2] == :read
    end

    @testset "ObservedVector popfirst!" begin
        arr = ObservedVector{Int,Member}([1000, 2000, 3000, 4000])
        base = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(arr._address, base, Member(:myarray))

        initial_notifications = length(base.seen)

        for expected_value in [1000, 2000]
            result = popfirst!(arr)
            @test result == expected_value
            # popfirst! should trigger write notifications for remaining elements
            # because they all shift positions
        end

        @test length(arr) == 2
        @test arr == [3000, 4000]
        # Verify we got write notifications after initial count
        @test length(base.seen) > initial_notifications
    end

    @testset "ObservedVector append!" begin
        arr = ObservedVector{Int,Member}([1, 2])
        base = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(arr._address, base, Member(:myarray))

        initial_notifications = length(base.seen)

        append!(arr, [3, 4])
        @test length(arr) == 4
        @test arr == [1, 2, 3, 4]
        # Check that append! triggered write notifications for new elements
        @test length(base.seen) > initial_notifications

        append!(arr, [5])
        @test length(arr) == 5
        @test arr[5] == 5
    end

    @testset "ObservedVector resize!" begin
        arr = ObservedVector{Int,Member}([10, 20, 30, 40, 50])
        base = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(arr._address, base, Member(:myarray))

        initial_notifications = length(base.seen)

        # Test shrinking
        resize!(arr, 3)
        @test length(arr) == 3
        @test arr == [10, 20, 30]

        # Test growing
        resize!(arr, 6)
        @test length(arr) == 6
        # First 3 elements should remain
        @test arr[1:3] == [10, 20, 30]

        # Verify write notifications were triggered
        @test length(base.seen) > initial_notifications
    end

    @testset "ObservedArray isempty operations" begin
        # Test with empty array
        empty_arr = ObservedVector{Int,Member}()
        base1 = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(empty_arr._address, base1, Member(:empty_array))

        @test isempty(empty_arr) == true

        # Test with non-empty array
        full_arr = ObservedVector{Int,Member}([1, 2, 3])
        base2 = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(full_arr._address, base2, Member(:full_array))

        initial_notifications = length(base2.seen)
        @test isempty(full_arr) == false

        # isempty is read-only, so no additional notifications
        @test length(base2.seen) == initial_notifications
    end

    @testset "ObservedArray axes operations" begin
        arr_1d = ObservedVector{Int,Member}([1, 2, 3, 4])
        arr_2d = ObservedMatrix{Int,Member}(reshape(1:6, 2, 3))

        base1 = ObsArrayListen(Any[])
        base2 = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(arr_1d._address, base1, Member(:array1d))
        ChronoSim.ObservedState.update_index(arr_2d._address, base2, Member(:array2d))

        initial_notifications_1d = length(base1.seen)
        initial_notifications_2d = length(base2.seen)

        # Test axes for 1D array
        @test axes(arr_1d) == (1:4,)
        @test axes(arr_1d, 1) == 1:4

        # Test axes for 2D array
        @test axes(arr_2d) == (1:2, 1:3)
        @test axes(arr_2d, 1) == 1:2
        @test axes(arr_2d, 2) == 1:3

        # axes is read-only, so no additional notifications
        @test length(base1.seen) == initial_notifications_1d
        @test length(base2.seen) == initial_notifications_2d
    end

    @testset "ObservedArray iterate operations" begin
        arr = ObservedVector{Int,Member}([10, 20, 30])
        base = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(arr._address, base, Member(:myarray))

        initial_notifications = length(base.seen)

        # Test manual iteration
        state = iterate(arr)
        values_collected = []
        while state !== nothing
            value, next_state = state
            push!(values_collected, value)
            state = iterate(arr, next_state)
        end

        @test values_collected == [10, 20, 30]

        # Test for-loop iteration
        for_loop_values = []
        for value in arr
            push!(for_loop_values, value)
        end

        @test for_loop_values == [10, 20, 30]

        # iterate is read-only, so no additional notifications
        @test length(base.seen) == initial_notifications
    end

    @testset "ObservedVector constructor variations" begin
        # Test ObservedVector constructor with generator
        arr1 = ObservedVector{Int,Member}(x*2 for x in 1:4)
        base1 = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(arr1._address, base1, Member(:gen_array))

        @test length(arr1) == 4
        @test arr1 == [2, 4, 6, 8]

        # Test ObservedVector constructor with array
        arr2 = ObservedVector{Int,Member}([100, 200, 300])
        base2 = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(arr2._address, base2, Member(:array_array))

        @test length(arr2) == 3
        @test arr2 == [100, 200, 300]

        # Test ObservedMatrix constructor with generator
        arr3 = ObservedMatrix{Int,Member}(i+j for i in 1:2, j in 1:3)
        base3 = ObsArrayListen(Any[])
        ChronoSim.ObservedState.update_index(arr3._address, base3, Member(:matrix_gen))

        @test size(arr3) == (2, 3)
        @test arr3[1, 1] == 2  # 1+1
        @test arr3[2, 3] == 5  # 2+3

        # Test that all constructors properly initialize the address
        @test isa(arr1._address, ChronoSim.ObservedState.Address{Member})
        @test isa(arr2._address, ChronoSim.ObservedState.Address{Member})
        @test isa(arr3._address, ChronoSim.ObservedState.Address{Member})
    end

    @testset "ObservedArray IndexStyle verification" begin
        arr_1d = ObservedVector{Int,Member}([1, 2, 3])
        arr_2d = ObservedMatrix{Int,Member}(reshape(1:6, 2, 3))

        # Test that IndexStyle is properly forwarded
        @test IndexStyle(arr_1d) == IndexStyle([1, 2, 3])
        @test IndexStyle(arr_2d) == IndexStyle(reshape(1:6, 2, 3))

        # Should be IndexLinear for both since Array uses IndexLinear
        @test IndexStyle(arr_1d) isa IndexLinear
        @test IndexStyle(arr_2d) isa IndexLinear
    end

end
