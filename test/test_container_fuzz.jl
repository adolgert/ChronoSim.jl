using ReTest
using ChronoSim
using ChronoSim.ObservedState
using Random

# Snapshot-diff fuzz tester for the ObservedState containers. It is the runnable
# form of docs/src/state_contract.md: random operation sequences run against each
# container, the true denotation-change set Delta is computed by diffing raw
# storage before/after each op, and the contract clauses (C1 write soundness,
# C2 address integrity, C3 address determinism, plus reported precision) are
# asserted. See the doc's final section "What the fuzzer asserts".

# A parent sink recording (address, readwrite) pairs. Every container under test
# is attached to one via `update_index(c._address, sink, Member(:root))`, so each
# recorded address is prefixed with `Member(:root)`. Mirrors ObsArrayListen /
# DictListen in the per-container tests.
struct FuzzSink
    seen::Vector{Any}
end
function ChronoSim.ObservedState.observed_notify(s::FuzzSink, address, readwrite)
    push!(s.seen, (address, readwrite))
end

# Compound element with two primitive fields. Int index type serves both the
# 1-D array (index is the slot) and the Int-keyed dict (index is the key).
@keyedby FuzzElem Int begin
    a::Int
    b::Int
end

# Over-notification tally for the precision report (clause 4, reported not asserted).
mutable struct FuzzPrec
    writes::Int
    delta::Int
    ops::Int
end

fuzz_attach(c) = begin
    s = FuzzSink(Any[])
    ChronoSim.ObservedState.update_index(c._address, s, Member(:root))
    s
end

# Strip the Member(:root) sink prefix to get a container-relative address.
fuzz_rel(addr) = addr[2:end]

# w covers a when w equals a or is a proper prefix of it. The empty tuple ()
# (whole-container write) is a prefix of everything, so it covers all of Delta
# for that container; a compound-element field flood covers each field leaf.
fuzz_isprefix(w, a) = length(w) <= length(a) && all(i -> w[i] == a[i], 1:length(w))
fuzz_covered(a, writes) = any(w -> fuzz_isprefix(w, a), writes)

# Delta: leaf addresses whose denotation changed, appeared, or disappeared.
function fuzz_delta(before, after)
    d = Set{Any}()
    for (a, v) in before
        (!haskey(after, a) || after[a] != v) && push!(d, a)
    end
    for (a, _) in after
        haskey(before, a) || push!(d, a)
    end
    return d
end

# --- leaf-denotation snapshots (read raw storage, no notifications) ---

function fuzz_snap_prim_vec(raw)
    d = Dict{Any,Any}()
    for i in eachindex(raw)
        isassigned(raw, i) && (d[(i,)] = raw[i])
    end
    return d
end

function fuzz_snap_prim_mat(raw)
    d = Dict{Any,Any}()
    ci = CartesianIndices(raw)
    for lin in eachindex(IndexLinear(), raw)
        isassigned(raw, lin) || continue
        d[(Tuple(ci[lin]),)] = raw[lin]
    end
    return d
end

function fuzz_snap_comp_vec(raw)
    d = Dict{Any,Any}()
    for i in eachindex(raw)
        isassigned(raw, i) || continue
        el = raw[i]
        d[(i, Member(:a))] = getfield(el, :a)
        d[(i, Member(:b))] = getfield(el, :b)
    end
    return d
end

function fuzz_snap_prim_dict(raw)
    d = Dict{Any,Any}()
    for (k, v) in raw
        d[(k,)] = v
    end
    return d
end

function fuzz_snap_comp_dict(raw)
    d = Dict{Any,Any}()
    for (k, el) in raw
        d[(k, Member(:a))] = getfield(el, :a)
        d[(k, Member(:b))] = getfield(el, :b)
    end
    return d
end

# A set has no addressable places: membership as a whole lives under (). Any
# change of membership is a change of denotation of that single leaf.
fuzz_snap_set(raw) = Dict{Any,Any}(() => sort(collect(raw)))

# --- element maps (slot/key => element object) for C2 integrity ---

