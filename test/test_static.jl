using ReTest
using Aqua

@testset "Look at method ambiguities" begin
    using Aqua
    # Disabling dependency compatibility because it's giving spurious output.
    Aqua.test_all(
        ChronoSim;
        stale_deps=(ignore=[:JuliaFormatter, :Distributions, :CompetingClocks, :Logging],),
        )
end
