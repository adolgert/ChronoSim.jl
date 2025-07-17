using ChronoSim
using Documenter

DocMeta.setdocmeta!(ChronoSim, :DocTestSetup, :(using ChronoSim); recursive=true)

makedocs(;
    modules=[ChronoSim],
    authors="Andrew Dolgert <github@dolgert.com>",
    sitename="ChronoSim.jl",
    format=Documenter.HTML(;
        canonical="https://adolgert.github.io/ChronoSim.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/adolgert/ChronoSim.jl",
    devbranch="main",
)
