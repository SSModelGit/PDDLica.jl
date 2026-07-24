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

function _reject_extra(d::AbstractDict,allowed_keys,context)
    allowed=Set(allowed_keys)
    Diagnostic[_diagnostic("PDDLICA-JSON-006","$context contains unknown key '$k'") for k in Base.keys(d) if !(k in allowed)]
end

function _object!(diags,x,context,required,allowed=required)
    if !(x isa AbstractDict)
        push!(diags,_diagnostic("PDDLICA-JSON-004","$context must be a JSON object"))
        return false
    end
    append!(diags,_require_keys(x,required,context))
    append!(diags,_reject_extra(x,allowed,context))
    true
end

function _array!(diags,x,context)
    x isa AbstractVector && return true
    push!(diags,_diagnostic("PDDLICA-JSON-004","$context must be a JSON array"))
    false
end

function _parameters!(diags,x,context)
    _array!(diags,x,context) || return
    for (i,p) in enumerate(x)
        _object!(diags,p,"$context[$i]",("name","type")) || continue
        get(p,"name",nothing) isa AbstractString || push!(diags,
            _diagnostic("PDDLICA-JSON-004","$context[$i].name must be a string"))
        get(p,"type",nothing) isa AbstractString || push!(diags,
            _diagnostic("PDDLICA-JSON-004","$context[$i].type must be a string"))
    end
end

function _value!(diags,x,context)
    _object!(diags,x,context,("kind",),
        ("kind","value","name","operator","arguments","field","port","path",
         "anchor","segments")) || return
    kind=string(get(x,"kind",""))
    required=Dict(
        "number"=>("value",),"boolean"=>("value",),"symbol"=>("name",),
        "object"=>("name",),
        "variable"=>("name",),"self"=>(),"instance"=>("path",),
        "component"=>("path",),"call"=>("name","arguments"),
        "arithmetic"=>("operator","arguments"),"port_field"=>("field","port"))
    haskey(required,kind) || (push!(diags,_diagnostic("PDDLICA-JSON-007",
        "$context has unknown value kind '$kind'")); return)
    append!(diags,_require_keys(x,required[kind],context))
    if kind in ("call","arithmetic")
        _array!(diags,get(x,"arguments",nothing),"$context.arguments") &&
            foreach(i->_value!(diags,x["arguments"][i],"$context.arguments[$i]"),
                eachindex(x["arguments"]))
    elseif kind=="port_field"
        port=get(x,"port",nothing)
        if _object!(diags,port,"$context.port",("instance","port"))
            inst=get(port,"instance",nothing)
            _object!(diags,inst,"$context.port.instance",("anchor","segments")) &&
                _array!(diags,inst["segments"],"$context.port.instance.segments")
        end
    elseif kind in ("instance","component")
        path=get(x,"path",nothing)
        path isa AbstractDict && _object!(diags,path,"$context.path",
            ("anchor","segments"))
    end
end

