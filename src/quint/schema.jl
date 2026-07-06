# The Quint compiler — state-schema reflection and the init value emitter.
#
# Builds a `_QuintSchema` from the physical type by reflection only (no `eval`):
# splits fields into vars / promoted consts / erased floats, lowers element
# `@keyedby` records and `@enum`s to Quint types, applies the one-field-record
# collapse (D7), and serializes a live snapshot into `init` literals (D15) with a
# canonical key order so goldens are byte-stable.

using ..ChronoSim.ObservedState: ObservedArray, ObservedDict, ObservedSet, Param,
    ObservedPhysical

########################### Reserved-word sanitization ###########################

const _QUINT_RESERVED = Set{Symbol}([
    :val, :def, :action, :module, :type, :pure, :nondet, :all, :any, :if, :else,
    :import, :init, :step, :run, :assume, :const, :var, :Set, :List, :Map, :Int,
    :Bool, :int, :bool, :str, :and, :or, :not, :iff, :implies, :export, :from,
    :match, :temporal, :assert,
])

_is_reserved(s::Symbol) = s in _QUINT_RESERVED
_sanitize(s::Symbol) = _is_reserved(s) ? Symbol(string(s), "_") : s

########################### Type predicates ###########################

_is_enum_type(@nospecialize(T)) = T isa Type && T <: Base.Enum
_is_record_type(@nospecialize(T)) = T isa Type && T <: ObservedState.Addressed
_is_float_type(@nospecialize(T)) = T isa Type && (T === Float64 || T === Float32 || T === Float16)

# Element/field names of a `@keyedby` record, minus the address field.
_record_fields(::Type{T}) where {T} = Symbol[f for f in fieldnames(T) if f !== :_address]

########################### Enum / record collection ###########################

# Recursively collect every `@enum` and `@keyedby` type reachable from `T`.
function _scan_types!(enums::Dict{Symbol,_EnumInfo}, records::Set{Type}, @nospecialize(T))
    T isa Type || return
    if _is_enum_type(T)
        nm = nameof(T)
        haskey(enums, nm) && return
        enums[nm] = _EnumInfo(nm, Symbol[Symbol(e) for e in instances(T)], T)
        return
    elseif _is_record_type(T)
        T in records && return
        push!(records, T)
        for f in _record_fields(T)
            _scan_types!(enums, records, fieldtype(T, f))
        end
        return
    elseif T <: ObservedArray
        _scan_types!(enums, records, eltype(T))
    elseif T <: ObservedDict
        _scan_types!(enums, records, keytype(T))
        _scan_types!(enums, records, valtype(T))
    elseif T <: ObservedSet
        _scan_types!(enums, records, eltype(T))
    elseif T <: Param
        _scan_types!(enums, records, T.parameters[1])
    elseif T <: Tuple
        for P in T.parameters
            _scan_types!(enums, records, P)
        end
    elseif T <: AbstractArray
        _scan_types!(enums, records, eltype(T))
    elseif T <: AbstractSet
        _scan_types!(enums, records, eltype(T))
    end
    return
end

########################### Type lowering ###########################

struct _EnumCollision <: Exception
    value::Symbol
    a::Symbol
    b::Symbol
end

# Detect two enums sharing a constructor name (would collide as a bare Quint name).
function _check_enum_collisions(enums::Dict{Symbol,_EnumInfo})
    seen = Dict{Symbol,Symbol}()   # constructor -> enum type name
    for (ename, info) in sort(collect(enums); by=first)
        for c in info.instances
            if haskey(seen, c) && seen[c] != ename
                throw(_EnumCollision(c, seen[c], ename))
            end
            seen[c] = ename
        end
    end
    return nothing
end

struct _FloatTypeError <: Exception
    T::Type
end

# Lower a Julia type to a Quint type string. `records` may be `nothing` (during
# early scans) or the built dict (to honor collapse for value positions).
function _lower_type(s::_QuintSchema, @nospecialize(T))
    _lower_type_impl(s.records, T)
end

