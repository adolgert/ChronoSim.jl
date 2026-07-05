########## The why-verbs (Phase 1e)
#
# Three diagnostic verbs that turn a recorded `TrajectorySkeleton` (1b) into
# answers. `whynot` explains a missing event by the furthest lifecycle stage it
# reached (never proposed / rejected / enabled-but-outraced / it fired),
# `whyrunning` explains a run that will not stop, and `whystopped` renders an
# ended run or an `InvariantViolation` as a bounded causal readout of
# `(address, value, writer event, time)` entries.
#
# Purely additive: no framework/policy/skeleton/replay/guard/derive/coverage
# file is edited. The verbs run offline on a finished skeleton, so the default
# execution path and the differential safety net are untouched by construction.
#
# Consumes only exported/public names from 1b-1d (TrajectorySkeleton fields,
# replay, guard_clauses, GuardEvalError, InvariantViolation fields) plus committed
# internals: placekey_mask_index, MEMBERINDEX, generators, matches_place/
# matches_event, clock_key, derivation_spec (hasmethod-gated),
# FieldBinding/LiteralIndex/TaintedIndex/TupleIndex, precondition, Member, and
# capture_state_reads. Registries are never read (they are empty at runtime for
# precompiled packages, Amendment 1); only baked/runtime accessors are used.

using OrderedCollections: OrderedSet

export whynot, whyrunning, whystopped, WhynotReport, WhyrunningReport, WhystoppedReport

public last_writer, WriterIndex, value_at

# Internal NamedTuple alias for a recorded write's provenance. Not a public name.
const LastWrite = @NamedTuple{step::Int, clock::Any, when::Float64}

########## Last-writer index

"""
    WriterIndex(skeleton) -> WriterIndex

An index over the skeleton's recorded writes (`init.changed` and every
`steps[i].changed`), built once in one pass, for repeated
[`last_writer`](@ref) queries.
"""
struct WriterIndex{CK}
    skeleton::TrajectorySkeleton{CK}
    writes::Dict{Tuple,Vector{Int}}    # address -> ascending step numbers (0 = init)
end

function WriterIndex(skel::TrajectorySkeleton{CK}) where {CK}
    writes = Dict{Tuple,Vector{Int}}()
    for a in skel.init.changed
        push!(get!(Vector{Int}, writes, a), 0)
    end
    for (i, s) in enumerate(skel.steps)
        for a in s.changed
            v = get!(Vector{Int}, writes, a)
            (isempty(v) || v[end] != i) && push!(v, i)   # dedup within a step
        end
    end
    return WriterIndex{CK}(skel, writes)
end

"""
    last_writer(skeleton, address; at_step=length(skeleton.steps))
    last_writer(index::WriterIndex, address; at_step=...)

The most recent recorded write to `address` at or before step `at_step`,
as a NamedTuple `(step, clock, when)`: `step` is 1-based into
`skeleton.steps`, with `step = 0, clock = :init` for a write by the
initializer; returns `nothing` when nothing wrote `address` in steps
`0:at_step`. Addresses compare by exact tuple equality — no index masking.
The skeleton method builds a fresh [`WriterIndex`](@ref) per call; pass an
index for repeated queries. Throws `ArgumentError` when `at_step` is outside
`0:length(skeleton.steps)`.
"""
function last_writer(wi::WriterIndex, address::Tuple;
                     at_step::Int=length(wi.skeleton.steps))
    0 <= at_step <= length(wi.skeleton.steps) || throw(ArgumentError(
        "at_step=$at_step is outside this skeleton's 0:$(length(wi.skeleton.steps)) steps"))
    v = get(wi.writes, address, nothing)
    v === nothing && return nothing
    j = searchsortedlast(v, at_step)
    j == 0 && return nothing
    i = v[j]
    i == 0 && return LastWrite((0, :init, wi.skeleton.init.when))
    s = wi.skeleton.steps[i]
    return LastWrite((i, s.clock, s.when))
end

last_writer(skel::TrajectorySkeleton, address::Tuple;
            at_step::Int=length(skel.steps)) =
    last_writer(WriterIndex(skel), address; at_step=at_step)

########## Address -> value walker

# ObservedArray records an N-dim index as one tuple component and its getindex
# splats; a Dict tuple key is one key and must NOT be splatted. Disambiguate on
# the container type: only an ObservedArray indexed by a Tuple splats.
_walk_index(cur::ObservedState.ObservedArray, c::Tuple) = cur[c...]
_walk_index(cur, c) = cur[c]

"""
    value_at(physical, address::Tuple) -> Any

Walk an ObservedState address to its current value: a `Member` component is a
field access, anything else is a container index (dict keys, integer or tuple
array indices). `value_at(physical, (Member(:person), 5, Member(:location)))`
is `physical.person[5].location`. Throws whatever the underlying access
throws (e.g. `KeyError` for a deleted dict key). Reading through `value_at`
notifies the read tracker like any other read; the framework drains that
buffer at its next capture, so simulation behavior is unaffected.
"""
function value_at(physical, address::Tuple)
    cur = physical
    for c in address
        cur = c isa Member ? getproperty(cur, c.name) : _walk_index(cur, c)
    end
    return cur
end

# value_at wrapped for diagnostic display: return the exception rather than throw.
function _safe_value(physical, address::Tuple)
    try
        return value_at(physical, address)
    catch e
        return e
    end
end

########## Report structs

