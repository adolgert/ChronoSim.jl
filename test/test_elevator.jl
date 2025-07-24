using ReTest
include("elevator.jl")

@testset "Elevator smoke" begin
    using ElevatorExample
    ElevatorExample.run_elevator()
end