function _lower_type_impl(records, @nospecialize(T))
    if T === Bool
        return "bool"
    elseif T <: Integer
        return "int"
    elseif _is_enum_type(T)
        return String(nameof(T))
    elseif _is_float_type(T)
        throw(_FloatTypeError(T))
    elseif T <: Tuple
        return "(" * join((_lower_type_impl(records, P) for P in T.parameters), ", ") * ")"
    elseif T <: AbstractSet
        return "Set[" * _lower_type_impl(records, eltype(T)) * "]"
    elseif T <: ObservedSet
        return "Set[" * _lower_type_impl(records, eltype(T)) * "]"
    elseif T <: ObservedArray
        N = T.parameters[2]
        vt = _lower_value_type_impl(records, eltype(T))
        key = N == 1 ? "int" : "(" * join(fill("int", N), ", ") * ")"
        return key * " -> " * vt
    elseif T <: ObservedDict
        return _lower_type_impl(records, keytype(T)) * " -> " *
               _lower_value_type_impl(records, valtype(T))
    elseif _is_record_type(T)
        return String(nameof(T))
    else
        error("Quint: cannot lower Julia type `$T` to a Quint type")
    end
end

# The value-position type: a collapsed single-field record lowers to its field's type.
_lower_value_type(s::_QuintSchema, @nospecialize(T)) = _lower_value_type_impl(s.records, T)
function _lower_value_type_impl(records, @nospecialize(T))
    if records !== nothing && _is_record_type(T)
        ri = get(records, nameof(T), nothing)
        if ri !== nothing && ri.collapsed
            return _lower_type_impl(records, ri.ftypes[1])
        end
    end
    return _lower_type_impl(records, T)
end

########################### Schema construction ###########################

# Which top-level physical fields does any compiled event write? Returns
# (writtenset, promotion_ok). Promotion is disabled if any event lacks effect_spec.
function _written_fields(events)
    written = Set{Symbol}()
    promotion_ok = true
    for T in events
        if !hasmethod(effect_spec, Tuple{Type{T}})
            promotion_ok = false
            continue
        end
        for w in effect_spec(T).writes
            m1 = w.matchstr[1]
            m1 isa Member && push!(written, m1.name)
        end
    end
    return (written, promotion_ok)
end

# A record/value field type the compiler can lower (float and plain
# Vector/Dict/struct fields are dropped from records).
function _can_lower_field(@nospecialize(T))
    (T === Bool || _is_enum_type(T) || T <: Integer) && return true
    _is_float_type(T) && return false
    if T <: Tuple
        return all(_can_lower_field, T.parameters)
    elseif T <: AbstractSet || T <: ObservedSet
        return _can_lower_field(eltype(T))
    elseif _is_record_type(T)
        return true
    end
    return false
end

# Build the record infos: keep only lowerable, non-float fields (drop the rest),
# and collapse iff exactly one field is kept.
function _build_records(records_set::Set{Type})
    out = Dict{Symbol,_RecordInfo}()
    for T in records_set
        allf = _record_fields(T)
        kept = Symbol[f for f in allf if _can_lower_field(fieldtype(T, f))]
        dropped = Symbol[f for f in allf if !(f in kept)]
        collapsed = length(kept) == 1
        out[nameof(T)] = _RecordInfo(nameof(T), kept, Any[fieldtype(T, f) for f in kept],
            String[], collapsed, collapsed ? kept[1] : nothing, dropped)
    end
    for (nm, ri) in out
        qf = String[_lower_value_type_impl(out, ft) for ft in ri.ftypes]
        out[nm] = _RecordInfo(ri.name, ri.fields, ri.ftypes, qf, ri.collapsed,
            ri.collapsed_field, ri.dropped)
    end
    return out
end

"""
    _build_schema(model, physical, events) -> _QuintSchema

Reflect the physical type into a `_QuintSchema`. `events` drives D6 constant
promotion (a scalar with no WriteSpec is a `pure val`).
"""
function _build_schema(model::Module, physical, events)
    ptype = typeof(physical)
    enums = Dict{Symbol,_EnumInfo}()
    records_set = Set{Type}()
    ufields = Symbol[f for f in fieldnames(ptype) if f ∉ (:obs_modified, :obs_read)]
    for f in ufields
        _scan_types!(enums, records_set, fieldtype(ptype, f))
    end
    for T in events
        for ef in fieldnames(T)
            _scan_types!(enums, records_set, fieldtype(T, ef))
        end
    end
    _check_enum_collisions(enums)
    records = _build_records(records_set)

    written, promotion_ok = _written_fields(events)
    renames = Pair{Symbol,Symbol}[]
    fields = _FieldInfo[]
    for f in ufields
        FT = fieldtype(ptype, f)
        emit = _sanitize(f)
        emit === f || push!(renames, f => emit)
        info = _classify_field(records, physical, f, FT, written, promotion_ok)
        push!(fields, info)
    end
    return _QuintSchema(model, ptype, fields, records, enums, renames)