"""
    WhynotReport

Result of [`whynot`](@ref). Fields, in order:

  * `clock::Any` — `clock_key` of the queried event.
  * `stage::Symbol` — `:never_proposed | :rejected | :enabled_never_fired | :fired`.
  * `nsteps::Int` — recorded steps examined (the whole skeleton).
  * `detail::NamedTuple` — stage-specific payload (schemas below).

`:never_proposed` — `(trigger_source, required, fired_triggers, true_reads,
precondition_now, missing_triggers, near_misses, near_miss_total, exact_hits,
note)`.
`trigger_source` is `:derivation_spec` or `:hand_written`; `required` is the
declared trigger addresses (derived: `evt`-bound indices substituted;
hand-written: wildcards left as the mask sentinel, printing `_index`);
`true_reads` are the precondition's reads at the final replayed state;
`precondition_now` is that evaluation's value (`Bool`, or the exception it
threw); `missing_triggers` are `true_reads` covered by no declared trigger
mask; `near_misses` is a vector of `(address, step, clock, when, class)`
NamedTuples with `class ∈ (:index_near_miss, :container_near_miss)`, capped
at 12 with the full count in `near_miss_total`; `exact_hits` (same NamedTuple
shape, `class = :exact`) holds recorded writes that exactly matched a declared
trigger — should-be-impossible generator/dedup anomalies, printed with a
warning line, never dropped.

`:rejected` — `(n_proposals, rejection_steps, examined)`. Each element of
`examined` is `(step, when, clause_analysis, verdict, clauses, failing_clause,
reads)`.

`:enabled_never_fired` — `(intervals, total_duration, n_enables, distributions,
preempted_by, sampled_time_note)`.

`:fired` — `(count, occurrences)`.
"""
struct WhynotReport
    clock::Any
    stage::Symbol
    nsteps::Int
    detail::NamedTuple
end

"""
    WhyrunningReport

Result of [`whyrunning`](@ref). Fields, in order:

  * `predicate_value::Bool` — the predicate's value now (`true` means the
    question was mistaken: the run will stop at the next check).
  * `reads::Vector` — one `(address, value, writer)` NamedTuple per address
    the predicate read, in read order.
  * `window::UnitRange{Int}` — the recorded steps summarized.
  * `top_events::Vector` — up to 5 `(event, count, writes, touches_predicate)`
    NamedTuples.
  * `predicate_writes_in_window::Vector` — `(step, clock, address)` for every
    recorded write in the window whose address exactly equals a predicate read.
  * `reachability::String` — Phase-2 stub, see [`whyrunning`](@ref).
"""
struct WhyrunningReport
    predicate_value::Bool
    reads::Vector{@NamedTuple{address::Tuple, value::Any, writer::Union{Nothing,LastWrite}}}
    window::UnitRange{Int}
    top_events::Vector{@NamedTuple{event::Symbol, count::Int, writes::Vector{Tuple}, touches_predicate::Bool}}
    predicate_writes_in_window::Vector{@NamedTuple{step::Int, clock::Any, address::Tuple}}
    reachability::String
end

"""
    WhystoppedReport

Result of [`whystopped`](@ref). Fields, in order: `kind::Symbol`
(`:invariant_violation | :end_of_run`), `invariant::Union{Nothing,String}`,
`step::Int`, `event::Any` (breaking event's clock key, or the last fired
clock), `when::Float64`, `guilty::Vector` (`(address, writer, prior_writer)`
NamedTuples; empty for `:end_of_run`), `still_enabled::Vector` (clock keys
open at the end of the skeleton; empty for `:invariant_violation`),
`verdict::Symbol` (`:invariant_violated | :no_events_enabled |
:stopped_while_events_enabled`), and `replay_command::Union{Nothing,String}`.
"""
struct WhystoppedReport
    kind::Symbol
    invariant::Union{Nothing,String}
    step::Int
    event::Any
    when::Float64
    guilty::Vector{@NamedTuple{address::Tuple, writer::Union{Nothing,LastWrite}, prior_writer::Union{Nothing,LastWrite}}}
    still_enabled::Vector{Any}
    verdict::Symbol
    replay_command::Union{Nothing,String}
end

########## Skeleton accessors (internal, exact semantics)

_stepish(skel, i) = i == 0 ? skel.init : skel.steps[i]

# All steps (0 = init) at which ck was proposed.
_proposed_steps(skel, ck) =
    [i for i in 0:length(skel.steps) if ck in _stepish(skel, i).proposed]

# Was ck committed to the sampler during stepish i?
_enabled_in(stepish, ck) = any(er.clock == ck for er in stepish.enabled)

# Rejection steps: proposed and not enabled in the same stepish. Exact within
# whynot stage 2 (ck has no EnableRecord anywhere); see design decision 3.
_rejection_steps(skel, ck) =
    [i for i in _proposed_steps(skel, ck) if !_enabled_in(_stepish(skel, i), ck)]

_fired_steps(skel, ck) = [i for (i, s) in enumerate(skel.steps) if s.clock == ck]

