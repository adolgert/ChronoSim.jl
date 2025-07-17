using ArgParse

include("ChronoSimTests.jl")

function parse_commandline()
    s = ArgParseSettings()
    @add_arg_table! s begin
        "--long"
        help = "Run long tests"
        action = :store_true
        "--verbose", "-v"
        help = "Enable verbose output"
        action = :store_true
        "pattern"
        help = "Test pattern to match"
        required = false
    end
    return parse_args(s)
end

# Parse command line arguments
parsed_args = parse_commandline()

# Extract arguments
verbose = parsed_args["verbose"] ? Inf : 0
pattern = parsed_args["pattern"]
flags = Symbol[]
parsed_args["long"] && push!(flags, :long)

# Run tests with appropriate arguments
if pattern !== nothing
    ChronoSimTests.retest(pattern; verbose=verbose, tag=flags)
else
    ChronoSimTests.retest(; verbose=verbose, tag=flags)
end