function _formula!(diags,x,context)
    _object!(diags,x,context,("kind",),
        ("kind","value","name","arguments","item","items","operator","left","right",
         "component","parameters","body","antecedent","consequent","time","times",
         "first","second","trigger","response")) || return
    kind=string(get(x,"kind",""))
    if kind=="boolean"
        append!(diags,_require_keys(x,("value",),context))
    elseif kind=="atom"
        append!(diags,_require_keys(x,("name","arguments"),context))
        _array!(diags,get(x,"arguments",nothing),"$context.arguments") &&
            foreach(i->_value!(diags,x["arguments"][i],"$context.arguments[$i]"),
                eachindex(x["arguments"]))
    elseif kind=="present"
        append!(diags,_require_keys(x,("component",),context))
        haskey(x,"component") && _value!(diags,x["component"],"$context.component")
    elseif kind=="not"
        append!(diags,_require_keys(x,("item",),context))
        haskey(x,"item") && _formula!(diags,x["item"],"$context.item")
    elseif kind in ("and","or")
        append!(diags,_require_keys(x,("items",),context))
        _array!(diags,get(x,"items",nothing),"$context.items") &&
            foreach(i->_formula!(diags,x["items"][i],"$context.items[$i]"),
                eachindex(x["items"]))
    elseif kind=="imply"
        append!(diags,_require_keys(x,("antecedent","consequent"),context))
        haskey(x,"antecedent") && _formula!(diags,x["antecedent"],"$context.antecedent")
        haskey(x,"consequent") && _formula!(diags,x["consequent"],"$context.consequent")
    elseif kind=="compare"
        append!(diags,_require_keys(x,("operator","left","right"),context))
        haskey(x,"left") && _value!(diags,x["left"],"$context.left")
        haskey(x,"right") && _value!(diags,x["right"],"$context.right")
    elseif kind in ("forall","exists")
        append!(diags,_require_keys(x,("parameters","body"),context))
        haskey(x,"parameters") && _parameters!(diags,x["parameters"],"$context.parameters")
        haskey(x,"body") && _formula!(diags,x["body"],"$context.body")
    elseif kind=="preference"
        append!(diags,_require_keys(x,("name","body"),context))
        haskey(x,"body") && _formula!(diags,x["body"],"$context.body")
    elseif kind in ("always","sometime","at_most_once","hold_after","within","hold_during")
        append!(diags,_require_keys(x,("body",),context))
        haskey(x,"body") && _formula!(diags,x["body"],"$context.body")
    elseif kind in ("sometime_before","sometime_after")
        append!(diags,_require_keys(x,("first","second"),context))
        haskey(x,"first") && _formula!(diags,x["first"],"$context.first")
        haskey(x,"second") && _formula!(diags,x["second"],"$context.second")
    elseif kind=="always_within"
        append!(diags,_require_keys(x,("time","trigger","response"),context))
        haskey(x,"trigger") && _formula!(diags,x["trigger"],"$context.trigger")
        haskey(x,"response") && _formula!(diags,x["response"],"$context.response")
    else
        push!(diags,_diagnostic("PDDLICA-JSON-007",
            "$context has unknown formula kind '$kind'"))
    end
end

function _effect!(diags,x,context)
    _object!(diags,x,context,("kind",),
        ("kind","items","condition","effect","parameters","target","value",
         "atom","component")) || return
    kind=string(get(x,"kind",""))
    if kind=="and"
        append!(diags,_require_keys(x,("items",),context))
        _array!(diags,get(x,"items",nothing),"$context.items") &&
            foreach(i->_effect!(diags,x["items"][i],"$context.items[$i]"),
                eachindex(x["items"]))
    elseif kind=="when"
        append!(diags,_require_keys(x,("condition","effect"),context))
        haskey(x,"condition") && _formula!(diags,x["condition"],"$context.condition")
        haskey(x,"effect") && _effect!(diags,x["effect"],"$context.effect")
    elseif kind=="forall"
        append!(diags,_require_keys(x,("parameters","effect"),context))
        haskey(x,"parameters") && _parameters!(diags,x["parameters"],"$context.parameters")
        haskey(x,"effect") && _effect!(diags,x["effect"],"$context.effect")
    elseif kind in ("assign","increase","decrease","scale_up","scale_down")
        append!(diags,_require_keys(x,("target","value"),context))
        haskey(x,"target") && _value!(diags,x["target"],"$context.target")
        haskey(x,"value") && _value!(diags,x["value"],"$context.value")
    elseif kind=="set_atom"
        append!(diags,_require_keys(x,("atom","value"),context))
        atom=get(x,"atom",nothing)
        _object!(diags,atom,"$context.atom",("name","arguments")) &&
            _array!(diags,atom["arguments"],"$context.atom.arguments")
    elseif kind in ("create","remove")
        append!(diags,_require_keys(x,("component",),context))
        haskey(x,"component") && _value!(diags,x["component"],"$context.component")
    else
        push!(diags,_diagnostic("PDDLICA-JSON-007",
            "$context has unknown effect kind '$kind'"))
    end
end