end

# Classify one physical field into a `_FieldInfo`.
function _classify_field(records, physical, f::Symbol, @nospecialize(FT), written, promotion_ok)
    emit = _sanitize(f)
    snap = getfield(physical, f)
    if FT <: Param
        VT = FT.parameters[1]
        if _representable_const(VT)
            qt = _lower_value_type_impl(records, VT)
            return _FieldInfo(f, emit, :const, qt, VT, nothing, 0, Int[], false, "")
        else
            return _FieldInfo(f, emit, :erased, "", VT, nothing, 0, Int[], false,
                "$(f)::Param{$VT} (unrepresentable const, erased)")
        end
    elseif FT <: ObservedArray
        N = FT.parameters[2]
        ET = eltype(FT)
        _element_empty(records, ET) && return _erased_field(f, emit, ET, "ObservedArray element")
        qt = try _lower_type_impl(records, FT) catch; "" end
        qt == "" && return _erased_field(f, emit, ET, "ObservedArray (unlowerable)")
        ext = collect(Int, size(getfield(snap, :arr)))
        return _FieldInfo(f, emit, N == 1 ? :array1 : :arrayN, qt, ET, Int, N, ext, false, "")
    elseif FT <: ObservedDict
        KT = keytype(FT); VT = valtype(FT)
        _element_empty(records, VT) && return _erased_field(f, emit, VT, "ObservedDict value")
        qt = try _lower_type_impl(records, FT) catch; "" end
        qt == "" && return _erased_field(f, emit, VT, "ObservedDict (unlowerable)")
        return _FieldInfo(f, emit, :dict, qt, VT, KT, 0, Int[], false, "")
    elseif FT <: ObservedSet
        ET = eltype(FT)
        _is_float_type(ET) && return _erased_field(f, emit, ET, "ObservedSet element")
        qt = "Set[" * _lower_type_impl(records, ET) * "]"
        return _FieldInfo(f, emit, :set, qt, ET, nothing, 0, Int[], false, "")
    elseif FT === Bool || _is_enum_type(FT) || FT <: Integer
        promoted = promotion_ok && !(f in written)
        kind = promoted ? :const : :scalar
        qt = _lower_type_impl(records, FT)
        note = promoted ? "$(f) (no WriteSpec names it)" : ""
        return _FieldInfo(f, emit, kind, qt, FT, nothing, 0, Int[], promoted, note)
    elseif _is_float_type(FT)
        return _erased_field(f, emit, FT, "physical field")
    else
        # Plain untracked Vector/Dict/struct: treat as a const iff representable,
        # else erase (projecting unrepresentable members leaves nothing).
        if _representable_const(FT) && !(f in written)
            qt = _lower_type_impl(records, FT)
            return _FieldInfo(f, emit, :const, qt, FT, nothing, 0, Int[], false, "")
        end
        return _FieldInfo(f, emit, :erased, "", FT, nothing, 0, Int[], false,
            "$(f)::$FT (untracked/unrepresentable, erased)")
    end
end

_erased_field(f, emit, T, why) =
    _FieldInfo(f, emit, :erased, "", T, nothing, 0, Int[], false, "$(f)::$T ($why, erased)")

# Does a keyedby element / value type carry a Float leaf?
function _is_float_leaf(records, @nospecialize(T))
    _is_float_type(T) && return true
    if _is_record_type(T)
        return any(ft -> _is_float_type(ft), (fieldtype(T, f) for f in _record_fields(T)))
    end
    return false
end

# A container element type that lowers to nothing (a bare float, or a record with
# no kept fields) -> the whole container field is erased.
function _element_empty(records, @nospecialize(T))
    _is_float_type(T) && return true
    if _is_record_type(T)
        ri = get(records, nameof(T), nothing)
        return ri !== nothing && isempty(ri.fields)
    end
    return !_can_lower_field(T)