# Enable intervals for ck: a per-clock state machine over [init; steps...].
# Returns a vector of (open_step, open_when, close_step, close_when, close_kind).
function _enable_intervals(skel, ck)
    T = @NamedTuple{open_step::Int, open_when::Float64, close_step::Int,
                    close_when::Float64, close_kind::Symbol}
    out = T[]
    open_step = -1
    open_when = 0.0
    isopen = false
    # Step 0 (init): only rule 3 (init.disabled is always empty today).
    if _enabled_in(skel.init, ck)
        isopen = true; open_step = 0; open_when = skel.init.when
    end
    for (i, s) in enumerate(skel.steps)
        # 1. fire closes an open interval.
        if s.clock == ck && isopen
            push!(out, T((open_step, open_when, i, s.when, :fired)))
            isopen = false
        end
        # 2. disable closes an open interval.
        if isopen && ck in s.disabled
            push!(out, T((open_step, open_when, i, s.when, :disabled)))
            isopen = false
        end
        # 3. enable opens a new interval when none is open.
        if !isopen && _enabled_in(s, ck)
            isopen = true; open_step = i; open_when = s.when
        end
    end
    if isopen
        cw = isempty(skel.steps) ? skel.init.when : skel.steps[end].when
        push!(out, T((open_step, open_when, length(skel.steps), cw, :end_of_run)))
    end
    return out
end

# Preemptors of ck: for every step i where an interval was open when step i
# fired (open at entry to rule 1), count steps[i].clock[1]::Symbol.
function _preemptors(skel, ck)
    counts = Dict{Symbol,Int}()
    isopen = _enabled_in(skel.init, ck)
    for (i, s) in enumerate(skel.steps)
        fires_ck = s.clock == ck
        if isopen && !fires_ck
            sym = s.clock[1]::Symbol
            counts[sym] = get(counts, sym, 0) + 1
        end
        # advance interval state (same rule order as _enable_intervals)
        if fires_ck && isopen
            isopen = false
        end
        if isopen && ck in s.disabled
            isopen = false
        end
        if !isopen && _enabled_in(s, ck)
            isopen = true
        end
    end
    pairs = sort!(collect(counts); by=kv -> (-kv[2], string(kv[1])))
    return [k => v for (k, v) in Iterators.take(pairs, 5)]
end

# Open clocks at end (for whystopped(skeleton)).
function _open_clocks_at_end(skel::TrajectorySkeleton{CK}) where {CK}
    open = Set{CK}()
    for er in skel.init.enabled
        push!(open, er.clock)
    end
    for s in skel.steps
        delete!(open, s.clock)
        for d in s.disabled
            delete!(open, d)
        end
        for er in s.enabled
            push!(open, er.clock)
        end
    end
    return sort!(collect(Any, open); by=string)
end

########## whynot: the four-stage cascade

"""
    whynot(skeleton, sim_factory, evt::SimEvent) -> WhynotReport

Explain why `evt` did not fire during the recorded run, reported at the
furthest lifecycle stage the event reached:

  * `:never_proposed` — no generator ever proposed `clock_key(evt)`. The
    report lists the declared trigger addresses that would have to change,
    the addresses the precondition actually reads at the final replayed state
    (the true trigger set), the reads no declared trigger covers (missing
    triggers), and recorded writes that nearly matched a trigger (same
    container, different index or leaf).
  * `:rejected` — proposed but its precondition always evaluated false. The
    report replays to up to six rejection steps (first 5 and last 1) and, for
    `@precondition` events, names the failing conjunct via
    [`guard_clauses`](@ref) with the values and last writers of the
    evaluation's reads. Hand-written events get the whole-precondition verdict
    and reads; per-clause analysis requires `@precondition`.
  * `:enabled_never_fired` — enabled but always outraced: interval count and
    total enabled duration, the committed distributions, and which events
    fired while it was enabled (the preemptors).
  * `:fired` — the event did fire; the report says when.

`sim_factory` follows the [`replay`](@ref) contract:
`sim_factory(policy) -> (sim, initializer)` with the same constructor
arguments as the recorded run. `whynot` replays the skeleton (once for stage
`:never_proposed`, up to six prefixes for stage `:rejected`); a mismatch in
the factory surfaces as [`ReplayDivergence`](@ref).

The result is a [`WhynotReport`](@ref); `show` prints a plain-text readout of
at most ~30 lines.
"""
function whynot(skel::TrajectorySkeleton, sim_factory::Function, evt::SimEvent)
    ck = clock_key(evt)
    fired = _fired_steps(skel, ck)
    if !isempty(fired)
        occ = length(fired) <= 6 ? [(i, skel.steps[i].when) for i in fired] :
            vcat([(i, skel.steps[i].when) for i in fired[1:5]],
                 [(fired[end], skel.steps[fired[end]].when)])
        return WhynotReport(ck, :fired, length(skel.steps),
            (count=length(fired), occurrences=occ))
    end
    ivals = _enable_intervals(skel, ck)
    isempty(ivals) || return WhynotReport(ck, :enabled_never_fired,
        length(skel.steps), _enabled_detail(skel, ck, ivals))
    rej = _rejection_steps(skel, ck)      # == _proposed_steps here (no enables exist)
    isempty(rej) || return WhynotReport(ck, :rejected, length(skel.steps),
        _rejected_detail(skel, sim_factory, evt, ck, rej))
    return WhynotReport(ck, :never_proposed, length(skel.steps),
        _never_proposed_detail(skel, sim_factory, evt, ck))
end

########## Trigger instantiation

_subst_index(ix::FieldBinding, evt) = getfield(evt, ix.field)
_subst_index(ix::LiteralIndex, evt) = ix.value
_subst_index(::TaintedIndex, evt) = MEMBERINDEX
_subst_index(ix::TupleIndex, evt) = Tuple(_subst_index(c, evt) for c in ix.components)