function _declaration_arrays!(diags,d)
    array_fields=("types","constants","predicates","functions","derived_predicates",
        "connector_types","component_types","actions","durative_actions","events","processes")
    for field in array_fields
        _array!(diags,get(d,field,nothing),"domain.$field") || continue
        for (i,item) in enumerate(d[field])
            context="domain.$field[$i]"
            item isa AbstractDict || (push!(diags,_diagnostic("PDDLICA-JSON-004",
                "$context must be a JSON object")); continue)
            if field=="types"
                _object!(diags,item,context,("id","name","parent"))
            elseif field=="constants"
                _object!(diags,item,context,("id","name","type"))
            elseif field in ("predicates","functions")
                allowed=field=="functions" ? ("id","name","parameters","returns") :
                    ("id","name","parameters")
                _object!(diags,item,context,allowed)
                haskey(item,"parameters") && _parameters!(diags,item["parameters"],"$context.parameters")
            elseif field=="derived_predicates"
                _object!(diags,item,context,("id","name","parameters","body"))
                haskey(item,"parameters") && _parameters!(diags,item["parameters"],"$context.parameters")
                haskey(item,"body") && _formula!(diags,item["body"],"$context.body")
            elseif field=="connector_types"
                _object!(diags,item,context,("id","name","fields"))
                if _array!(diags,get(item,"fields",nothing),"$context.fields")
                    for (j,f) in enumerate(item["fields"])
                        _object!(diags,f,"$context.fields[$j]",("name","category","value_type"))
                    end
                end
            elseif field=="component_types"
                _component_decl!(diags,item,context)
            elseif field=="durative_actions"
                _durative_decl!(diags,item,context)
            else
                _behavior_decl!(diags,item,context;process=field=="processes")
            end
        end
    end
end

function _behavior_decl!(diags,item,context;process=false)
    required=process ? ("id","name","parameters","precondition","effects") :
        ("id","name","parameters","precondition","effect")
    _object!(diags,item,context,required) || return
    _parameters!(diags,item["parameters"],"$context.parameters")
    _formula!(diags,item["precondition"],"$context.precondition")
    if process
        if _array!(diags,item["effects"],"$context.effects")
            for (i,e) in enumerate(item["effects"])
                _object!(diags,e,"$context.effects[$i]",("operator","target","rate")) || continue
                _value!(diags,e["target"],"$context.effects[$i].target")
                _value!(diags,e["rate"],"$context.effects[$i].rate")
            end
        end
    else
        _effect!(diags,item["effect"],"$context.effect")
    end
end

function _durative_decl!(diags,item,context)
    required=("id","name","parameters","duration","duration_constraint","conditions","effects")
    _object!(diags,item,context,required) || return
    _parameters!(diags,item["parameters"],"$context.parameters")
    _value!(diags,item["duration"],"$context.duration")
    _formula!(diags,item["duration_constraint"],"$context.duration_constraint")
    for (field,payload) in (("conditions","formula"),("effects","effect"))
        _array!(diags,item[field],"$context.$field") || continue
        for (i,x) in enumerate(item[field])
            _object!(diags,x,"$context.$field[$i]",("timing",payload)) || continue
            payload=="formula" ? _formula!(diags,x[payload],"$context.$field[$i].$payload") :
                _effect!(diags,x[payload],"$context.$field[$i].$payload")
        end
    end
end

function _component_decl!(diags,item,context)
    fields=("id","name","variables","ports","requirements","methods","events",
        "processes","subcomponents","connections")
    _object!(diags,item,context,fields) || return
    for field in fields[3:end]
        _array!(diags,item[field],"$context.$field") || continue
        for (i,x) in enumerate(item[field])
            c="$context.$field[$i]"
            if field=="variables"
                _object!(diags,x,c,("id","name","parameters","value_type","static"))
                x isa AbstractDict && haskey(x,"parameters") &&
                    _parameters!(diags,x["parameters"],"$c.parameters")
            elseif field=="ports"
                _object!(diags,x,c,("id","name","connector_type","presence"))
            elseif field=="requirements"
                _object!(diags,x,c,("id","formula"))
                x isa AbstractDict && haskey(x,"formula") && _formula!(diags,x["formula"],"$c.formula")
            elseif field in ("methods","events")
                _behavior_decl!(diags,x,c)
            elseif field=="processes"
                _behavior_decl!(diags,x,c;process=true)
            elseif field=="subcomponents"
                _object!(diags,x,c,("id","name","component_type"))
            elseif field=="connections"
                _connection!(diags,x,c)
            end
        end
    end
end

function _connection!(diags,x,context)
    _object!(diags,x,context,("id","ports")) || return
    _array!(diags,x["ports"],"$context.ports") || return
    for (i,p) in enumerate(x["ports"])
        c="$context.ports[$i]"
        if _object!(diags,p,c,("instance","port"))
            _object!(diags,p["instance"],"$c.instance",("anchor","segments")) &&
                _array!(diags,p["instance"]["segments"],"$c.instance.segments")
        end
    end
