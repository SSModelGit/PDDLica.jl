mutable struct _UnionFind
    parent::Dict{String,String}
end
_UnionFind(xs::AbstractVector{<:AbstractString}) = _UnionFind(Dict(String(x) => String(x) for x in xs))
function _find!(u::_UnionFind, x)
    haskey(u.parent, x) || (u.parent[x]=x)
    u.parent[x] == x && return x
    u.parent[x] = _find!(u, u.parent[x])
end
function _union!(u::_UnionFind, a, b)
    ra=_find!(u,a); rb=_find!(u,b); ra == rb || (u.parent[rb]=ra)
end

_pathstr(path) = join(path, ".")
_statekey(path, name) = isempty(path) ? name : _pathstr(path) * "." * name
_portkey(path, name) = _statekey(path, name)

function _literal(v)
    kind=get(v,"kind","")
    if kind == "number"; return _parse_time(v["value"])
    elseif kind == "symbol"; return v["name"]
    elseif kind == "boolean"; return Bool(v["value"])
    end
    nothing
end

function _argument_name(a)
    get(a,"kind","") in ("symbol","object") && return string(get(a,"name",""))
    get(a,"kind","") == "instance" && return join(get(get(a,"path",Dict()),"segments",Any[]), ".")
    get(a,"kind","") == "component" && return join(get(a,"path",Any[]), ".")
    ""
end

function _initial_target(expr, components)
    kind=get(expr,"kind","")
    if kind == "call"
        name=string(expr["name"]); args=get(expr,"arguments",Any[])
        if !isempty(args)
            owner=_argument_name(args[1])
            haskey(components, owner) && return _statekey(split(owner,'.'), name)
        end
        return isempty(args) ? name : name * "(" * join(_argument_name.(args), ",") * ")"
    elseif kind == "port_field"
        port=expr["port"]; path=String[string(x) for x in get(port["instance"],"segments",Any[])]
        return _portkey(path,string(port["port"])) * "." * string(expr["field"])
    end
    ""
end