# Derived: walk matchstr, consuming one index spec per MEMBERINDEX position.
function _instantiate_derived(matchstr, indices, evt)
    out = Any[]
    k = 0
    for comp in matchstr
        if comp === MEMBERINDEX
            k += 1
            push!(out, _subst_index(indices[k], evt))
        else
            push!(out, comp)
        end
    end
    return Tuple(out)
end

# Hand-written: no index spec is available (generator closures are opaque), so
# the wildcards are left as MEMBERINDEX in `required`. For the near-miss scan a
# best-effort instantiation substitutes evt's fields positionally into the
# wildcard positions ONLY when their count matches, so an index/leaf mismatch is
# classified relative to the queried instance (see design decision 6).
function _instantiate_handwritten(matchstr, evt)
    nwild = count(==(MEMBERINDEX), matchstr)
    if nwild == nfields(evt) && nwild > 0
        out = Any[]
        k = 0
        for comp in matchstr
            if comp === MEMBERINDEX
                k += 1
                push!(out, getfield(evt, k))
            else
                push!(out, comp)
            end
        end
        return Tuple(out)
    end
    return Tuple(matchstr)
end

########## Near-miss matcher

_comp_match(x, p::Member) = p === MEMBERINDEX ? !(x isa Member) : x == p
_comp_match(x, p::Tuple)  = x isa Tuple && length(x) == length(p) &&
                            all(_comp_match.(x, p))
_comp_match(x, p)         = x == p            # literal index component

_addr_match(w, a) = length(w) == length(a) && all(_comp_match.(w, a))

# Classify a recorded write w against an (instantiated) trigger target a.
# Returns :exact, :index_near_miss, :container_near_miss, or :none.
function _classify_write(w, a)
    _addr_match(w, a) && return :exact
    placekey_mask_index(w) == placekey_mask_index(a) && return :index_near_miss
    (!isempty(w) && !isempty(a) && w[1] == a[1]) && return :container_near_miss
    return :none
end

########## Stage :never_proposed

function _never_proposed_detail(skel, sim_factory, evt, ck)
    T = typeof(evt)
    derived = hasmethod(derivation_spec, Tuple{Type{T}})
    if derived
        trigger_source = :derivation_spec
        specs = derivation_spec(T)
        required = Tuple[_instantiate_derived(s.matchstr, s.indices, evt) for s in specs]
        targets = required                                    # already instantiated
        fired_triggers = Symbol[]
        note = ""
    else
        trigger_source = :hand_written
        gens = generators(T)
        required = Tuple[Tuple(g.matchstr) for g in gens if matches_place(g)]
        targets = Tuple[_instantiate_handwritten(g.matchstr, evt)
                        for g in gens if matches_place(g)]
        fired_triggers = Symbol[g.matchstr[1] for g in gens if matches_event(g)]
        note = isempty(gens) ?
            "no generators registered for this event type." :
            "trigger-set analysis is one precondition evaluation at the final " *
            "replayed state; short-circuited reads may be missing. fired() triggers " *
            "(if any) can cover reads without a place trigger. Full per-clause " *
            "analysis requires @precondition."
    end

    # True trigger set: replay to end, evaluate the real precondition once.
    sim = replay(sim_factory, skel)
    r = capture_state_reads(sim.physical) do
        try
            precondition(evt, sim.physical)
        catch e
            e
        end
    end
    true_reads = collect(Tuple, r.reads)
    precondition_now = r.result
    if precondition_now isa Exception
        note = strip(note * " precondition threw $(typeof(precondition_now)); " *
                     "true-read analysis is partial.")
    end

    declared_masks = Set(placekey_mask_index(t) for t in required)
    missing_triggers = Tuple[a for a in true_reads
                             if placekey_mask_index(a) ∉ declared_masks]

    near_misses, near_miss_total, exact_hits = _scan_near_misses(skel, targets)

    return (trigger_source=trigger_source, required=required,
            fired_triggers=fired_triggers, true_reads=true_reads,
            precondition_now=precondition_now, missing_triggers=missing_triggers,
            near_misses=near_misses, near_miss_total=near_miss_total,
            exact_hits=exact_hits, note=String(note))
end

function _scan_near_misses(skel, targets)
    NM = @NamedTuple{address::Tuple, step::Int, clock::Any, when::Float64, class::Symbol}
    hits = NM[]
    exacts = NM[]      # a recorded write exactly matched a declared trigger, yet the
                       # event was never proposed: a generator/dedup anomaly, surfaced
                       # with a warning line in show, never silently dropped.
    total = 0
    seen = Set{Tuple}()
    function consider(w, step, clock, when)
        w in seen && return nothing
        for a in targets
            cls = _classify_write(w, a)
            cls === :none && continue
            push!(seen, w)
            if cls === :exact
                push!(exacts, NM((w, step, clock, when, :exact)))
            else
                total += 1
                length(hits) < 12 && push!(hits, NM((w, step, clock, when, cls)))
            end
            return nothing
        end
        return nothing
    end
    for a in skel.init.changed
        consider(a, 0, :init, skel.init.when)
    end
    for (i, s) in enumerate(skel.steps)
        for a in s.changed
            consider(a, i, s.clock, s.when)
        end
    end
    return hits, total, exacts
end

########## Stage :rejected

