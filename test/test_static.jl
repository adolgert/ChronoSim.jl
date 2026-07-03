using ReTest
using Aqua

@testset "Look at method ambiguities" begin
    using Aqua
    # Disabling dependency compatibility because it's giving spurious output.
    # persistent_tasks spawns a subprocess that reloads the package; it flakes in
    # sandboxed CI ("done.log was not created, but precompilation exited") for
    # reasons unrelated to whether ChronoSim leaves tasks running, so disable it.
    Aqua.test_all(
        ChronoSim;
        stale_deps=(ignore=[:JuliaFormatter, :Distributions, :CompetingClocks, :Logging],),
        persistent_tasks=false,
    )
end