end

# A representable const: Int/Bool/Enum, Tuples/Sets/Vectors thereof, or records
# whose fields are representable. Floats and Distributions are not representable.
function _representable_const(@nospecialize(T))
    (T === Bool || _is_enum_type(T) || T <: Integer) && return true
    _is_float_type(T) && return false
    if T <: Tuple
        return all(_representable_const, T.parameters)
    elseif T <: AbstractSet || T <: AbstractArray
        return _representable_const(eltype(T))
    end
    return false
end

########################### The init value emitter ###########################

# Canonical key ordering so Map(...) literals are byte-stable across Dict order.
_canon_key(x::Integer) = (0, Int(x), "")
_canon_key(x::Base.Enum) = (1, Int(x), "")
_canon_key(x::Symbol) = (2, 0, string(x))
_canon_key(x::AbstractString) = (2, 0, string(x))
_canon_key(x::Bool) = (0, x ? 1 : 0, "")
_canon_key(t::Tuple) = (3, 0, join((repr(_canon_key(e)) for e in t), "|"))

"""
    _emit_value(schema, T, v) -> String

Serialize a live value `v` of Julia type `T` to a Quint literal (D15). Dict/array
keys are emitted in canonical order for byte-stable goldens.
"""
function _emit_value(s::_QuintSchema, @nospecialize(T), v)
    if T === Bool
        return v ? "true" : "false"
    elseif _is_enum_type(T)
        return String(Symbol(v))
    elseif T <: Integer
        return string(v)
    elseif T <: Tuple
        return "(" * join((_emit_value(s, T.parameters[i], v[i]) for i in 1:length(v)), ", ") * ")"
    elseif T <: ObservedSet || T <: AbstractSet
        ET = eltype(T)
        elems = sort(collect(v); by=_canon_key)
        return "Set(" * join((_emit_value(s, ET, e) for e in elems), ", ") * ")"
    elseif T <: ObservedArray
        arr = getfield(v, :arr)
        N = T.parameters[2]
        ET = eltype(T)
        pairs = String[]
        if N == 1
            for i in 1:length(arr)
                push!(pairs, string(i) * " -> " * _emit_record_or_value(s, ET, arr[i]))
            end
        else
            for idx in CartesianIndices(arr)
                key = "(" * join(Tuple(idx), ", ") * ")"
                push!(pairs, key * " -> " * _emit_record_or_value(s, ET, arr[idx]))
            end
        end
        return isempty(pairs) ? "Map()" : "Map(" * join(pairs, ", ") * ")"
    elseif T <: ObservedDict
        KT = keytype(T); VT = valtype(T)
        ks = sort(collect(keys(v)); by=_canon_key)
        pairs = String[_emit_value(s, KT, k) * " -> " * _emit_record_or_value(s, VT, v[k]) for k in ks]
        return isempty(pairs) ? "Map()" : "Map(" * join(pairs, ", ") * ")"
    elseif T <: Param
        return _emit_value(s, T.parameters[1], v.value)
    elseif _is_record_type(T)
        return _emit_record_or_value(s, T, v)
    elseif T <: AbstractArray
        # plain Vector const -> a 1-based Quint map
        pairs = String[string(i) * " -> " * _emit_value(s, eltype(T), v[i]) for i in 1:length(v)]
        return isempty(pairs) ? "Map()" : "Map(" * join(pairs, ", ") * ")"
    else
        error("Quint: cannot serialize value of type `$T`")
    end
end

# Emit an element: a collapsed record emits its bare field value; otherwise a
# `{ field: v, ... }` record literal in field order.
function _emit_record_or_value(s::_QuintSchema, @nospecialize(T), v)
    if _is_record_type(T)
        ri = get(s.records, nameof(T), nothing)
        if ri !== nothing && ri.collapsed
            return _emit_value(s, ri.ftypes[1], getfield(v, ri.collapsed_field))
        elseif ri !== nothing
            parts = String[]
            for (f, ft) in zip(ri.fields, ri.ftypes)
                push!(parts, string(f) * ": " * _emit_value(s, ft, getfield(v, f)))
            end
            return "{ " * join(parts, ", ") * " }"
        end
    end
    return _emit_value(s, T, v)
end
