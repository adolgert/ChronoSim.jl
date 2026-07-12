using ReTest
using ChronoSim
using ChronoSim.ObservedState
using Distributions
using Random
using ForwardDiff
import ChronoSim: precondition, generators, enable, fire!

# =============================================================================
# Phase OB-3b: event entries and the parameter binding (design doc Section 6).
# The model's event list carries FAMILY values (entries); a bare type is the
# all-defaults family. An entry binds the event type's FORMAL parameter names
# (the `param_names` trait) to the model's global ACTUAL θ names, resolved to
# integer indices at construction; at enabling time the event receives a
# NamedTuple view of exactly the bound components through the existing θ seam.
# The entry's `memory` slot overrides the `memory_policy` trait per model.
# These tests pin: the self-enforcing named view (13), bit-for-bit passthrough
# migration (14), renaming at the entry (15), the memory override/trait
# layering (16), type stability of the view, and the construction validations.
# =============================================================================

# A counting-clock model whose events read parameters BY NAME through the
# binding. `Tick` reads the formal it declared; `BadTick` declares :rate but
# its enable reads .other -- the deliberate under/over-declaration mismatch the
# named view must turn into an immediate field error rather than a silent bias.
module EntryBind
using ChronoSim, ChronoSim.ObservedState, Distributions
import ChronoSim: precondition, generators, enable, fire!, param_names
@keyedby Cell Int64 begin
    n::Int64
end
@observedphysical Board begin
    cell::ObservedVector{Cell,Member}
end
function Board(n::Int)
    m = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Cell(0)
    end
    return Board(m)
end
# The rate the enable actually saw, recorded so a test can assert WHICH global
# θ component the identity binding resolved to. Not physical state; a plain Ref.
const SEEN_RATE = Base.RefValue{Any}(nothing)
struct Tick <: SimEvent
    idx::Int64
end
param_names(::Type{Tick}) = (:rate,)
@precondition precondition(e::Tick, s) = s.cell[e.idx].n >= 0
enable(::Tick, s, p, when) = (SEEN_RATE[] = p.rate; (Exponential(inv(p.rate)), when))
fire!(e::Tick, s, when, rng) = (s.cell[e.idx].n += 1; nothing)
struct BadTick <: SimEvent
    idx::Int64
end
param_names(::Type{BadTick}) = (:rate,)
@precondition precondition(e::BadTick, s) = s.cell[e.idx].n >= 0
# WRONG on purpose: reads a name its binding never granted.
enable(::BadTick, s, p, when) = (Exponential(inv(p.other)), when)
fire!(e::BadTick, s, when, rng) = (s.cell[e.idx].n += 1; nothing)
init!(s, when, rng) = (s.cell[1].n = 0; nothing)
end # module

# The passthrough (migration) model: positional θ reads through the WHOLE
# vector, no `param_names` trait, so entries must hand it the very same object
# the pre-entry engine did. `SEEN` records the θ object enable received.
module EntryPass
using ChronoSim, ChronoSim.ObservedState, Distributions
import ChronoSim: precondition, generators, enable, fire!
@keyedby Cell Int64 begin
    a::Int64
    b::Int64
end
@observedphysical Board begin
    cell::ObservedVector{Cell,Member}
end
function Board(n::Int)
    m = ObservedArray{Cell,Member}(undef, n)
    for i in eachindex(m)
        m[i] = Cell(0, 0)
    end
    return Board(m)
end
const SEEN = Base.RefValue{Any}(nothing)
struct FireA <: SimEvent
    idx::Int64
end
@precondition precondition(e::FireA, s) = s.cell[e.idx].a >= 0
enable(::FireA, s, θ, when) = (SEEN[] = θ; (Exponential(inv(θ[1])), when))
fire!(e::FireA, s, when, rng) = (s.cell[e.idx].a += 1; nothing)
struct FireB <: SimEvent
    idx::Int64
