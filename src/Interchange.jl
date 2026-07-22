const MODEL_FORMAT = "pddlica-json"
const MODEL_VERSION = "0.1"
const PLAN_FORMAT = "pddlica-plan"

_plain(x::JSON3.Object) = Dict{String,Any}(String(k) => _plain(v) for (k, v) in pairs(x))
_plain(x::JSON3.Array) = Any[_plain(v) for v in x]
_plain(x) = x

function _asdict(x)
    x isa Dict{String,Any} && return x
    x isa AbstractDict && return Dict{String,Any}(string(k) => _asdict(v) for (k, v) in x)
    x isa AbstractVector && return Any[_asdict(v) for v in x]
    return x
end

function _diagnostic(code, message; severity=:error, data=Dict{String,Any}())
    Diagnostic(severity=severity, code=code, message=message, data=data)
end

function _require_keys(d::AbstractDict, keys, context)
    Diagnostic[_diagnostic("PDDLICA-JSON-001", "$context is missing required key '$k'")
               for k in keys if !haskey(d, k)]
end

function _validate_document(d::Dict{String,Any})
    diags = _require_keys(d, ("format", "version", "language", "domain", "problem",
                              "source_map", "metadata"), "model document")
    get(d, "format", nothing) == MODEL_FORMAT || push!(diags,
        _diagnostic("PDDLICA-JSON-002", "expected format '$MODEL_FORMAT'"))
    get(d, "version", nothing) == MODEL_VERSION || push!(diags,
        _diagnostic("PDDLICA-JSON-003", "unsupported PDDLica-JSON version '$(get(d, "version", "missing"))'"))
    for name in ("language", "domain", "problem", "source_map", "metadata")
        haskey(d, name) && !(d[name] isa AbstractDict) && push!(diags,
            _diagnostic("PDDLICA-JSON-004", "'$name' must be a JSON object"))
    end
    isempty(diags) || return diags
    append!(diags, _require_keys(d["domain"], ("name", "requirements"), "domain"))
    append!(diags, _require_keys(d["problem"], ("name", "domain", "init", "goal"), "problem"))
    diags
end

function _document(d::Dict{String,Any})
    PDDLicaDocument(
        format=String(d["format"]), version=String(d["version"]),
        language=_asdict(d["language"]), domain=_asdict(d["domain"]),
        problem=_asdict(d["problem"]), source_map=_asdict(d["source_map"]),
        metadata=_asdict(d["metadata"]))
end

function document_dict(doc::PDDLicaDocument; include_digest=true)
    metadata = deepcopy(doc.metadata)
    d = Dict{String,Any}(
        "format" => doc.format, "version" => doc.version,
        "language" => doc.language, "domain" => doc.domain,
        "problem" => doc.problem, "source_map" => doc.source_map,
        "metadata" => metadata)
    include_digest && (metadata["semantic_digest"] = semantic_digest(doc))
    d
end

function read_pddlica_json(io::IO)
    try
        d = _plain(JSON3.read(io))
        d isa Dict{String,Any} || return ParseResult(diagnostics=[
            _diagnostic("PDDLICA-JSON-000", "top-level JSON value must be an object")])
        diags = _validate_document(d)
        isempty(diags) || return ParseResult(diagnostics=diags)
        doc = _document(d)
        supplied = get(doc.metadata, "semantic_digest", nothing)
        if !isnothing(supplied) && supplied != semantic_digest(doc)
            return ParseResult(diagnostics=[_diagnostic("PDDLICA-JSON-005",
                "semantic digest does not match the document payload")])
        end
        ParseResult(document=doc)
    catch err
        ParseResult(diagnostics=[_diagnostic("PDDLICA-JSON-000",
            "malformed JSON: $(sprint(showerror, err))")])
    end
end
read_pddlica_json(path::AbstractString) = open(read_pddlica_json, path)

function write_pddlica_json(io::IO, doc::PDDLicaDocument; canonical=false)
    d = document_dict(doc)
    canonical ? print(io, canonical_json(d)) : JSON3.pretty(io, d)
    io
end
write_pddlica_json(path::AbstractString, doc::PDDLicaDocument; kwargs...) =
    open(io -> write_pddlica_json(io, doc; kwargs...), path, "w")

function _canonical(io::IO, x)
    if x isa AbstractDict
        print(io, '{')
        first = true
        for k in sort!(collect(keys(x)); by=string)
            first || print(io, ','); first = false
            print(io, JSON3.write(string(k)), ':'); _canonical(io, x[k])
        end
        print(io, '}')
    elseif x isa AbstractVector || x isa Tuple
        print(io, '[')
        for (i, v) in enumerate(x)
            i == 1 || print(io, ','); _canonical(io, v)
        end
        print(io, ']')
    elseif x isa Symbol
        print(io, JSON3.write(String(x)))
    else
        print(io, JSON3.write(x))
    end