function fuzz_elmap_vec(raw)
    m = Dict{Any,Any}()
    for i in eachindex(raw)
        isassigned(raw, i) && (m[i] = raw[i])
    end
    return m
end

fuzz_elmap_dict(raw) = Dict{Any,Any}(k => el for (k, el) in raw)

# C2: stored compound elements resolve to their slot rooted at the container;
# elements the op removed have an emptied address.
function fuzz_check_integrity(c, before_el, after_el)
    for (slot, el) in after_el
        addr = el._address
        @test addr.container === c
        @test addr.index == slot
    end
    for (slot, el) in before_el
        haskey(after_el, slot) && continue
        @test el._address.container === nothing
    end
end

# Pick an existing dict key (sorted for run-to-run determinism). Ops that need a
# present key degrade to a whole-container read when the dict is empty, keeping
# the rng draw count identical across the two C3 replays.
function fuzz_dict_present(c, rng, desc_f, act)
    ks = sort(collect(keys(getfield(c, :dict))))
    isempty(ks) && return (desc="dict-empty->length", throws=nothing, apply=() -> length(c))
    k = rand(rng, ks)
    return (desc=desc_f(k), throws=nothing, apply=() -> act(k))
end

# Run one seeded op sequence. With check=true it asserts C1/C2 and tallies
# precision; the returned notification stream lets a second check=false replay
# assert C3 by equality.
function fuzz_run_sequence(seed, nops, make, rawof, snapshot, elemmap, catalog; check, prec)
    rng = MersenneTwister(seed)
    c, sink = make()
    stream = Any[]
    for step in 1:nops
        gen = catalog[rand(rng, 1:length(catalog))]
        op = gen(c, rng)
        before = snapshot(rawof(c))
        before_el = elemmap === nothing ? nothing : elemmap(rawof(c))
        empty!(sink.seen)
        if op.throws !== nothing
            if check
                @test_throws op.throws op.apply()
                # A rejected length-change mutates nothing and notifies nothing.
                @test snapshot(rawof(c)) == before
                @test isempty(sink.seen)
            else
                try
                    op.apply()
                catch
                end
            end
        else
            op.apply()
            if check
                after = snapshot(rawof(c))
                delta = fuzz_delta(before, after)
                writes = Set{Any}(fuzz_rel(a) for (a, rw) in sink.seen if rw === :write)
                uncovered = [a for a in delta if !fuzz_covered(a, writes)]
                if !isempty(uncovered)
                    @info "C1 under-notification" seed step op.desc delta writes uncovered
                end
                @test isempty(uncovered)
                if !isempty(delta)
                    prec.writes += length(writes)
                    prec.delta += length(delta)
                    prec.ops += 1
                end
                if elemmap !== nothing
                    fuzz_check_integrity(c, before_el, elemmap(rawof(c)))
                end
            end
        end
        append!(stream, sink.seen)
    end
    return stream
end

function fuzz_class(name, base_seed, seeds, nops, make, rawof, snapshot, elemmap, catalog)
    prec = FuzzPrec(0, 0, 0)
    for s in 1:seeds
        seed = base_seed + s
        stream1 = fuzz_run_sequence(
            seed, nops, make, rawof, snapshot, elemmap, catalog; check=true, prec
        )
        stream2 = fuzz_run_sequence(
            seed, nops, make, rawof, snapshot, elemmap, catalog; check=false, prec
        )
        @test stream1 == stream2
    end
    ratio = prec.delta == 0 ? 1.0 : prec.writes / prec.delta
    @info "fuzz precision" class=name ops=prec.ops writes=prec.writes delta=prec.delta overnotify=ratio
    return nothing
end