end

function _problem_payload!(diags,p)
    for field in ("objects","components","connections","init","timed_initials",
                  "constraints","preferences")
        _array!(diags,get(p,field,nothing),"problem.$field") || continue
    end
    for (i,x) in enumerate(get(p,"objects",Any[]))
        _object!(diags,x,"problem.objects[$i]",("id","name","type"))
    end
    for (i,x) in enumerate(get(p,"components",Any[]))
        _object!(diags,x,"problem.components[$i]",
            ("id","name","component_type","present"))
    end
    for (i,x) in enumerate(get(p,"connections",Any[]))
        _connection!(diags,x,"problem.connections[$i]")
    end
    for (i,x) in enumerate(get(p,"init",Any[]))
        c="problem.init[$i]"
        _object!(diags,x,c,("id","kind"),("id","kind","left","right","atom","value")) || continue
        kind=string(get(x,"kind",""))
        if kind=="equality"
            append!(diags,_require_keys(x,("left","right"),c))
            haskey(x,"left") && _value!(diags,x["left"],"$c.left")
            haskey(x,"right") && _value!(diags,x["right"],"$c.right")
        elseif kind=="fact"
            append!(diags,_require_keys(x,("atom","value"),c))
        else
            push!(diags,_diagnostic("PDDLICA-JSON-007","$c has unknown initializer kind '$kind'"))
        end
    end
    for (i,x) in enumerate(get(p,"timed_initials",Any[]))
        c="problem.timed_initials[$i]"
        _object!(diags,x,c,("id","time","effect")) || continue
        _effect!(diags,x["effect"],"$c.effect")
    end
    haskey(p,"goal") && _formula!(diags,p["goal"],"problem.goal")
    for field in ("constraints","preferences"), (i,x) in enumerate(get(p,field,Any[]))
        _formula!(diags,x,"problem.$field[$i]")
    end
    metric=get(p,"metric",nothing)
    if !isnothing(metric) && _object!(diags,metric,"problem.metric",
            ("optimization","expression"))
        _value!(diags,metric["expression"],"problem.metric.expression")
    end
end