function _rejected_detail(skel, sim_factory, evt, ck, rej)
    wi = WriterIndex(skel)
    examined_idx = length(rej) <= 6 ? rej : vcat(rej[1:5], rej[end])
    EX = @NamedTuple{step::Int, when::Float64, clause_analysis::Symbol, verdict::Any,
                     clauses::Vector{Tuple{String,Any}}, failing_clause::String,
                     reads::Vector{@NamedTuple{address::Tuple, value::Any,
                                               writer::Union{Nothing,LastWrite}}}}
    examined = EX[]
    for s in examined_idx
        sim = replay(sim_factory, skel; upto=s)
        when = s == 0 ? skel.init.when : skel.steps[s].when
        push!(examined, _rejection_case(sim, evt, s, when, wi))
    end
    return (n_proposals=length(rej), rejection_steps=rej, examined=examined)
end

function _rejection_case(sim, evt, step, when, wi)
    RD = @NamedTuple{address::Tuple, value::Any, writer::Union{Nothing,LastWrite}}
    local clause_analysis, clauses, failing_clause, reads_set, verdict
    try
        r = capture_state_reads(sim.physical) do
            guard_clauses(typeof(evt), evt, sim.physical)
        end
        clause_analysis = :clauses
        clauses = r.result::Vector{Tuple{String,Any}}
        reads_set = r.reads
        verdict, failing_clause = _reconstruct_verdict(clauses)
    catch e
        e isa GuardEvalError || rethrow()
        r = capture_state_reads(sim.physical) do
            try
                precondition(evt, sim.physical)
            catch pe
                pe
            end
        end
        clause_analysis = :whole_precondition
        clauses = Tuple{String,Any}[("<whole precondition>", r.result)]
        reads_set = r.reads
        verdict = r.result
        failing_clause = "<whole precondition; per-clause analysis requires @precondition>"
    end
    reads = RD[RD((a, _safe_value(sim.physical, a), last_writer(wi, a; at_step=step)))
               for a in reads_set]
    return (step=step, when=when, clause_analysis=clause_analysis, verdict=verdict,
            clauses=clauses, failing_clause=failing_clause, reads=reads)
end

# The 1c reconstruction rule: first non-`true` clause value decides.
function _reconstruct_verdict(clauses)
    for (src, v) in clauses
        v === true && continue
        return v, src
    end
    return true, ""
end

########## Stage :enabled_never_fired

function _enabled_detail(skel, ck, ivals)
    total_duration = sum((iv.close_when - iv.open_when for iv in ivals); init=0.0)
    n_enables = 0
    for i in 0:length(skel.steps)
        n_enables += count(er -> er.clock == ck, _stepish(skel, i).enabled)
    end
    dists = _distribution_summary(skel, ck)
    preempted_by = _preemptors(skel, ck)
    return (intervals=ivals, total_duration=total_duration, n_enables=n_enables,
            distributions=dists, preempted_by=preempted_by,
            sampled_time_note="not exposed by sampler (v1)")
end

function _distribution_summary(skel, ck)
    DS = @NamedTuple{name::String, params::Tuple, count::Int}
    order = Tuple{String,Tuple}[]
    counts = Dict{Tuple{String,Tuple},Int}()
    for i in 0:length(skel.steps)
        for er in _stepish(skel, i).enabled
            er.clock == ck || continue
            key = (String(nameof(typeof(er.distribution))), Distributions.params(er.distribution))
            if !haskey(counts, key)
                push!(order, key)
                counts[key] = 0
            end
            counts[key] += 1
        end
    end
    return DS[DS((nm, ps, counts[(nm, ps)])) for (nm, ps) in order]
end

########## whyrunning

"""
    whyrunning(sim, skeleton, stop_predicate; nsteps=50) -> WhyrunningReport

Explain why a run has not stopped. Evaluates `stop_predicate` on `sim`'s
current state inside `capture_state_reads` and reports every address it read,
its current value, and its last writer; then summarizes the last `nsteps`
recorded steps — the dominant event types, the addresses they rewrite, and
whether any recorded write in that window touched an address the predicate
reads. The predicate is called as `stop_predicate(physical)` when that method
exists, else as `stop_predicate(physical, step, clock, when)` (the `run` stop
condition form).

`sim` must be at the skeleton's final state (the recording sim after `run`
returned, or the result of a full [`replay`](@ref)); an `ArgumentError` is
thrown when `sim.when` disagrees with the skeleton's last step.

Static unreachability ("no event can ever write what the predicate reads") is
answered by [`can_stop_change`](@ref) when the model's event-type vector is passed
as `events` and those types carry `@fire` effect specs: the `reachability` field
then reports `:cannot_change`/`:can_change`/`:unknown`. Without `events` (or when
the types lack effect specs) the report keeps the fixed line: reachability
analysis requires effect analysis (not yet run).
"""
function whyrunning(sim::SimulationFSM, skel::TrajectorySkeleton, stop_predicate;
                    nsteps::Int=50, events=nothing)
    n = length(skel.steps)
    if n > 0 && sim.when != skel.steps[end].when
        throw(ArgumentError(
            "sim.when = $(sim.when) but the skeleton's last step is at " *
            "$(skel.steps[end].when); whyrunning needs the sim at the skeleton's " *
            "final state (the recording sim after run, or replay(sim_factory, skeleton))"))
    end
    last_ck = n == 0 ? nothing : skel.steps[end].clock
    r = capture_state_reads(sim.physical) do
        applicable(stop_predicate, sim.physical) ?
            stop_predicate(sim.physical) :
            stop_predicate(sim.physical, n, last_ck, sim.when)
    end
    r.result isa Bool || error("the stop predicate returned $(typeof(r.result)), not Bool")
    predicate_value = r.result
    wi = WriterIndex(skel)
    RD = @NamedTuple{address::Tuple, value::Any, writer::Union{Nothing,LastWrite}}
    reads = RD[RD((a, _safe_value(sim.physical, a), last_writer(wi, a))) for a in r.reads]
    predicate_read_addresses = Set{Tuple}(r.reads)
    predicate_read_masks = Set(placekey_mask_index(a) for a in r.reads)

    window = max(1, n - nsteps + 1):n

    # Recurrence summary over the window (one pass).
    counts = Dict{Symbol,Int}()
    writesets = Dict{Symbol,OrderedSet{Tuple}}()
    order = Symbol[]
    PW = @NamedTuple{step::Int, clock::Any, address::Tuple}
    predicate_writes = PW[]
    for i in window
        s = skel.steps[i]
        sym = s.clock[1]::Symbol
        if !haskey(counts, sym)
            push!(order, sym)
            counts[sym] = 0
            writesets[sym] = OrderedSet{Tuple}()
        end
        counts[sym] += 1
        for a in s.changed
            push!(writesets[sym], placekey_mask_index(a))
            a in predicate_read_addresses && push!(predicate_writes, PW((i, s.clock, a)))
        end
    end
    ranked = sort!(collect(order); by=sym -> (-counts[sym], string(sym)))
    TE = @NamedTuple{event::Symbol, count::Int, writes::Vector{Tuple}, touches_predicate::Bool}
    top_events = TE[]
    for sym in Iterators.take(ranked, 5)
        wmasks = collect(Tuple, writesets[sym])
        touches = !isdisjoint(writesets[sym], predicate_read_masks)
        push!(top_events, TE((sym, counts[sym], wmasks[1:min(4, length(wmasks))], touches)))
    end

    return WhyrunningReport(predicate_value, reads, window, top_events, predicate_writes,
        _reachability_line(sim, r.reads, events))
