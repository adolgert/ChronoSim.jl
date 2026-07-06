# The Quint compiler — data model (Phase 4).
#
# Pure-Julia AST→Quint compiler. This file holds the four public result/error
# structs, the toolchain descriptor, and the internal reflection-schema structs
# that `schema.jl` populates and `printer.jl`/`effects.jl`/`assemble.jl`/`trace.jl`
# consume. No `eval`, no I/O, no toolchain dependency to construct any of these.
#
# See .claude/design/phase4_design.md for the authoritative design.

export compile_quint, validate_trace, QuintCompileError
public QuintModel, QuintCompilationReport, TraceValidationReport, QuintToolchain,
    find_quint_toolchain, write_quint

########################### Internal reflection schema ###########################

# One lowered `@enum` type.
struct _EnumInfo
    name::Symbol                 # Quint type name (== Julia enum type name)
    instances::Vector{Symbol}    # constructor names, in @enum order
    jltype::Type
end

# One lowered `@keyedby` element record (or a promoted plain struct).
struct _RecordInfo
    name::Symbol                       # element type name
    fields::Vector{Symbol}             # KEPT user fields (lowerable, non-float), decl order
    ftypes::Vector{Any}                # Julia field types (kept)
    quintfields::Vector{String}        # lowered Quint field types (kept)
    collapsed::Bool                    # D7: single-kept-field collapse
    collapsed_field::Union{Nothing,Symbol}
    dropped::Vector{Symbol}            # erased fields (float / unrepresentable)
end

# One lowered `@observedphysical` field.
struct _FieldInfo
    name::Symbol            # Julia field name
    emit::Symbol            # emitted var/const name (reserved-word sanitized)
    kind::Symbol            # :scalar | :array1 | :arrayN | :dict | :set | :const | :erased
    quinttype::String       # lowered Quint type ("int -> Person", "Set[int]", "int", ...)
    eltype::Any             # Julia element/value type (records/value emitter)
    keytype::Any            # Julia key type (dict) or Int (array); nothing otherwise
    ndims::Int              # array dimensionality (0 for non-arrays)
    extent::Vector{Int}     # snapshot extents (arrays); empty otherwise
    promoted::Bool          # true when a primitive field promoted to a const (D6)
    note::String            # erasure / promotion reason for the report
end

# The whole reflected schema, built once by `_build_schema`.
struct _QuintSchema
    model::Module
    ptype::Type
    fields::Vector{_FieldInfo}          # every physical field, schema (fieldnames) order
    records::Dict{Symbol,_RecordInfo}   # element/record type name -> info
    enums::Dict{Symbol,_EnumInfo}       # enum type name -> info
    renames::Vector{Pair{Symbol,Symbol}}
end

# Emitted `var` field names (schema order). Const/erased fields excluded.
_var_fields(s::_QuintSchema) =
    Symbol[f.emit for f in s.fields if f.kind in (:scalar, :array1, :arrayN, :dict, :set)]
_field_by_name(s::_QuintSchema, name::Symbol) =
    s.fields[findfirst(f -> f.name === name, s.fields)]
_field_by_emit(s::_QuintSchema, emit::Symbol) =
    (i = findfirst(f -> f.emit === emit, s.fields); i === nothing ? nothing : s.fields[i])

########################### Compilation report ###########################

"""
    QuintCompilationReport

Per-event status and every deviation from a 1:1 transliteration. `Base.show`
prints the plan's bounded plain-text block (stable order):

    quint compilation: elevator (9 events)
      clean   : PickNewDestination CallElevator OpenElevatorDoors ...
      widened : (none)
      assumed : (none)
      skipped : (none)
      refused : (none)
    constants promoted: floor_cnt
    records collapsed : ElevatorCall -> requested
    fields erased     : (none)
    invariants        : 8 compiled, 0 refused
    widenings total   : 0 (v1 refuses where the design allowed widening; markers reserved)
"""
struct QuintCompilationReport
    model::Symbol
    events::Vector{NamedTuple{(:name, :status, :widenings, :reason),
                              Tuple{Symbol,Symbol,Int,String}}}
        # status ∈ :clean | :widened | :assumed_true_guard | :skipped | :refused
    widenings::Vector{NamedTuple{(:event, :reason, :source),Tuple{Symbol,String,String}}}
    promoted::Vector{Symbol}
    collapsed::Vector{Pair{Symbol,Symbol}}     # ElementType => field
    erased::Vector{String}                     # "actors[].work_age::Float64", ...
    invariants::Vector{NamedTuple{(:name, :status, :reason),Tuple{String,Symbol,String}}}
    renames::Vector{Pair{Symbol,Symbol}}
    mutated::String                            # "" or the mutation description (D16)