function elaborate(doc::PDDLicaDocument)
    diags=Diagnostic[]; domain=doc.domain; problem=doc.problem
    ctypes=Dict{String,Dict{String,Any}}(string(c["name"])=>c for c in get(domain,"component_types",Any[]))
    connectors=Dict{String,Dict{String,Any}}(string(c["name"])=>c for c in get(domain,"connector_types",Any[]))
    components=Dict{String,ComponentInstance}(); presence=Dict{String,Bool}()

    function instantiate(path::Vector{String}, typ::String, declared::Bool; parent=nothing, trail=String[])
        if typ in trail
            push!(diags, Diagnostic(code="PDDLICA-MODEL-010", message="cyclic component hierarchy through '$typ'")); return
        end
        haskey(ctypes,typ) || (push!(diags, Diagnostic(code="PDDLICA-MODEL-001",
            message="unknown component type '$typ'")); return)
        key=_pathstr(path); ctype=ctypes[typ]
        ports=Dict{String,Dict{String,Any}}(string(p["name"])=>p for p in get(ctype,"ports",Any[]))
        components[key]=ComponentInstance(path=path,component_type=typ,parent=parent,ports=ports)
        presence[key]=declared
        for sub in get(ctype,"subcomponents",Any[])
            instantiate(vcat(path,[string(sub["name"])]),string(sub["component_type"]),declared;
                parent=key,trail=vcat(trail,[typ]))
        end
    end
    for c in get(problem,"components",Any[])
        instantiate([string(c["name"])],string(c["component_type"]),Bool(get(c,"present",true)))
    end

    initial=Dict{String,Any}()
    for (key,inst) in components
        ct=ctypes[inst.component_type]
        for v in get(ct,"variables",Any[])
            # Missing values remain visible and are diagnosed after init lowering.
            initial[_statekey(inst.path,string(v["name"]))]=nothing
        end
    end
    initial_iface=Dict{String,Float64}()
    for e in get(problem,"init",Any[])
        if get(e,"kind","") == "equality"
            key=_initial_target(e["left"],components); val=_literal(e["right"])
            if isempty(key) || isnothing(val)
                push!(diags, Diagnostic(code="PDDLICA-MODEL-020", message="unsupported initial equality '$(get(e,"id",""))'"))
            elseif occursin(r"\.[^.]+\.[^.]+$", key) && !haskey(initial,key)
                val isa Number ? (initial_iface[key]=Float64(val)) : push!(diags,
                    Diagnostic(code="PDDLICA-MODEL-021",message="connector initial value must be numeric"))
            else
                initial[key]=val
            end
        elseif get(e,"kind","") == "fact"
            a=e["atom"]; args=get(a,"arguments",Any[])
            key=string(a["name"]) * "(" * join(_argument_name.(args),",") * ")"
            initial[key]=Bool(e["value"])
        end
    end
    for (key,val) in initial
        isnothing(val) && push!(diags, Diagnostic(code="PDDLICA-MODEL-022",
            message="component variable '$key' has no initial value"))
    end

    # Build all port vertices, then merge source hyperedges.
    allports=String[]
    for (key,inst) in components, pname in keys(inst.ports); push!(allports,"$key.$pname") end
    uf=_UnionFind(allports)
    function absolute_ref(ref, base::Vector{String})
        inst=get(ref,"instance",Dict{String,Any}()); anchor=get(inst,"anchor","problem")
        segs=String[string(s) for s in get(inst,"segments",Any[])]
        path=anchor == "self" ? vcat(base,segs) : segs
        _portkey(path,string(ref["port"]))
    end
    function add_connection(c, base=String[])
        ps=[absolute_ref(p,base) for p in get(c,"ports",Any[])]
        for p in ps
            p in allports || push!(diags, Diagnostic(code="PDDLICA-MODEL-030",message="unknown port '$p'"))
        end
        for p in ps[2:end]; _union!(uf,ps[1],p) end
    end
    for c in get(problem,"connections",Any[]); add_connection(c) end
    for (_,inst) in components
        ct=ctypes[inst.component_type]
        for c in get(ct,"connections",Any[]); add_connection(c,inst.path) end
    end
    groups=Dict{String,Vector{String}}()
    for p in allports; push!(get!(groups,_find!(uf,p),String[]),p) end
    connection_sets=collect(values(groups))

    for set in connection_sets
        connector_names=String[]
        for p in set
            owner,pname=rsplit(p,'.';limit=2); push!(connector_names,string(components[owner].ports[pname]["connector_type"]))
        end
        length(unique(connector_names)) == 1 || push!(diags, Diagnostic(code="PDDLICA-MODEL-031",
            message="connection set has incompatible connector types: $(join(unique(connector_names),", "))"))
    end

    behaviors=Dict{String,Dict{String,Any}}()
    for kind in ("actions","events","processes"), b in get(domain,kind,Any[])
        copyb=deepcopy(b); copyb["_kind"]=kind[1:end-1]; behaviors[string(b["id"])]=copyb
    end
    for (typ,ct) in ctypes, (field,kind) in (("methods","method"),("events","event"),("processes","process"))
        for b in get(ct,field,Any[])
            copyb=deepcopy(b); copyb["_kind"]=kind; copyb["_owner_type"]=typ; behaviors[string(b["id"])]=copyb
        end
    end
    provenance=Dict{String,Any}("initial_interface"=>initial_iface)
    model=ElaboratedModel(document=doc,digest=semantic_digest(doc),components=components,
        component_types=ctypes,connector_types=connectors,behaviors=behaviors,
        initial_values=initial,initial_presence=presence,connection_sets=connection_sets,
        goal=get(problem,"goal",Dict("kind"=>"boolean","value"=>true)),provenance=provenance)
    isempty(diags) ? ElaborationResult(model=model) : ElaborationResult(diagnostics=diags)
end
