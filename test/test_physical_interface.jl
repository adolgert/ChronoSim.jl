using ChronoSim
using ReTest

@testset "Member wrapper" begin
    m = Member(:foo)
    @test isa(m, Member)
    @test m.name == :foo
end

@testset "Member equality" begin
    m = Member(:foo)
    b = Member(:bar)
    @test m != b
    n = Member(:foo)
    @test m == n
end

@testset "Member conversion" begin
    m = Member(:foo)
    @test Symbol(m) == :foo
    @test convert(Symbol, m) == :foo
end

@testset "Member show" begin
    m = Member(:example)
    io = IOBuffer()
    show(io, m)
    @test String(take!(io)) == "example"
end