end

function _status_names(rep::QuintCompilationReport, status::Symbol)
    Symbol[e.name for e in rep.events if e.status === status]
end

function Base.show(io::IO, ::MIME"text/plain", rep::QuintCompilationReport)
    println(io, "quint compilation: ", rep.model, " (", length(rep.events), " events)")
    clean = _status_names(rep, :clean)
    println(io, "  clean   : ", isempty(clean) ? "(none)" : join(clean, " "))
    widened = [e for e in rep.events if e.status === :widened]
    if isempty(widened)
        println(io, "  widened : (none)")
    else
        println(io, "  widened : ",
            join(("$(e.name) ($(e.widenings): $(e.reason))" for e in widened), ", "))
    end
    assumed = _status_names(rep, :assumed_true_guard)
    println(io, "  assumed : ", isempty(assumed) ? "(none)" : join(assumed, " "))
    skipped = _status_names(rep, :skipped)
    println(io, "  skipped : ", isempty(skipped) ? "(none)" : join(skipped, " "))
    refused = _status_names(rep, :refused)
    println(io, "  refused : ", isempty(refused) ? "(none)" : join(refused, " "))
    println(io, "constants promoted: ",
        isempty(rep.promoted) ? "(none)" : join(rep.promoted, " "))
    println(io, "records collapsed : ",
        isempty(rep.collapsed) ? "(none)" :
        join(("$(p.first) -> $(p.second)" for p in rep.collapsed), ", "))
    println(io, "fields erased     : ",
        isempty(rep.erased) ? "(none)" : join(rep.erased, ", "))
    ninv = length(rep.invariants)
    nref = count(i -> i.status === :refused, rep.invariants)
    println(io, "invariants        : ", ninv - nref, " compiled, ", nref, " refused")
    if !isempty(rep.renames)
        println(io, "renamed (reserved): ",
            join(("$(p.first) -> $(p.second)" for p in rep.renames), ", "))
    end
    rep.mutated == "" || println(io, "mutated           : ", rep.mutated)
    print(io, "widenings total   : ", length(rep.widenings),
        " (v1 refuses where the design allowed widening; `// WIDENED:` markers reserved)")
end

Base.show(io::IO, rep::QuintCompilationReport) =
    print(io, "QuintCompilationReport(", rep.model, ", ", length(rep.events), " events, ",
        length(rep.widenings), " widenings)")

########################### The compiled module ###########################

"""
    QuintModel

A compiled Quint module: `name`, the module `text`, the
[`QuintCompilationReport`](@ref), and the trace-validation metadata: `varnames`
(emitted state vars, schema order), `actions::Dict{Symbol,Symbol}` (event name →
parameterized action name), `schema` (the reflection result reused by the trace
emitter), and `partial::Bool`.
"""
struct QuintModel
    name::String
    text::String
    report::QuintCompilationReport
    varnames::Vector{Symbol}
    actions::Dict{Symbol,Symbol}
    schema::_QuintSchema
    partial::Bool
end

Base.show(io::IO, qm::QuintModel) =
    print(io, "QuintModel(\"", qm.name, "\", ", length(qm.varnames), " vars, ",
        length(qm.actions), " actions", qm.partial ? ", PARTIAL" : "", ")")

"""
    write_quint(path::AbstractString, qm::QuintModel) -> path

Write the compiled module text to `path` (conventionally `<name>.qnt`).
"""
function write_quint(path::AbstractString, qm::QuintModel)
    open(path, "w") do io
        write(io, qm.text)
    end
    return String(path)
end

########################### The refusal error ###########################

"""
    QuintCompileError

All refusals from one `compile_quint` call. Each entry names the subject (event,
invariant, `@fragment` helper, or `:schema`), the offending construct, the source
location, and the category:
`:no_precondition | :no_fire | :float_read | :unclassified_loop | :rand_in_loop |
:unsupported_call | :unsupported_node | :loop_read_write_overlap | :unordered_fold |
:enum_collision | :unsupported_state | :bitwise_int | :while_loop | :early_return`.
`showerror` prints one block per entry, capped at 10 with a "+k more" line.
"""
struct QuintCompileError <: Exception
    model::Symbol
    entries::Vector{NamedTuple{(:subject, :category, :construct, :source, :hint),
                               Tuple{Symbol,Symbol,String,String,String}}}
end