end

# The `reachability` field: the real `can_stop_change` verdict when `events` is
# given and at least one type carries an `effect_spec` (a partial spec set yields
# an honest :unknown naming the unanalyzed types); the Phase-2 stub only when no
# events were given or none has a spec. Kept to a single line for the line budget.
function _reachability_line(sim::SimulationFSM, reads, events)
    events === nothing && return "reachability analysis requires effect analysis (not yet run)"
    any(T -> hasmethod(effect_spec, Tuple{Type{T}}), events) ||
        return "reachability analysis requires effect analysis (not yet run)"
    sw = can_stop_change(reads, events;
        enabled_types=unique(typeof.(values(sim.enabled_events))))
    if sw.verdict === :cannot_change
        return "reachability: no event can ever write what the stop predicate reads " *
               "(the run provably cannot stop by state change)"
    elseif sw.verdict === :unknown
        return "reachability: unknown — event types lack @fire effect specs: " *
               join(sw.unanalyzed, ", ")
    else
        writers = unique(Symbol[h.event for h in sw.hits])
        base = "reachability: these event types can write a stop-predicate read: " *
               join(writers, ", ")
        return isempty(sw.enabled_hits) && !isempty(sw.disabled_hits) ?
            base * " (none currently enabled)" : base
    end
end

########## whystopped

"""
    whystopped(violation::InvariantViolation) -> WhystoppedReport
    whystopped(skeleton::TrajectorySkeleton) -> WhystoppedReport

Render why a run ended. The `InvariantViolation` method is the forensic
readout of a violation caught from a [`CheckInvariants`](@ref) run: the
invariant's name, the breaking event, each guilty address with its last
writer at the violating step and the previous writer before that step, and
the exact `replay(...)` invocation that reproduces the state one step before
the violation. The `TrajectorySkeleton` method reads out a run that ended
without an exception: the final step and time, and whether any clocks were
still enabled (stopped by the stop condition) or none were (the sampler was
exhausted).
"""
function whystopped(v::InvariantViolation)
    G = @NamedTuple{address::Tuple, writer::Union{Nothing,LastWrite},
                    prior_writer::Union{Nothing,LastWrite}}
    guilty = if v.skeleton === nothing
        G[G((a, nothing, nothing)) for a in v.guilty]
    else
        wi = WriterIndex(v.skeleton)
        at = min(v.step, length(v.skeleton.steps))
        # `at <= 0` covers both a step-0 violation and an UNSEALED skeleton (the
        # recorder placed after CheckInvariants in the stack records step-1 steps,
        # so a step-1 violation clamps to at=0): there is no step before init.
        G[G((a, last_writer(wi, a; at_step=at),
             at <= 0 ? nothing : last_writer(wi, a; at_step=at - 1)))
          for a in v.guilty]
    end
    return WhystoppedReport(:invariant_violation, v.name, v.step, v.event, v.when,
        guilty, Any[], :invariant_violated, v.replay_command)
end

function whystopped(skel::TrajectorySkeleton)
    n = length(skel.steps)
    still = _open_clocks_at_end(skel)
    verdict = isempty(still) ? :no_events_enabled : :stopped_while_events_enabled
    G = @NamedTuple{address::Tuple, writer::Union{Nothing,LastWrite},
                    prior_writer::Union{Nothing,LastWrite}}
    return WhystoppedReport(:end_of_run, nothing, n,
        n == 0 ? :init : skel.steps[end].clock,
        n == 0 ? skel.init.when : skel.steps[end].when,
        G[], collect(Any, still), verdict,
        "replay(sim_factory, skeleton)")
end

########## show formats (plain text, stable field order, <= 30 lines, no color)

_truncrepr(v) = (s = repr(v); length(s) > 40 ? first(s, 40) * "…" : s)