function _validate_document(d::Dict{String,Any})
    diags = _require_keys(d, ("format", "version", "language", "domain", "problem",
                              "source_map", "metadata"), "model document")
    append!(diags,_reject_extra(d,("format","version","language","domain","problem","source_map","metadata"),"model document"))
    get(d, "format", nothing) == MODEL_FORMAT || push!(diags,
        _diagnostic("PDDLICA-JSON-002", "expected format '$MODEL_FORMAT'"))
    get(d, "version", nothing) == MODEL_VERSION || push!(diags,
        _diagnostic("PDDLICA-JSON-003", "unsupported PDDLica-JSON version '$(get(d, "version", "missing"))'"))
    for name in ("language", "domain", "problem", "source_map", "metadata")
        haskey(d, name) && !(d[name] isa AbstractDict) && push!(diags,
            _diagnostic("PDDLICA-JSON-004", "'$name' must be a JSON object"))
    end
    isempty(diags) || return diags
    append!(diags, _require_keys(d["domain"], ("id","name","requirements","types","constants","predicates",
        "functions","derived_predicates","connector_types","component_types","actions","durative_actions","events","processes"), "domain"))
    append!(diags, _require_keys(d["problem"], ("id","name","domain","objects","components","connections","init",
        "timed_initials","goal","constraints","preferences","metric"), "problem"))
    append!(diags,_reject_extra(d["domain"],("id","name","requirements","types","constants","predicates","functions",
        "derived_predicates","connector_types","component_types","actions","durative_actions","events","processes"),"domain"))
    append!(diags,_reject_extra(d["problem"],("id","name","domain","objects","components","connections","init",
        "timed_initials","goal","constraints","preferences","metric"),"problem"))
    _declaration_arrays!(diags,d["domain"])
    _problem_payload!(diags,d["problem"])
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
        extras=setdiff(Set(string.(keys(d))),Set(["format","version","model_digest","horizon","occurrences","metadata"]))
        isempty(extras) || throw(ArgumentError("plan contains unknown keys: $(join(sort!(collect(extras)),", "))"))
        get(d, "format", "") == PLAN_FORMAT || throw(ArgumentError("not a PDDLica plan"))
        get(d, "version", "") == "0.1" || throw(ArgumentError("unsupported plan version"))
        for key in ("model_digest","horizon","occurrences","metadata")
            haskey(d,key) || throw(ArgumentError("plan is missing $key"))
        end
        d["occurrences"] isa AbstractVector || throw(ArgumentError("plan occurrences must be an array"))
        d["metadata"] isa AbstractDict || throw(ArgumentError("plan metadata must be an object"))
        horizon=_parse_time(d["horizon"])
        isfinite(horizon) && horizon>=0 ||
            throw(ArgumentError("plan horizon must be finite and nonnegative"))
        occurrences = PlanOccurrence[]
        for (i, o) in enumerate(get(d, "occurrences", Any[]))
            o isa AbstractDict || throw(ArgumentError("plan occurrence $i must be an object"))
            oextras=setdiff(Set(string.(keys(o))),Set(["id","time","kind","schema_id","name","owner","arguments","duration"]))
            isempty(oextras) || throw(ArgumentError("plan occurrence $i contains unknown keys: $(join(sort!(collect(oextras)),", "))"))
            for key in ("id","time","kind","schema_id","name","arguments")
                haskey(o,key) || throw(ArgumentError("plan occurrence $i is missing $key"))
            end
            kind=Symbol(o["kind"])
            kind in (:action,:method,:durative_action) ||
                throw(ArgumentError("plan occurrence $i has unknown kind '$kind'"))
            o["arguments"] isa AbstractVector ||
                throw(ArgumentError("plan occurrence $i arguments must be an array"))
            argdiags=Diagnostic[]
            for (j,a) in enumerate(o["arguments"])
                _value!(argdiags,a,"plan occurrence $i argument $j")
            end
            isempty(argdiags) || throw(ArgumentError(join(string.(argdiags),"; ")))
            time=_parse_time(o["time"])
            isfinite(time) && time>=0 ||
                throw(ArgumentError("plan occurrence $i time must be finite and nonnegative"))
            duration=haskey(o,"duration") ? _parse_time(o["duration"]) : nothing
            (isnothing(duration) || isfinite(duration) && duration>=0) ||
                throw(ArgumentError("plan occurrence $i duration must be finite and nonnegative"))
            push!(occurrences, PlanOccurrence(
                id=string(o["id"]), time=time, kind=kind,
                schema_id=string(get(o, "schema_id", "")), name=string(get(o, "name", "")),
                owner=String[string(v) for v in get(o, "owner", Any[])],
                arguments=Any[_asdict(v) for v in get(o, "arguments", Any[])],
                duration=duration))
        end
        PlanDocument(model_digest=string(get(d, "model_digest", "")),
            horizon=horizon, occurrences=occurrences,
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
    open=Dict{String,Any}()
    for (id,record) in state.open_duratives
        behavior=get(record,"behavior",Dict{String,Any}())
        open[id]=Dict{String,Any}("schema_id"=>get(behavior,"id",""),
            "parameters"=>deepcopy(get(record,"params",Dict{String,Any}())),
            "end_time"=>get(record,"end_time",nothing))
    end
    Dict{String,Any}("time" => string(state.time), "microstep" => state.microstep,
        "stored" => deepcopy(state.values), "interface" => deepcopy(state.interface),
        "presence" => deepcopy(state.presence), "boundary_memory" => deepcopy(state.boundary),
        "open_duratives" => open)
end

function diagnostic_dict(d::Diagnostic)
    out=Dict{String,Any}("severity"=>String(d.severity),"code"=>d.code,
        "message"=>d.message,"related"=>d.related,"notes"=>d.notes,"data"=>d.data)
    if !isnothing(d.location)
        s=d.location
        out["location"]=Dict{String,Any}("document"=>s.document,
            "start_byte"=>s.start_byte,"end_byte"=>s.end_byte,
            "start_line"=>s.start_line,"start_column"=>s.start_column,
            "end_line"=>s.end_line,"end_column"=>s.end_column)
    end
    out
end

function write_diagnostics_json(io::IO,diagnostics;canonical=false)
    payload=Dict{String,Any}("format"=>"pddlica-diagnostics","version"=>"0.1",
        "diagnostics"=>diagnostic_dict.(collect(diagnostics)))
    canonical ? print(io,canonical_json(payload)) : JSON3.pretty(io,payload)
    io
end
write_diagnostics_json(path::AbstractString,diagnostics;kwargs...)=
    open(io->write_diagnostics_json(io,diagnostics;kwargs...),path,"w")

function read_diagnostics_json(io::IO)
    d=_plain(JSON3.read(io))
    d isa AbstractDict || throw(ArgumentError("diagnostics document must be an object"))
    get(d,"format","")=="pddlica-diagnostics" ||
        throw(ArgumentError("not a PDDLica diagnostics document"))
    get(d,"version","")=="0.1" ||
        throw(ArgumentError("unsupported diagnostics version"))
    get(d,"diagnostics",nothing) isa AbstractVector ||
        throw(ArgumentError("diagnostics must be an array"))
    Diagnostic[_diagnostic_from_dict(x) for x in d["diagnostics"]]
end
read_diagnostics_json(path::AbstractString)=open(read_diagnostics_json,path)

function execution_dict(result::SimulationResult)
    Dict{String,Any}(
        "format" => "pddlica-execution", "version" => "0.1",
        "status" => lowercase(String(result.status)),
        "plan" => isnothing(result.plan) ? nothing : plan_dict(result.plan),
        "terminal_state" => isnothing(result.terminal_state) ? nothing : state_dict(result.terminal_state),
        "steps" => result.steps,
        "trajectories" => Dict(name => Dict{String,Any}(
            "kind" => String(series.kind), "times" => string.(series.times),
            "values" => series.values, "phases" => String.(series.phases))
            for (name, series) in result.trajectories),
        "diagnostics" => diagnostic_dict.(result.diagnostics),
        "metadata" => result.metadata)
end

function write_execution_json(io::IO, result::SimulationResult; canonical=false)
    d = execution_dict(result)
    canonical ? print(io, canonical_json(d)) : JSON3.pretty(io, d)
    io
end
write_execution_json(path::AbstractString, result::SimulationResult; kwargs...) =
    open(io -> write_execution_json(io, result; kwargs...), path, "w")

function _diagnostic_from_dict(d)
    location=nothing
    if get(d,"location",nothing) isa AbstractDict
        x=d["location"]
        location=SourceSpan(document=string(get(x,"document","")),
            start_byte=Int(get(x,"start_byte",0)),end_byte=Int(get(x,"end_byte",0)),
            start_line=Int(get(x,"start_line",1)),start_column=Int(get(x,"start_column",1)),
            end_line=Int(get(x,"end_line",1)),end_column=Int(get(x,"end_column",1)))
    end
    Diagnostic(severity=Symbol(get(d,"severity","error")),code=string(get(d,"code","PDDLICA-ERROR")),
        message=string(get(d,"message","")),location=location,
        related=Any[_asdict(x) for x in get(d,"related",Any[])],
        notes=String[string(x) for x in get(d,"notes",Any[])],
        data=_asdict(get(d,"data",Dict{String,Any}())))
end

function _state_from_dict(d)
    RuntimeState(time=_parse_time(get(d,"time","0")),microstep=Int(get(d,"microstep",0)),
        values=_asdict(get(d,"stored",Dict{String,Any}())),
        interface=Dict{String,Float64}(string(k)=>Float64(v)
            for (k,v) in get(d,"interface",Dict{String,Any}())),
        presence=Dict{String,Bool}(string(k)=>Bool(v)
            for (k,v) in get(d,"presence",Dict{String,Any}())),
        boundary=Dict{String,Float64}(string(k)=>Float64(v)
            for (k,v) in get(d,"boundary_memory",Dict{String,Any}())))
end

function _simulation_from_dict(d)
    plan=get(d,"plan",nothing)
    pd=isnothing(plan) ? nothing : read_plan_json(IOBuffer(JSON3.write(plan)))
    terminal=get(d,"terminal_state",nothing)
    trajectories=Dict{String,VariableTrajectory}()
    for (name,x) in get(d,"trajectories",Dict{String,Any}())
        trajectories[string(name)]=VariableTrajectory(name=string(name),
            kind=Symbol(get(x,"kind","stored")),
            times=Float64[_parse_time(t) for t in get(x,"times",Any[])],
            values=Any[_asdict(v) for v in get(x,"values",Any[])],
            phases=Symbol[Symbol(v) for v in get(x,"phases",Any[])])
    end
    SimulationResult(status=Symbol(uppercase(string(get(d,"status","error")))),
        plan=pd,terminal_state=isnothing(terminal) ? nothing : _state_from_dict(terminal),
        steps=Dict{String,Any}[_asdict(x) for x in get(d,"steps",Any[])],
        trajectories=trajectories,
        diagnostics=Diagnostic[_diagnostic_from_dict(x)
            for x in get(d,"diagnostics",Any[])],
        metadata=_asdict(get(d,"metadata",Dict{String,Any}())))
end

function read_execution_json(io::IO)
    d=_plain(JSON3.read(io))
    d isa AbstractDict || throw(ArgumentError("execution must be a JSON object"))
    get(d,"format","")=="pddlica-execution" ||
        throw(ArgumentError("not a PDDLica execution document"))
    get(d,"version","")=="0.1" || throw(ArgumentError("unsupported execution version"))
    required=("status","plan","terminal_state","steps","trajectories","diagnostics","metadata")
    missing=[k for k in required if !haskey(d,k)]
    isempty(missing) || throw(ArgumentError("execution is missing: $(join(missing,", "))"))
    _simulation_from_dict(d)
end
read_execution_json(path::AbstractString)=open(read_execution_json,path)

function capability_dict(report::CapabilityReport)
    Dict{String,Any}("supported"=>report.supported,"backend"=>report.backend,
        "profile"=>report.profile,"restrictions"=>report.restrictions,
        "diagnostics"=>diagnostic_dict.(report.diagnostics),
        "details"=>report.details)
end

function optimization_result_dict(result::OptimizationResult)
    Dict{String,Any}(
        "format"=>"pddlica-optimization-result","version"=>"0.1",
        "status"=>lowercase(String(result.status)),"backend"=>result.backend,
        "capability"=>capability_dict(result.capability),
        "plan"=>isnothing(result.plan) ? nothing : plan_dict(result.plan),
        "validation"=>isnothing(result.validation) ? nothing : execution_dict(result.validation),
        "objective"=>result.objective,
        "diagnostics"=>diagnostic_dict.(result.diagnostics),
        "statistics"=>result.statistics,"metadata"=>result.metadata)
end

function write_optimization_result_json(io::IO,result::OptimizationResult;canonical=false)
    d=optimization_result_dict(result)
    canonical ? print(io,canonical_json(d)) : JSON3.pretty(io,d)
    io
end
write_optimization_result_json(path::AbstractString,result::OptimizationResult;kwargs...) =
    open(io->write_optimization_result_json(io,result;kwargs...),path,"w")

function read_optimization_result_json(io::IO)
    d=_plain(JSON3.read(io))
    d isa AbstractDict || throw(ArgumentError("optimization result must be a JSON object"))
    get(d,"format","")=="pddlica-optimization-result" ||
        throw(ArgumentError("not a PDDLica optimization result"))
    get(d,"version","")=="0.1" ||
        throw(ArgumentError("unsupported optimization-result version"))
    c=get(d,"capability",Dict{String,Any}())
    capability=CapabilityReport(supported=Bool(get(c,"supported",false)),
        backend=string(get(c,"backend","")),profile=string(get(c,"profile","")),
        restrictions=String[string(x) for x in get(c,"restrictions",Any[])],
        diagnostics=Diagnostic[_diagnostic_from_dict(x)
            for x in get(c,"diagnostics",Any[])],
        details=_asdict(get(c,"details",Dict{String,Any}())))
    plan=get(d,"plan",nothing); validation=get(d,"validation",nothing)
    OptimizationResult(status=Symbol(uppercase(string(get(d,"status","backend_error")))),
        backend=string(get(d,"backend","")),capability=capability,
        plan=isnothing(plan) ? nothing : read_plan_json(IOBuffer(JSON3.write(plan))),
        validation=isnothing(validation) ? nothing : _simulation_from_dict(validation),
        objective=isnothing(get(d,"objective",nothing)) ? nothing : _asdict(d["objective"]),
        diagnostics=Diagnostic[_diagnostic_from_dict(x)
            for x in get(d,"diagnostics",Any[])],
        statistics=_asdict(get(d,"statistics",Dict{String,Any}())),
        metadata=_asdict(get(d,"metadata",Dict{String,Any}())))
end
read_optimization_result_json(path::AbstractString)=
    open(read_optimization_result_json,path)