end
@precondition precondition(e::FireB, s) = s.cell[e.idx].b >= 0
enable(::FireB, s, θ, when) = (Exponential(inv(θ[2])), when)
fire!(e::FireB, s, when, rng) = (s.cell[e.idx].b += 1; nothing)
init!(s, when, rng) = (s.cell[1].a = 0; s.cell[1].b = 0; nothing)
end # module

# --- test 16's pausable job, split so ONE type name carries TWO traits --------
# The completion clock is a Weibull (memory is invisible on an exponential), a
# one-shot Pause disables it mid-flight, and Resume re-enables it. The two
# Complete types live in different modules but share the NAME :Complete, so
# their clock keys -- and therefore their per-clock random streams at a common
# seed -- are IDENTICAL. That makes "entry override on the :fresh-trait type"
# vs "silent entry on the :resume-trait type" comparable bit-for-bit.
module EntryMemShared
using ChronoSim, ChronoSim.ObservedState, Distributions
import ChronoSim: precondition, generators, enable, fire!
@enum JPhase jrunning jpaused jjdone
@keyedby MJob Int64 begin
    phase::JPhase
    budget::Int64
end
@observedphysical MWorld begin
    job::ObservedVector{MJob,Member}
end
function MWorld(n::Int)
    m = ObservedArray{MJob,Member}(undef, n)
    for i in eachindex(m)
        m[i] = MJob(jjdone, 0)
    end
    return MWorld(m)
end
struct Pause <: SimEvent
    idx::Int64
end
@precondition precondition(e::Pause, s) = s.job[e.idx].phase == jrunning && s.job[e.idx].budget > 0
enable(e::Pause, s, when) = (Exponential(1 / 0.7), when)
fire!(e::Pause, s, when, rng) = (s.job[e.idx].phase = jpaused; s.job[e.idx].budget -= 1; nothing)
struct Resume <: SimEvent
    idx::Int64
end
@precondition precondition(e::Resume, s) = s.job[e.idx].phase == jpaused
enable(e::Resume, s, when) = (Exponential(1 / 1.1), when)
fire!(e::Resume, s, when, rng) = (s.job[e.idx].phase = jrunning; nothing)
init!(s, when, rng) = (s.job[1].phase = jrunning; s.job[1].budget = 1; nothing)
end # module

module EntryMemFresh
using ChronoSim, Distributions
import ChronoSim: precondition, generators, enable, fire!
using ..EntryMemShared: jrunning, jjdone
# Trait DEFAULT (:fresh): no memory_policy method on purpose.
struct Complete <: SimEvent
    idx::Int64
end
@precondition precondition(e::Complete, s) = s.job[e.idx].phase == jrunning
enable(e::Complete, s, when) = (Weibull(1.6, 1.5), when)
fire!(e::Complete, s, when, rng) = (s.job[e.idx].phase = jjdone; nothing)
end # module

module EntryMemResume
using ChronoSim, Distributions
import ChronoSim: precondition, generators, enable, fire!, memory_policy
using ..EntryMemShared: jrunning, jjdone
struct Complete <: SimEvent
    idx::Int64
end
@precondition precondition(e::Complete, s) = s.job[e.idx].phase == jrunning
enable(e::Complete, s, when) = (Weibull(1.6, 1.5), when)
memory_policy(::Type{Complete}) = :resume
fire!(e::Complete, s, when, rng) = (s.job[e.idx].phase = jjdone; nothing)
end # module

# --- helpers -----------------------------------------------------------------

# Forward run recording the (when, clock_key) trace, InitializeEvent skipped.
function _entry_trace(board, events, init!; seed, params=Float64[], param_names=nothing,
    stop=(p, i, e, w) -> i > 30)
    trace = Tuple{Float64,Tuple}[]
    obs = (p, w, e, c) -> (e isa ChronoSim.InitializeEvent) ? nothing :
          push!(trace, (w, clock_key(e)))
    sim = SimulationFSM(
        board, events;
        rng=Xoshiro(seed), key_type=Tuple, observer=obs, params=params,
        param_names=param_names,
    )
    ChronoSim.run(sim, init!, stop)
    return trace
