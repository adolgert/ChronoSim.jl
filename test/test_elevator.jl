using Logging
using ReTest
include("elevator.jl")

@testset "Elevator smoke" begin
    using .ElevatorExample
    with_logger(ConsoleLogger(stderr, Logging.Info)) do
        ElevatorExample.run_elevator()
    end
end

@testset "Elevator tlaplus" begin
    using .ElevatorExample
    with_logger(ConsoleLogger(stderr, Logging.Info)) do
        ElevatorExample.run_with_trace()
    end
end