@testset "container fuzz" begin
    long = get(ENV, "CHRONOSIM_FUZZ_LONG", "false") == "true"
    seeds = long ? 250 : 25
    nops = 60

    # --- factories: fill before attaching so the priming writes emit nothing ---
    make_prim_vec() = begin
        c = ObservedVector{Int,Member}(undef, 8)
        for i in 1:8
            c[i] = i
        end
        (c, fuzz_attach(c))
    end
    make_prim_mat() = begin
        c = ObservedMatrix{Int,Member}(undef, 3, 3)
        for k in 1:9
            c[k] = k
        end
        (c, fuzz_attach(c))
    end
    make_comp_vec() = begin
        c = ObservedArray{FuzzElem,Member}(undef, 6)
        for i in 1:6
            c[i] = FuzzElem(i, i)
        end
        (c, fuzz_attach(c))
    end
    make_prim_dict() = begin
        c = ObservedDict{Int,Int,Member}()
        for k in 1:3
            c[k] = k * 10
        end
        (c, fuzz_attach(c))
    end
    make_comp_dict() = begin
        c = ObservedDict{Int,FuzzElem,Member}()
        for k in 1:3
            c[k] = FuzzElem(k, k)
        end
        (c, fuzz_attach(c))
    end
    make_set() = begin
        c = ObservedSet{Int,Member}()
        for x in 1:3
            push!(c, x)
        end
        (c, fuzz_attach(c))
    end

    # --- operation catalogs: each gen(c, rng) => (desc, throws, apply) ---

    prim_vec_ops = [
        (c, rng) -> (
            i=rand(rng, 1:8);
            v=rand(rng, 1:5);
            (desc="pv[$i]=$v", throws=nothing, apply=() -> (c[i] = v))
        ),
        (c, rng) -> (i=rand(rng, 1:8); (desc="get pv[$i]", throws=nothing, apply=() -> c[i])),
        (c, rng) -> (
            lo=rand(rng, 1:8);
            hi=rand(rng, lo:8);
            (desc="pv[$lo:$hi]", throws=nothing, apply=() -> c[lo:hi])
        ),
        (c, rng) -> (v=rand(rng, 1:5); (desc="fill!($v)", throws=nothing, apply=() -> fill!(c, v))),
        (c, rng) -> (desc="sort!", throws=nothing, apply=() -> sort!(c)),
        (c, rng) -> (desc="iterate", throws=nothing, apply=() -> (
            for _ in c
            end
        )),
    ]

    prim_mat_ops = [
        (c, rng) -> (
            i=rand(rng, 1:3);
            j=rand(rng, 1:3);
            v=rand(rng, 1:5);
            (desc="pm[$i,$j]=$v", throws=nothing, apply=() -> (c[i, j] = v))
        ),
        (c, rng) -> (
            i=rand(rng, 1:3);
            j=rand(rng, 1:3);
            (desc="get pm[$i,$j]", throws=nothing, apply=() -> c[i, j])
        ),
        (c, rng) -> (k=rand(rng, 1:9); (desc="get pm[$k]", throws=nothing, apply=() -> c[k])),
    ]

    comp_vec_ops = [
        (c, rng) -> (
            i=rand(rng, 1:6);
            a=rand(rng, 1:5);
            b=rand(rng, 1:5);
            (desc="cv[$i]=E($a,$b)", throws=nothing, apply=() -> (c[i] = FuzzElem(a, b)))
        ),
        (c, rng) -> (
            i=rand(rng, 1:6);
            f=rand(rng, (:a, :b));
            v=rand(rng, 1:5);
            (desc="cv[$i].$f=$v", throws=nothing, apply=() -> setproperty!(c[i], f, v))
        ),
        (c, rng) -> (
            i=rand(rng, 1:6);
            f=rand(rng, (:a, :b));
            (desc="read cv[$i].$f", throws=nothing, apply=() -> getproperty(c[i], f))
        ),
        (c, rng) -> (
            lo=rand(rng, 1:6);
            hi=rand(rng, lo:6);
            (desc="cv[$lo:$hi]", throws=nothing, apply=() -> c[lo:hi])
        ),
        (c, rng) -> (desc="push!", throws=FixedExtentError, apply=() -> push!(c, FuzzElem(1, 1))),
        (c, rng) -> (desc="pop!", throws=FixedExtentError, apply=() -> pop!(c)),
        (c, rng) -> (desc="resize!", throws=FixedExtentError, apply=() -> resize!(c, 3)),
        (c, rng) -> (desc="empty!", throws=FixedExtentError, apply=() -> empty!(c)),
    ]

    prim_dict_ops = [
        (c, rng) -> (
            k=rand(rng, 1:8);
            v=rand(rng, 1:5);
            (desc="pd[$k]=$v", throws=nothing, apply=() -> (c[k] = v))
        ),
        (c, rng) -> fuzz_dict_present(c, rng, k -> "delete! pd[$k]", k -> delete!(c, k)),
        (c, rng) ->
            (k=rand(rng, 1:8); (desc="delete! pd[$k]?", throws=nothing, apply=() -> delete!(c, k))),
        (c, rng) -> fuzz_dict_present(c, rng, k -> "pop! pd[$k]", k -> pop!(c, k)),
        (c, rng) ->
            (k=rand(rng, 1:8); (desc="pop!(pd,$k,-1)", throws=nothing, apply=() -> pop!(c, k, -1))),
        (c, rng) ->
            (k=rand(rng, 1:8); (desc="get(pd,$k,-1)", throws=nothing, apply=() -> get(c, k, -1))),
        (c, rng) -> (
            k=rand(rng, 1:8);
            v=rand(rng, 1:5);
            (desc="get!(pd,$k,$v)", throws=nothing, apply=() -> get!(c, k, v))
        ),
        (c, rng) ->
            (k=rand(rng, 1:8); (desc="haskey(pd,$k)", throws=nothing, apply=() -> haskey(c, k))),
        (c, rng) -> fuzz_dict_present(c, rng, k -> "get pd[$k]", k -> c[k]),
        (c, rng) -> (desc="iterate pd", throws=nothing, apply=() -> (
            for _ in c
            end
        )),
        (c, rng) -> (desc="keys/length pd", throws=nothing, apply=() -> (keys(c); length(c))),
    ]

    comp_dict_ops = [
        (c, rng) -> (
            k=rand(rng, 1:8);
            a=rand(rng, 1:5);
            b=rand(rng, 1:5);
            (desc="cd[$k]=E($a,$b)", throws=nothing, apply=() -> (c[k] = FuzzElem(a, b)))
        ),
        (c, rng) -> fuzz_dict_present(c, rng, k -> "delete! cd[$k]", k -> delete!(c, k)),
        (c, rng) -> fuzz_dict_present(c, rng, k -> "pop! cd[$k]", k -> pop!(c, k)),
        (c, rng) -> begin
            ks = sort(collect(keys(getfield(c, :dict))))
            isempty(ks) &&
                return (desc="cd-empty->length", throws=nothing, apply=() -> length(c))
            k = rand(rng, ks)
            f = rand(rng, (:a, :b))
            v = rand(rng, 1:5)
            (desc="cd[$k].$f=$v", throws=nothing, apply=() -> setproperty!(c[k], f, v))
        end,
        (c, rng) -> begin
            ks = sort(collect(keys(getfield(c, :dict))))
            isempty(ks) &&
                return (desc="cd-empty->length", throws=nothing, apply=() -> length(c))
            k = rand(rng, ks)
            f = rand(rng, (:a, :b))
            (desc="read cd[$k].$f", throws=nothing, apply=() -> getproperty(c[k], f))
        end,
        (c, rng) -> (
            k=rand(rng, 1:8);
            (desc="pop!(cd,$k,def)", throws=nothing, apply=() -> pop!(c, k, FuzzElem(0, 0)))
        ),
    ]

    set_ops = [
        (c, rng) -> (x=rand(rng, 1:6); (desc="push!($x)", throws=nothing, apply=() -> push!(c, x))),
        (c, rng) -> begin
            xs = sort(collect(getfield(c, :set)))
            isempty(xs) &&
                return (desc="set-empty->length", throws=nothing, apply=() -> length(c))
            x = rand(rng, xs)
            (desc="pop!($x)", throws=nothing, apply=() -> pop!(c, x))
        end,
        (c, rng) ->
            (x=rand(rng, 1:6); (desc="delete!($x)", throws=nothing, apply=() -> delete!(c, x))),
        (c, rng) -> (desc="empty!", throws=nothing, apply=() -> empty!(c)),
        (c, rng) -> (
            xs=Set(rand(rng, 1:6) for _ in 1:2);
            (desc="union!($xs)", throws=nothing, apply=() -> union!(c, xs))
        ),
        (c, rng) -> (
            xs=Set(rand(rng, 1:6) for _ in 1:2);
            (desc="setdiff!($xs)", throws=nothing, apply=() -> setdiff!(c, xs))
        ),
        (c, rng) -> (x=rand(rng, 1:6); (desc="in($x)", throws=nothing, apply=() -> in(x, c))),
        (c, rng) -> (desc="length", throws=nothing, apply=() -> length(c)),
    ]

    @testset "fuzz ObservedArray primitive 1-D obeys C1/C2/C3" begin
        fuzz_class(
            "prim_vec",
            1000,
            seeds,
            nops,
            make_prim_vec,
            c -> getfield(c, :arr),
            fuzz_snap_prim_vec,
            nothing,
            prim_vec_ops,
        )
    end

    @testset "fuzz ObservedArray primitive 2-D obeys C1/C2/C3" begin
        fuzz_class(
            "prim_mat",
            2000,
            seeds,
            nops,
            make_prim_mat,
            c -> getfield(c, :arr),
            fuzz_snap_prim_mat,
            nothing,
            prim_mat_ops,
        )
    end

    @testset "fuzz ObservedArray compound 1-D obeys C1/C2/C3" begin
        fuzz_class(
            "comp_vec",
            3000,
            seeds,
            nops,
            make_comp_vec,
            c -> getfield(c, :arr),
            fuzz_snap_comp_vec,
            fuzz_elmap_vec,
            comp_vec_ops,
        )
    end

    @testset "fuzz ObservedDict primitive obeys C1/C2/C3" begin
        fuzz_class(
            "prim_dict",
            4000,
            seeds,
            nops,
            make_prim_dict,
            c -> getfield(c, :dict),
            fuzz_snap_prim_dict,
            nothing,
            prim_dict_ops,
        )
    end

    @testset "fuzz ObservedDict compound obeys C1/C2/C3" begin
        fuzz_class(
            "comp_dict",
            5000,
            seeds,
            nops,
            make_comp_dict,
            c -> getfield(c, :dict),
            fuzz_snap_comp_dict,
            fuzz_elmap_dict,
            comp_dict_ops,
        )
    end

    @testset "fuzz ObservedSet obeys C1/C2/C3" begin
        fuzz_class(
            "set",
            6000,
            seeds,
            nops,
            make_set,
            c -> getfield(c, :set),
            fuzz_snap_set,
            nothing,
            set_ops,
        )
    end

    # Documented, reproducible C1 violation: replacing a whole compound element via
    # `arr[i] = FuzzElem(...)` changes the denotation of every field of slot i but
    # Regression: the fuzzer originally caught whole-element compound setindex
    # emitting no write notification (array _setindex!(CompoundTrait) lacked the
    # notify_all flood the dict compound path performs). The fix also unroots the
    # displaced element so it cannot notify through a slot it no longer occupies.
    @testset "fuzz compound-array whole-element setindex floods fields and unroots the displaced element" begin
        c = ObservedArray{FuzzElem,Member}(undef, 3)
        for i in 1:3
            c[i] = FuzzElem(i, i)
        end
        displaced = c[2]
        sink = fuzz_attach(c)
        before = fuzz_snap_comp_vec(getfield(c, :arr))
        empty!(sink.seen)
        c[2] = FuzzElem(99, 88)
        after = fuzz_snap_comp_vec(getfield(c, :arr))
        delta = fuzz_delta(before, after)
        writes = Set{Any}(fuzz_rel(a) for (a, rw) in sink.seen if rw === :write)
        uncovered = [a for a in delta if !fuzz_covered(a, writes)]
        @test !isempty(delta)
        @test isempty(uncovered)
        @test getfield(displaced, :_address).container === nothing
        empty!(sink.seen)
        displaced.a = 7
        @test isempty(sink.seen)
    end
end