end

# One pausable-job run under the given Complete FAMILY (an entry), returning
# the trace. Pause/Resume are shared bare types, so only the completion
# family's memory declaration differs between runs.
function _mem_trace(complete_family; seed)
    return _entry_trace(
        EntryMemShared.MWorld(1),
        [complete_family, EntryMemShared.Pause, EntryMemShared.Resume],
        EntryMemShared.init!;
        seed=seed, stop=(p, i, e, w) -> i > 50,
    )
end

# =============================================================================
# (13) The self-enforcing named view.
# =============================================================================

@testset "event entry: an event with a declared binding reads its parameters by name and receives only the bound components" begin
    # Global names put :rate at position TWO, so the identity binding of
    # `entry(Tick)` (formals ARE global names) must resolve by NAME, not by
    # position -- reading 2.0, not the 999.0 decoy in slot one.
    θ = [999.0, 2.0]
    EntryBind.SEEN_RATE[] = nothing
    trace = _entry_trace(
        EntryBind.Board(1), [entry(EntryBind.Tick)], EntryBind.init!;
        seed=90210, params=θ, param_names=(:other, :rate), stop=(p, i, e, w) -> i > 5,
    )
    @test !isempty(trace)
    @test EntryBind.SEEN_RATE[] === 2.0

    # The view carries ONLY the bound components: an enable that reads an
    # undeclared name dies with an immediate field error at the call -- through
    # the engine it surfaces as a ModelDefinitionError whose cause is the field
    # error, never as a silently wrong rate.
    err = try
        _entry_trace(
            EntryBind.Board(1), [entry(EntryBind.BadTick)], EntryBind.init!;
            seed=90210, params=θ, param_names=(:other, :rate), stop=(p, i, e, w) -> i > 5,
        )
        nothing
    catch e
        e
    end
    @test err isa ChronoSim.ModelDefinitionError
    @test err.cause isa FieldError

    # And bare, without the engine wrapper: property access on the view is the
    # error site itself.
    view = ChronoSim.param_view(ChronoSim.ResolvedBinding((:rate,), (2,)), θ)
    @test view == (rate=2.0,)
    @test_throws FieldError enable(EntryBind.BadTick(1), EntryBind.Board(1), view, 0.0)
end

# =============================================================================
# (14) Passthrough migration: no binding => the whole vector, bit for bit.
# =============================================================================

@testset "event entry: an event without a binding receives the whole parameter vector unchanged bit-for-bit" begin
    θ = [1.4, 2.2]
    seed = 20260712
    # The same model listed as bare TYPES and as all-default ENTRIES must
    # produce the identical seeded trajectory -- the entry layer normalizes a
    # bare type to entry(T), so the two lists are the same model.
    tr_types = _entry_trace(
        EntryPass.Board(1), [EntryPass.FireA, EntryPass.FireB], EntryPass.init!;
        seed=seed, params=θ,
    )
    EntryPass.SEEN[] = nothing
    tr_entries = _entry_trace(
        EntryPass.Board(1), [entry(EntryPass.FireA), entry(EntryPass.FireB)],
        EntryPass.init!;
        seed=seed, params=θ,
    )
    @test tr_types == tr_entries
    # The θ object the event saw is the VERY vector passed to the constructor,
    # not a copy and not a view -- identity, the strongest passthrough claim.
    @test EntryPass.SEEN[] === θ

    # Likelihood and gradient of the shared trace are bit-equal across the two
    # spellings of the event list.
    loglik(θv, evts) = trace_likelihood(
        SimulationFSM(
            EntryPass.Board(1), evts;
            seed=7, key_type=Tuple, step_likelihood=true, likelihood_eltype=eltype(θv),
        ),
        EntryPass.init!, tr_types; params=θv,
    ).loglikelihood
    ll_types = loglik(θ, [EntryPass.FireA, EntryPass.FireB])
    ll_entries = loglik(θ, [entry(EntryPass.FireA), entry(EntryPass.FireB)])
    @test ll_types === ll_entries
    g_types = ForwardDiff.gradient(
        θv -> loglik(θv, [EntryPass.FireA, EntryPass.FireB]), θ)
    g_entries = ForwardDiff.gradient(
        θv -> loglik(θv, [entry(EntryPass.FireA), entry(EntryPass.FireB)]), θ)
    @test g_types == g_entries
