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
            if haskey(components, owner)
                tail=_argument_name.(args[2:end]); base=_statekey(split(owner,'.'),name)
                return isempty(tail) ? base : base*"("*join(tail,",")*")"
            end
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
    known_requirements=Set([":strips",":typing",":negative-preconditions",":disjunctive-preconditions",":equality",
        ":existential-preconditions",":universal-preconditions",":quantified-preconditions",":conditional-effects",
        ":fluents",":numeric-fluents",":object-fluents",":adl",":durative-actions",":duration-inequalities",
        ":continuous-effects",":derived-predicates",":timed-initial-literals",":preferences",":constraints",
        ":action-costs",":time",":events",":processes",":components",":acausal-connectors",
        ":component-presence",":component-hierarchy"])
    for requirement in get(domain,"requirements",Any[])
        string(requirement) in known_requirements || push!(diags,Diagnostic(code="PDDLICA-MODEL-000",
            message="unknown requirement key '$requirement'"))
    end
    ctypes=Dict{String,Dict{String,Any}}(string(c["name"])=>c for c in get(domain,"component_types",Any[]))
    connectors=Dict{String,Dict{String,Any}}(string(c["name"])=>c for c in get(domain,"connector_types",Any[]))
    components=Dict{String,ComponentInstance}(); presence=Dict{String,Bool}()

    function duplicate_names(items,label)
        seen=Set{String}()
        for x in items
            n=string(get(x,"name",""))
            n in seen && push!(diags,Diagnostic(code="PDDLICA-MODEL-002",message="duplicate $label '$n'"))
            push!(seen,n)
        end
    end
    for (items,label) in ((get(domain,"types",Any[]),"type"),(get(domain,"constants",Any[]),"constant"),
            (get(domain,"predicates",Any[]),"predicate"),(get(domain,"functions",Any[]),"function"),
            (get(domain,"connector_types",Any[]),"connector type"),(get(domain,"component_types",Any[]),"component type"),
            (get(problem,"objects",Any[]),"object"),(get(problem,"components",Any[]),"component"))
        duplicate_names(items,label)
    end
    for (items,label) in ((get(domain,"actions",Any[]),"action"),
            (get(domain,"durative_actions",Any[]),"durative action"),
            (get(domain,"events",Any[]),"event"),(get(domain,"processes",Any[]),"process"),
            (get(domain,"derived_predicates",Any[]),"derived predicate"))
        duplicate_names(items,label)
    end

    type_parent=Dict{String,String}("object"=>"","component"=>"object")
    for t in get(domain,"types",Any[]); type_parent[string(t["name"])]=string(get(t,"parent","object")) end
    # A PDDLica component declaration introduces its component type. Authors do
    # not need to repeat it in the ordinary PDDL :types section.
    for ct in values(ctypes)
        get!(type_parent,string(ct["name"]),"component")
    end
    for (t,p) in type_parent
        isempty(p) || haskey(type_parent,p) || p=="component" || push!(diags,Diagnostic(
            code="PDDLICA-MODEL-003",message="type '$t' has unknown parent '$p'"))
        trail=Set{String}(); q=t
        while haskey(type_parent,q) && !isempty(q)
            q in trail && (push!(diags,Diagnostic(code="PDDLICA-MODEL-004",message="cyclic type hierarchy through '$q'")); break)
            push!(trail,q); q=type_parent[q]
        end
    end
    for declaration in vcat(get(domain,"constants",Any[]),get(problem,"objects",Any[]))
        typ=string(get(declaration,"type","object"))
        haskey(type_parent,typ) || push!(diags,Diagnostic(code="PDDLICA-MODEL-008",
            message="'$(declaration["name"])' uses unknown type '$typ'"))
    end
    for connector in values(connectors)
        duplicate_names(get(connector,"fields",Any[]),"field in $(connector["name"])")
        for field in get(connector,"fields",Any[])
            string(get(field,"category","")) in ("potential","flow") ||
                push!(diags,Diagnostic(code="PDDLICA-MODEL-009",
                    message="connector field '$(connector["name"]).$(field["name"])' has invalid category"))
            string(get(field,"value_type",""))=="number" ||
                push!(diags,Diagnostic(code="PDDLICA-MODEL-009",
                    message="connector field '$(connector["name"]).$(field["name"])' must be numeric"))
        end
    end
    for ct in values(ctypes)
        n=string(ct["name"])
        q=n; component_subtype=false; checked=Set{String}()
        while haskey(type_parent,q) && !(q in checked)
            push!(checked,q)
            type_parent[q]=="component" && (component_subtype=true; break)
            q=type_parent[q]
        end
        !component_subtype && push!(diags,Diagnostic(code="PDDLICA-MODEL-007",
            message="component type '$n' is not a subtype of component"))
        duplicate_names(get(ct,"variables",Any[]),"variable in $n")
        duplicate_names(get(ct,"ports",Any[]),"port in $n")
        for p in get(ct,"ports",Any[])
            haskey(connectors,string(p["connector_type"])) || push!(diags,Diagnostic(code="PDDLICA-MODEL-006",
                message="port '$n.$(p["name"])' uses unknown connector type '$(p["connector_type"])'"))
            string(get(p,"presence","")) in ("required","optional") || push!(diags,
                Diagnostic(code="PDDLICA-MODEL-006",
                    message="port '$n.$(p["name"])' has invalid presence category"))
        end
        for sub in get(ct,"subcomponents",Any[])
            haskey(ctypes,string(sub["component_type"])) || push!(diags,Diagnostic(
                code="PDDLICA-MODEL-001",
                message="subcomponent '$n.$(sub["name"])' uses unknown component type '$(sub["component_type"])'"))
        end
    end

    object_decls=Any[]
    append!(object_decls,get(domain,"constants",Any[])); append!(object_decls,get(problem,"objects",Any[]))
    for c in get(problem,"components",Any[])
        push!(object_decls,Dict{String,Any}("name"=>c["name"],"type"=>c["component_type"],"component"=>true))
    end
    function is_subtype(t,wanted)
        wanted=="object" && return true
        while !isempty(t)
            t==wanted && return true
            t=get(type_parent,t,"")
        end
        false
    end
    function ground_parameters(decls,index=1,env=String[])
        index>length(decls) && return [copy(env)]
        values=Vector{Vector{String}}()
        for o in object_decls
            is_subtype(string(get(o,"type","object")),string(get(decls[index],"type","object"))) || continue
            append!(values,ground_parameters(decls,index+1,vcat(env,[string(o["name"])])))
        end
        values
    end

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

    initial=Dict{String,Any}(); initial_types=Dict{String,String}()
    for (key,inst) in components
        ct=ctypes[inst.component_type]
        for v in get(ct,"variables",Any[])
            # Missing values remain visible and are diagnosed after init lowering.
            params=get(v,"parameters",Any[]); tuples=ground_parameters(params)
            for args in tuples
                base=_statekey(inst.path,string(v["name"])); key=isempty(args) ? base : base*"("*join(args,",")*")"
                initial[key]=nothing; initial_types[key]=string(v["value_type"])
            end
        end
    end
    for f in get(domain,"functions",Any[])
        for args in ground_parameters(get(f,"parameters",Any[]))
            name=string(f["name"]); key=isempty(args) ? name : name*"("*join(args,",")*")"
            initial[key]=nothing; initial_types[key]=string(get(f,"returns","number"))
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
            elseif haskey(initial,key)
                initial[key]=val
            else
                push!(diags,Diagnostic(code="PDDLICA-MODEL-024",message="initial equality has unknown target '$key'"))
            end
        elseif get(e,"kind","") == "fact"
            a=e["atom"]; args=get(a,"arguments",Any[])
            signature=findfirst(p->string(p["name"])==string(a["name"]),
                get(domain,"predicates",Any[]))
            if isnothing(signature)
                push!(diags,Diagnostic(code="PDDLICA-MODEL-026",
                    message="initial fact uses unknown predicate '$(a["name"])'"))
            elseif length(args)!=length(get(domain["predicates"][signature],"parameters",Any[]))
                push!(diags,Diagnostic(code="PDDLICA-MODEL-027",
                    message="initial fact '$(a["name"])' has the wrong number of arguments"))
            end
            key=string(a["name"]) * "(" * join(_argument_name.(args),",") * ")"
            initial[key]=Bool(e["value"])
        end
    end

    for (key,val) in initial
        isnothing(val) && push!(diags, Diagnostic(code="PDDLICA-MODEL-022",
            message="component variable '$key' has no initial value"))
        typ=get(initial_types,key,"object")
        !isnothing(val) && typ=="number" && !(val isa Number) && push!(diags,Diagnostic(code="PDDLICA-MODEL-025",
            message="numeric fluent '$key' must have a numeric initial value"))
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
        length(ps)>=2 || push!(diags,Diagnostic(code="PDDLICA-MODEL-032",message="a connection requires at least two ports"))
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
    connection_sets=sort!([sort!(copy(group)) for group in values(groups)];
        by=group->isempty(group) ? "" : first(group))

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
    for b in get(domain,"durative_actions",Any[])
        copyb=deepcopy(b); copyb["_kind"]="durative_action"; behaviors[string(b["id"])]=copyb
    end

    derived=Dict{String,Any}(string(d["name"])=>d for d in get(domain,"derived_predicates",Any[]))
    global_mutable=Set{String}(string(x["name"]) for x in vcat(get(domain,"predicates",Any[]),get(domain,"functions",Any[])))
    derived_names=Set{String}(keys(derived))
    function validate_effect(e, owner_type=nothing)
        kind=get(e,"kind","")
        if kind=="and"
            foreach(x->validate_effect(x,owner_type),get(e,"items",Any[]))
        elseif kind=="when"
            validate_effect(e["effect"],owner_type)
        elseif kind=="forall"
            validate_effect(e["effect"],owner_type)
        elseif kind in ("assign","increase","decrease","scale_up","scale_down")
            target=e["target"]
            get(target,"kind","")=="port_field" && (push!(diags,Diagnostic(code="PDDLICA-MODEL-040",
                message="connector fields cannot be effect targets")); return)
            name=string(get(target,"name",""))
            if !isnothing(owner_type)
                vars=Dict{String,Any}(string(v["name"])=>v for v in get(ctypes[owner_type],"variables",Any[]))
                if haskey(vars,name)
                    Bool(get(vars[name],"static",false)) && push!(diags,Diagnostic(code="PDDLICA-MODEL-041",
                        message="static variable '$owner_type.$name' cannot be changed"))
                    return
                end
            end
            name in global_mutable || push!(diags,Diagnostic(code="PDDLICA-MODEL-042",message="unknown effect target '$name'"))
        elseif kind=="set_atom"
            name=string(get(e["atom"],"name",""))
            name in derived_names && push!(diags,Diagnostic(code="PDDLICA-MODEL-043",message="derived predicate '$name' cannot be changed"))
            (name in global_mutable || name in derived_names) || push!(diags,Diagnostic(code="PDDLICA-MODEL-042",message="unknown predicate effect target '$name'"))
        end
    end
    for b in get(domain,"actions",Any[]); validate_effect(b["effect"]) end
    for b in get(domain,"events",Any[]); validate_effect(b["effect"]) end
    for b in get(domain,"durative_actions",Any[]), x in get(b,"effects",Any[]); validate_effect(x["effect"]) end
    for b in get(domain,"processes",Any[]), e in get(b,"effects",Any[])
        name=string(get(e["target"],"name",""))
        name in global_mutable || push!(diags,Diagnostic(code="PDDLICA-MODEL-042",message="unknown process target '$name'"))
    end
    for (typ,ct) in ctypes
        for field in ("methods","events"), b in get(ct,field,Any[]); validate_effect(b["effect"],typ) end
        vars=Dict{String,Any}(string(v["name"])=>v for v in get(ct,"variables",Any[]))
        for b in get(ct,"processes",Any[]), e in get(b,"effects",Any[])
            name=string(get(e["target"],"name",""))
            haskey(vars,name) || push!(diags,Diagnostic(code="PDDLICA-MODEL-042",message="unknown process target '$typ.$name'"))
            haskey(vars,name) && Bool(get(vars[name],"static",false)) && push!(diags,Diagnostic(code="PDDLICA-MODEL-041",
                message="static variable '$typ.$name' cannot be changed"))
        end
    end

    preferences=Any[]
    function hard_formula(f)
        get(f,"kind","")=="preference" && (push!(preferences,f); return Dict{String,Any}("kind"=>"boolean","value"=>true))
        if get(f,"kind","") in ("and","or")
            copyf=deepcopy(f); copyf["items"]=Any[hard_formula(x) for x in f["items"]]; return copyf
        elseif get(f,"kind","")=="not"
            copyf=deepcopy(f); copyf["item"]=hard_formula(f["item"]); return copyf
        end
        f
    end
    hardgoal=hard_formula(get(problem,"goal",Dict("kind"=>"boolean","value"=>true)))
    provenance=Dict{String,Any}("initial_interface"=>initial_iface,"objects"=>object_decls,
        "type_parent"=>type_parent,"derived_predicates"=>derived,
        "constraints"=>get(problem,"constraints",Any[]),"preferences"=>preferences,
        "metric"=>get(problem,"metric",nothing),"timed_initials"=>get(problem,"timed_initials",Any[]))
    model=ElaboratedModel(document=doc,digest=semantic_digest(doc),components=components,
        component_types=ctypes,connector_types=connectors,behaviors=behaviors,
        initial_values=initial,initial_presence=presence,connection_sets=connection_sets,
        goal=hardgoal,provenance=provenance)
    isempty(diags) ? ElaborationResult(model=model) : ElaborationResult(diagnostics=diags)
end