# Compact one-line show of a clock key tuple, e.g. (:StopElevator, 2).
_ckstr(ck) = string(ck)

function Base.show(io::IO, r::WhynotReport)
    print(io, "WhynotReport(", _ckstr(r.clock), ", stage=", r.stage, ", ",
        r.nsteps, " steps)")
end

function Base.show(io::IO, ::MIME"text/plain", r::WhynotReport)
    if r.stage === :fired
        _show_fired(io, r)
    elseif r.stage === :enabled_never_fired
        _show_enabled(io, r)
    elseif r.stage === :rejected
        _show_rejected(io, r)
    else
        _show_never_proposed(io, r)
    end
end

function _show_fired(io, r)
    d = r.detail
    println(io, "whynot ", _ckstr(r.clock), ": IT FIRED over ", r.nsteps,
        " recorded steps")
    println(io, "  fired ", d.count, " time(s); the premise was mistaken")
    for (step, when) in d.occurrences
        println(io, "    step ", step, " t=", when)
    end
    print(io, "  (question answered: this event did fire)")
end

function _show_enabled(io, r)
    d = r.detail
    println(io, "whynot ", _ckstr(r.clock), ": ENABLED BUT NEVER FIRED over ",
        r.nsteps, " recorded steps")
    println(io, "  enabled intervals    : ", length(d.intervals),
        " (total enabled duration ", d.total_duration, ")")
    for (k, iv) in enumerate(Iterators.take(d.intervals, 3))
        println(io, "  interval ", k, " : open step ", iv.open_step, " t=",
            iv.open_when, " -> closed step ", iv.close_step, " t=", iv.close_when,
            " (", iv.close_kind, ")")
    end
    length(d.intervals) > 3 && println(io, "  ... and ",
        length(d.intervals) - 3, " more intervals")
    println(io, "  enables committed    : ", d.n_enables)
    for ds in Iterators.take(d.distributions, 3)
        println(io, "  distribution         : ", ds.name, " params ", ds.params,
            " x", ds.count)
    end
    length(d.distributions) > 3 && println(io, "  ... and ",
        length(d.distributions) - 3, " more distributions")
    if isempty(d.preempted_by)
        println(io, "  preempted by (fired while enabled) : none")
    else
        println(io, "  preempted by (fired while enabled) : ",
            join(("$k $v" for (k, v) in d.preempted_by), ", "))
    end
    print(io, "  sampled firing time  : ", d.sampled_time_note)
end

function _show_rejected(io, r)
    d = r.detail
    println(io, "whynot ", _ckstr(r.clock), ": PROPOSED BUT REJECTED over ",
        r.nsteps, " recorded steps")
    println(io, "  proposals : ", d.n_proposals, ", all rejected (steps ",
        join(Iterators.take(d.rejection_steps, 6), ", "),
        length(d.rejection_steps) > 6 ? " ..." : "", ")")
    println(io, "  examined  : ", length(d.examined), " replayed case(s)",
        length(d.examined) > 2 ? "; showing first and last" : "")
    show_cases = length(d.examined) <= 2 ? d.examined :
        [d.examined[1], d.examined[end]]
    for case in show_cases
        println(io, "  -- rejection at step ", case.step, ", t=", case.when, " --")
        if case.verdict === true
            println(io, "  !! precondition is TRUE on the replayed state, which",
                " contradicts the recorded rejection;")
            println(io, "  !! the sim_factory likely rebuilt a different model")
        else
            println(io, "  failing clause : ", case.failing_clause)
        end
        println(io, "  clauses : ",
            join(("$src = $(_truncrepr(v))" for (src, v) in case.clauses), " | "))
        println(io, "  reads (", case.clause_analysis === :clauses ?
            "whole precondition evaluation" : "whole precondition", "):")
        for rd in Iterators.take(case.reads, 4)
            w = rd.writer === nothing ? "none" :
                (rd.writer.clock === :init ? "init" : _ckstr(rd.writer.clock))
            println(io, "    ", rd.address, " = ", _truncrepr(rd.value),
                " | writer: ", w)
        end
    end
    print(io, "")
end

# Print an address list packed `per` addresses per line, capped at `cap` with an
# explicit "... and N more" overflow line. Worst case: cld(cap, per) + 1 lines.
function _print_packed(io, addrs, cap; per=3, indent="    ")
    shown = collect(Any, Iterators.take(addrs, cap))
    for chunk in Iterators.partition(shown, per)
        println(io, indent, join((string(a) for a in chunk), " | "))
    end
    length(addrs) > cap && println(io, indent, "... and ", length(addrs) - cap, " more")
end