end

# =============================================================================
# (15) Renaming an actual at the entry redirects which θ component is read.
# =============================================================================

@testset "event entry: renaming an actual at the entry redirects which theta component the event reads without editing the event" begin
    # One event type, one θ vector, two entries that differ only in the actual
    # name the formal :rate binds. The rates differ by 10x, so the two models
    # have measurably different dynamics over the same horizon.
    θ = [0.5, 5.0]
    seed = 424242
    horizon = (p, i, e, w) -> w > 10.0
    tr_a = _entry_trace(
        EntryBind.Board(1), [entry(EntryBind.Tick; params=(rate=:a,))], EntryBind.init!;
        seed=seed, params=θ, param_names=(:a, :b), stop=horizon,
    )
    tr_b = _entry_trace(
        EntryBind.Board(1), [entry(EntryBind.Tick; params=(rate=:b,))], EntryBind.init!;
        seed=seed, params=θ, param_names=(:a, :b), stop=horizon,
    )
    @test tr_a != tr_b
    # Rate 5.0 fires about 10x more often than rate 0.5 over the same window.
    @test length(tr_b) > 2 * length(tr_a)

    # The binding is the gradient's sparsity structure, structurally: score the
    # rate=:b trace under the rate=:b model and the θ[:a] component of the
    # gradient is EXACTLY zero (the family never received it), while the θ[:b]
    # component matches the analytic exponential score n/λ - t_N.
    loglik(θv) = trace_likelihood(
        SimulationFSM(
            EntryBind.Board(1), [entry(EntryBind.Tick; params=(rate=:b,))];
            seed=7, key_type=Tuple, step_likelihood=true, likelihood_eltype=eltype(θv),
            param_names=(:a, :b),
        ),
        EntryBind.init!, tr_b; params=θv,
    ).loglikelihood
    g = ForwardDiff.gradient(loglik, θ)
    n = length(tr_b)
    tN = tr_b[end][1]
    @test g[1] == 0.0
    @test g[2] ≈ n / θ[2] - tN atol = 1e-10
end

# =============================================================================
# (16) The memory override wins; the trait applies when the entry is silent.
# =============================================================================

@testset "event entry: an entry memory override wins over the type trait and the trait applies when the entry is silent" begin
    # The two Complete types share the NAME :Complete, hence identical clock
    # keys and identical per-clock streams at a common seed, so runs are
    # comparable bit-for-bit across the trait/override combinations. Find a
    # seed whose fresh run interrupts the job (Pause, then Resume, then
    # Complete) so the memory policy genuinely acts -- deterministic search,
    # not selection on the outcome under test.
    found = nothing
    for seed in 1:20
        tr = _mem_trace(entry(EntryMemFresh.Complete); seed=seed)
        names = [k[1] for (w, k) in tr]
        ip = findfirst(==(:Pause), names)
        ir = findfirst(==(:Resume), names)
        ic = findfirst(==(:Complete), names)
        if ip !== nothing && ir !== nothing && ic !== nothing && ip < ir < ic
            found = seed
            break
        end
    end
    @test found !== nothing
    seed = found

    # All four combinations of (trait :fresh/:resume) x (entry silent/override).
    t_fresh_silent = _mem_trace(entry(EntryMemFresh.Complete); seed=seed)
    t_fresh_override = _mem_trace(entry(EntryMemFresh.Complete; memory=:resume); seed=seed)
    t_resume_silent = _mem_trace(entry(EntryMemResume.Complete); seed=seed)
    t_resume_override = _mem_trace(entry(EntryMemResume.Complete; memory=:fresh); seed=seed)

    # The trait acts when the entry is silent: fresh trait and resume trait
    # give different laws on this interrupted run.
    @test t_fresh_silent != t_resume_silent
    # The override WINS over the trait, exactly: overriding the fresh-trait
    # type to :resume reproduces the resume-trait type's run bit-for-bit, and
    # vice versa (identical streams make this an equality, not a statistic).
    @test t_fresh_override == t_resume_silent
    @test t_resume_override == t_fresh_silent
    # And the override genuinely changed its own type's behavior.
    @test t_fresh_override != t_fresh_silent
