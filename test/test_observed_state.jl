using ReTest
using ChronoSim

mutable struct ObserveContained{T}
    val::Int
    _address::ChronoSim.ObservedState.Address{T}
    ObserveContained{T}(v) where {T} = new{T}(v, ChronoSim.ObservedState.Address{T}())
end

ChronoSim.ObservedState.is_observed_container(::Type{<: ObserveContained}) = true


@testset "ObservedDict with keyedby" begin
    using ChronoSim.ObservedState

    # Define a struct with String keys
    @keyedby DictElement String begin
        value::Int
        label::String
    end

    # Create and populate the dictionary
    dict = ObservedDict{String,DictElement,Member}()
    dict["first"] = DictElement(100, "First Item")
    dict["second"] = DictElement(200, "Second Item")
    dict["third"] = DictElement(300, "Third Item")

    # Test that _container and _index are set correctly on access
    elem = dict["second"]
    @test elem.value == 200
    @test elem.label == "Second Item"
    @test elem._address.index == "second"
    @test elem._address.container === dict

    # Test updating an existing key
    dict["second"] = DictElement(250, "Updated Second")
    elem2 = dict["second"]
    @test elem2.value == 250
    @test elem2._address.index == "second"
    @test elem2._address.container === dict

    # Test delete! clears _container
    to_delete = dict["first"]
    @test to_delete._address.container === dict
    delete!(dict, "first")
    @test to_delete._address.container === nothing
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

    symdict = ObservedDict{Symbol,SymbolData,Member}()
    symdict[:alpha] = SymbolData(1.5)
    symdict[:beta] = SymbolData(2.5)

    elem_sym = symdict[:alpha]
    @test elem_sym.data == 1.5
    @test elem_sym._address.index == :alpha
    @test elem_sym._address.container === symdict
end