# Line budget (hard cap 30 newlines). Worst case: 1 header + 1 declared header +
# 3 required (2 packed + overflow) + 1 fired-event + 1 precondition + 2 bang +
# 2 exact-hit anomaly + 1 reads header + 3 reads + 1 MISSING header + 3 missing +
# 1 near-miss header + 4 near-misses + trailing note print (no newline) =
# 24 newlines.
function _show_never_proposed(io, r)
    d = r.detail
    println(io, "whynot ", _ckstr(r.clock), ": NEVER PROPOSED over ", r.nsteps,
        " recorded steps")
    println(io, "  declared triggers (", d.trigger_source, "):")
    _print_packed(io, d.required, 6)
    println(io, "  fired-event triggers : ",
        isempty(d.fired_triggers) ? "none" : join(d.fired_triggers, ", "))
    pn = d.precondition_now
    println(io, "  precondition at final replayed state : ",
        pn isa Exception ? "threw $(typeof(pn))" : string(pn))
    if pn === true
        println(io, "    !! the precondition holds now, yet the event was never proposed:")
        println(io, "    !! a trigger for one of the MISSING addresses below is required")
    end
    if !isempty(d.exact_hits)
        println(io, "    !! ", length(d.exact_hits), " recorded write(s) exactly matched",
            " a declared trigger yet the event was never")
        println(io, "    !! proposed (generator or dedup anomaly), first: ",
            d.exact_hits[1].address)
    end
    println(io, "  precondition reads (true trigger set) :")
    _print_packed(io, d.true_reads, 6)
    if isempty(d.missing_triggers)
        println(io, "  MISSING triggers (reads no declared trigger covers) : none")
    else
        println(io, "  MISSING triggers (reads no declared trigger covers) :")
        _print_packed(io, d.missing_triggers, 6)
    end
    println(io, "  near-miss writes (same container, different index/leaf) : ",
        d.near_miss_total, " total")
    for nm in Iterators.take(d.near_misses, 4)
        cl = nm.clock === :init ? "init" : _ckstr(nm.clock)
        println(io, "    step ", nm.step, " ", cl, " wrote ", nm.address,
            "  [", nm.class, "]")
    end
    print(io, "  note: ",
        length(d.note) > 200 ? first(d.note, 200) * "…" : d.note)
end

function Base.show(io::IO, r::WhyrunningReport)
    print(io, "WhyrunningReport(predicate=", r.predicate_value, ", ",
        length(r.reads), " reads, window=", r.window, ")")
end

function Base.show(io::IO, ::MIME"text/plain", r::WhyrunningReport)
    println(io, "whyrunning over window ", r.window, "; stop predicate is ",
        r.predicate_value)
    if r.predicate_value
        println(io, "  the stop predicate is TRUE at this state; the run stops at the next check")
    end
    println(io, "  predicate reads:")
    for rd in Iterators.take(r.reads, 6)
        w = rd.writer === nothing ? "none" :
            (rd.writer.clock === :init ? "init" : _ckstr(rd.writer.clock))
        println(io, "    ", rd.address, " = ", _truncrepr(rd.value), " | writer: ", w)
    end
    length(r.reads) > 6 && println(io, "    ... and ", length(r.reads) - 6, " more")
    println(io, "  recurrence over steps ", r.window, ":")
    for te in r.top_events
        wr = isempty(te.writes) ? "(no writes)" : join(te.writes, ", ")
        println(io, "    ", te.event, "  ", te.count, " | writes ", wr,
            " | predicate: ", te.touches_predicate ? "TOUCHED" : "untouched")
    end
    if isempty(r.predicate_writes_in_window)
        println(io, "  predicate reads written in this window : none")
    else
        println(io, "  predicate reads written in this window : ",
            length(r.predicate_writes_in_window))
        for pw in Iterators.take(r.predicate_writes_in_window, 4)
            println(io, "    step ", pw.step, " ", _ckstr(pw.clock), " wrote ", pw.address)
        end
    end
    print(io, "  ", r.reachability)
end

function Base.show(io::IO, r::WhystoppedReport)
    if r.kind === :invariant_violation
        print(io, "WhystoppedReport(invariant_violation, ",
            repr(r.invariant), ", step ", r.step, ")")
    else
        print(io, "WhystoppedReport(end_of_run, step ", r.step, ", ", r.verdict, ")")
    end
end

function Base.show(io::IO, ::MIME"text/plain", r::WhystoppedReport)
    if r.kind === :invariant_violation
        _show_violation(io, r)
    else
        _show_end_of_run(io, r)
    end
end

function _show_violation(io, r)
    println(io, "whystopped: invariant ", repr(r.invariant), " is false")
    println(io, "  step   : ", r.step, r.step == 0 ? " (init)" : " (fires since init)")
    println(io, "  event  : ", _ckstr(r.event))
    println(io, "  when   : ", r.when)
    println(io, "  guilty : ", length(r.guilty), " address(es)")
    for g in Iterators.take(r.guilty, 4)
        println(io, "    ", g.address)
        println(io, "      last writer  : ", _writestr(g.writer))
        println(io, "      prior writer : ", _writestr(g.prior_writer))
    end
    length(r.guilty) > 4 && println(io, "    ... and ", length(r.guilty) - 4, " more")
    print(io, "  replay : ", r.replay_command === nothing ?
        "no skeleton recorded" : r.replay_command)
end

function _show_end_of_run(io, r)
    println(io, "whystopped: the run ended without an exception")
    println(io, "  steps  : ", r.step)
    println(io, "  last event : ", r.step == 0 ? "none (no steps)" : _ckstr(r.event))
    println(io, "  when   : ", r.when)
    if r.verdict === :no_events_enabled
        println(io, "  no events were enabled when the run ended (sampler exhausted)")
    else
        println(io, "  ", length(r.still_enabled),
            " clock(s) were still enabled; the run ended by its stop condition")
        for ck in Iterators.take(r.still_enabled, 5)
            println(io, "    ", _ckstr(ck))
        end
        length(r.still_enabled) > 5 && println(io, "    ... and ",
            length(r.still_enabled) - 5, " more")
    end
    print(io, "  replay : ", r.replay_command)
end

function _writestr(w::Nothing)
    return "none"
end
function _writestr(w)
    w.clock === :init && return "init"
    return string("step ", w.step, " ", _ckstr(w.clock), " t=", w.when)
end
