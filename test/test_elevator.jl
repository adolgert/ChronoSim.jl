using Logging
using ReTest
include("elevator.jl")

@testset "Elevator smoke" begin
    using .ElevatorExample
    with_logger(ConsoleLogger(stderr, Logging.Debug)) do
        ElevatorExample.run_elevator()
    end
end