function Base.showerror(io::IO, e::QuintCompileError)
    println(io, "QuintCompileError compiling model `", e.model, "`: ",
        length(e.entries), " refusal(s)")
    for (i, ent) in enumerate(Iterators.take(e.entries, 10))
        println(io, "  [", i, "] ", ent.subject, " — ", ent.category)
        println(io, "      construct: ", ent.construct)
        ent.source == "" || println(io, "      at       : ", ent.source)
        println(io, "      fix      : ", ent.hint)
    end
    n = length(e.entries)
    n > 10 && println(io, "  ... and ", n - 10, " more")
    print(io, "No .qnt was emitted; fix or opt out (skip_events / assume_true_guards) each entry.")
end

########################### Toolchain ###########################

"""
    QuintToolchain

Located checker binaries. `quint` is an `npx --prefix <dir> quint` (or bare
`quint`) `Cmd`, or `nothing`; `java_home` is a directory or `nothing`;
`versions` is filled lazily.
"""
struct QuintToolchain
    quint::Union{Nothing,Cmd}
    java_home::Union{Nothing,String}
    versions::Dict{String,String}
end

quint_available(t::QuintToolchain) = t.quint !== nothing
java_available(t::QuintToolchain) = t.java_home !== nothing

const _INSTALL_QUINT = """
    Quint not found. Install the pinned version (quint_spike/VERSIONS.md):
      npm install @informalsystems/quint@0.32.0
    then set CHRONOSIM_QUINT to the directory containing node_modules, or put
    `quint` on PATH."""

const _INSTALL_JAVA = """
    No JVM found for Apalache. Install a Temurin 17 JRE (quint_spike/VERSIONS.md):
      curl -sL -o jre.tar.gz \\
        "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.19%2B10/OpenJDK17U-jre_aarch64_mac_hotspot_17.0.19_10.tar.gz"
      tar xzf jre.tar.gz
    then set JAVA_HOME to the unpacked .../Contents/Home (or put `java` on PATH).
    The first `quint verify` downloads Apalache 0.56.1 into ~/.quint (~1 min)."""

########################### Trace validation report ###########################

"""
    TraceValidationReport

`invariants`/`transitions` verdicts (`:passed|:failed|:skipped|:error` — `:error`
means the checker itself crashed or produced unparseable output; the log tail is
in `skip_reason`), `steps_checked`, `steps_total`, `first_failure` (`nothing` or
`(step, event, when, stage)` — step 0 is the initial state; step `k` names the
recorded event whose transition/poststate failed), `skip_reason` texts, checker
log paths, wall-clock seconds. `Base.show` is the bounded block captured in the
runbook.
"""
struct TraceValidationReport
    model::Symbol
    invariants::Symbol         # :passed | :failed | :skipped | :error
    transitions::Symbol
    steps_checked::Int
    steps_total::Int
    first_failure::Union{Nothing,NamedTuple{(:step, :event, :when, :stage),
                                            Tuple{Int,Symbol,Float64,Symbol}}}
    skip_reason::Dict{Symbol,String}     # :invariants / :transitions -> text
    logs::Dict{Symbol,String}            # stage -> checker log path
    seconds::Float64
end

function _verdict_str(v::Symbol)
    v === :passed ? "PASSED" : v === :failed ? "FAILED" :
    v === :error ? "ERROR (checker crashed; see log)" : "skipped"
end

function Base.show(io::IO, ::MIME"text/plain", r::TraceValidationReport)
    println(io, "trace validation: ", r.model)
    println(io, "  steps        : ", r.steps_checked, " checked / ", r.steps_total, " total")
    println(io, "  invariants   : ", _verdict_str(r.invariants),
        haskey(r.skip_reason, :invariants) ? "  ($(first(split(r.skip_reason[:invariants], '\n'))))" : "")
    println(io, "  transitions  : ", _verdict_str(r.transitions),
        haskey(r.skip_reason, :transitions) ? "  ($(first(split(r.skip_reason[:transitions], '\n'))))" : "")
    if r.first_failure !== nothing
        ff = r.first_failure
        println(io, "  first failure: step ", ff.step, " event ", ff.event,
            " at when=", ff.when, " (", ff.stage, " stage)")
    end
    for (stage, path) in sort(collect(r.logs); by=first)
        println(io, "  log[", stage, "]  : ", path)
    end
    print(io, "  wall-clock   : ", round(r.seconds; digits=2), " s")
end

Base.show(io::IO, r::TraceValidationReport) =
    print(io, "TraceValidationReport(", r.model, ", inv=", r.invariants,
        ", trans=", r.transitions, ")")
