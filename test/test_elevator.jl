using Logging
using ReTest
include("elevator.jl")

@testset "Elevator smoke" begin
    using .ElevatorExample
    with_logger(ConsoleLogger(stderr, Logging.Info)) do
        run_duration = ElevatorExample.run_elevator()
        @assert run_duration > 9.9
    end
end

@testset "Elevator tlaplus" begin
    using .ElevatorExample
    with_logger(ConsoleLogger(stderr, Logging.Info)) do
        ElevatorExample.run_with_trace()
    end
end