end

# =============================================================================
# Type stability and allocation of the view construction.
# =============================================================================

# @allocated measured inside a function so global-scope boxing does not count.
_view_alloc(b, θ) = @allocated ChronoSim.param_view(b, θ)

@testset "event entry: the NamedTuple parameter view is inferred concrete and allocation-free under Float64 and dual theta" begin
    b = ChronoSim.ResolvedBinding((:shape, :scale), (1, 2))
    θ = [1.5, 2.5, 9.0]
    v = @inferred ChronoSim.param_view(b, θ)
    @test v === (shape=1.5, scale=2.5)
    # Under a binding, integer indexing means "my first FORMAL", not "the
    # model's first component" -- document it as a live assertion.
    @test v[1] === v.shape
    _view_alloc(b, θ)                      # warm up compilation
    @test _view_alloc(b, θ) == 0
    # The view's eltype FOLLOWS θ's eltype: a dual θ yields a dual view, which
    # is what lets ForwardDiff flow through a bound family.
    θd = [ForwardDiff.Dual{:obt}(1.5, 1.0), ForwardDiff.Dual{:obt}(2.5, 0.0)]
    vd = @inferred ChronoSim.param_view(b, θd)
    @test vd.shape === θd[1]
    @test vd.scale === θd[2]
    _view_alloc(b, θd)
    @test _view_alloc(b, θd) == 0
    # Passthrough is the identity, not a copy.
    @test ChronoSim.param_view(nothing, θ) === θ
end

# =============================================================================
# Construction-time validation.
# =============================================================================

@testset "event entry: listing the same event type twice throws an error naming the parametric-type workaround" begin
    err = try
        SimulationFSM(
            EntryPass.Board(1), [entry(EntryPass.FireA), entry(EntryPass.FireA)];
            seed=1, key_type=Tuple,
        )
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("parametric", err.msg)
    @test occursin("FireA", err.msg)
end

@testset "event entry: a declared binding without global parameter names throws a clear construction error" begin
    err = try
        SimulationFSM(
            EntryBind.Board(1), [entry(EntryBind.Tick)];
            seed=1, key_type=Tuple,
        )
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("param_names", err.msg)
    @test occursin("global parameter names", err.msg)
end

@testset "event entry: the entry constructor validates its memory and params declarations eagerly" begin
    # An unknown memory value is refused at entry construction, not at run time.
    @test_throws ArgumentError entry(EntryBind.Tick; memory=:sticky)
    # A binding key must be one of the type's declared formals.
    @test_throws ArgumentError entry(EntryBind.Tick; params=(pace=:a,))
    # Binding a type that declares no formals has nothing to bind.
    @test_throws ArgumentError entry(EntryPass.FireA; params=(rate=:a,))
    # Binding values must be Symbols naming global components.
    @test_throws ArgumentError entry(EntryBind.Tick; params=(rate=1,))
    # The all-defaults entry is what a bare type normalizes to.
    e = entry(EntryBind.Tick)
    @test e.memory === nothing && e.params === nothing
    @test ChronoSim.event_type(e) === EntryBind.Tick
    # An actual name missing from the global list is refused at resolution.
    @test_throws ArgumentError ChronoSim.resolve_entries(
        [entry(EntryBind.Tick; params=(rate=:missing_name,))], (:a, :b))
end