end

function canonical_json(x)
    io = IOBuffer(); _canonical(io, x); String(take!(io))
end

function semantic_digest(doc::PDDLicaDocument)
    payload = Dict{String,Any}(
        "format" => doc.format, "version" => doc.version,
        "language" => doc.language, "domain" => doc.domain,
        "problem" => doc.problem)
    "sha256:" * bytes2hex(sha256(canonical_json(payload)))
end

function _parse_time(x)
    s = string(x)
    if occursin('/', s)
        a, b = split(s, '/'; limit=2)
        return parse(Float64, a) / parse(Float64, b)
    end
    parse(Float64, s)
end

function read_plan_json(io::IO)
    try
        d = _plain(JSON3.read(io))
        d isa AbstractDict || throw(ArgumentError("plan must be a JSON object"))
        get(d, "format", "") == PLAN_FORMAT || throw(ArgumentError("not a PDDLica plan"))
        get(d, "version", "") == "0.1" || throw(ArgumentError("unsupported plan version"))
        occurrences = PlanOccurrence[]
        for (i, o) in enumerate(get(d, "occurrences", Any[]))
            push!(occurrences, PlanOccurrence(
                id=string(get(o, "id", "occ/$(i-1)")), time=_parse_time(o["time"]),
                kind=Symbol(get(o, "kind", "action")),
                schema_id=string(get(o, "schema_id", "")), name=string(get(o, "name", "")),
                owner=String[string(v) for v in get(o, "owner", Any[])],
                arguments=Any[_asdict(v) for v in get(o, "arguments", Any[])],
                duration=haskey(o, "duration") ? _parse_time(o["duration"]) : nothing))
        end
        PlanDocument(model_digest=string(get(d, "model_digest", "")),
            horizon=_parse_time(d["horizon"]), occurrences=occurrences,
            metadata=_asdict(get(d, "metadata", Dict{String,Any}())))
    catch err
        throw(ArgumentError("invalid PDDLica plan: $(sprint(showerror, err))"))
    end
end
read_plan_json(path::AbstractString) = open(read_plan_json, path)

function plan_dict(plan::PlanDocument)
    occs = Any[]
    for o in sort(plan.occurrences; by=x -> (x.time, x.id))
        d = Dict{String,Any}(
            "id" => o.id, "time" => string(o.time), "kind" => String(o.kind),
            "schema_id" => o.schema_id, "name" => o.name,
            "arguments" => o.arguments)
        isempty(o.owner) || (d["owner"] = o.owner)
        isnothing(o.duration) || (d["duration"] = string(o.duration))
        push!(occs, d)
    end
    Dict{String,Any}("format" => plan.format, "version" => plan.version,
        "model_digest" => plan.model_digest, "horizon" => string(plan.horizon),
        "occurrences" => occs, "metadata" => plan.metadata)
end

function write_plan_json(io::IO, plan::PlanDocument; canonical=false)
    d = plan_dict(plan)
    canonical ? print(io, canonical_json(d)) : JSON3.pretty(io, d)
    io
end
write_plan_json(path::AbstractString, plan::PlanDocument; kwargs...) =
    open(io -> write_plan_json(io, plan; kwargs...), path, "w")

function state_dict(state::RuntimeState)
    Dict{String,Any}("time" => string(state.time), "microstep" => state.microstep,
        "stored" => state.values, "interface" => state.interface,
        "presence" => state.presence, "boundary_memory" => state.boundary)
end

function execution_dict(result::SimulationResult)
    Dict{String,Any}(
        "format" => "pddlica-execution", "version" => "0.1",
        "status" => lowercase(String(result.status)),
        "terminal_state" => isnothing(result.terminal_state) ? nothing : state_dict(result.terminal_state),
        "steps" => result.steps,
        "trajectories" => Dict(name => Dict{String,Any}(
            "kind" => String(series.kind), "times" => series.times,
            "values" => series.values, "phases" => String.(series.phases))
            for (name, series) in result.trajectories),
        "diagnostics" => [Dict("severity" => String(d.severity), "code" => d.code,
            "message" => d.message, "notes" => d.notes, "data" => d.data) for d in result.diagnostics],
        "metadata" => result.metadata)
end

function write_execution_json(io::IO, result::SimulationResult; canonical=false)
    d = execution_dict(result)
    canonical ? print(io, canonical_json(d)) : JSON3.pretty(io, d)
    io
end
write_execution_json(path::AbstractString, result::SimulationResult; kwargs...) =
    open(io -> write_execution_json(io, result; kwargs...), path, "w")
