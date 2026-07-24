_copy_state(s::RuntimeState) = RuntimeState(time=s.time,microstep=s.microstep,
    values=deepcopy(s.values),interface=deepcopy(s.interface),presence=deepcopy(s.presence),
    boundary=deepcopy(s.boundary),history=deepcopy(s.history),open_duratives=deepcopy(s.open_duratives))

function _record_trajectories!(store, state::RuntimeState, phase::Symbol)
    function record(name, kind, value)
        series = get!(store, name) do
            VariableTrajectory(name=name, kind=kind)
        end
        push!(series.times, state.time)
        push!(series.values, value)
        push!(series.phases, phase)
    end
    for (name, value) in state.values
        record(name, :stored, value)
    end
    for (name, value) in state.interface
        record(name, :interface, value)
    end
    for (name, value) in state.presence
        record("@presence/" * name, :presence, value)
    end
    store
end

function _component_path(expr, owner, params)
    kind=get(expr,"kind","")
    if kind == "self"; return owner
    elseif kind in ("symbol","variable")
        name=string(get(expr,"name","")); value=get(params,name,name)
        return value isa AbstractVector ? join(value,'.') : string(value)
    elseif kind in ("instance","component")
        p=get(expr,"path",Dict{String,Any}())
        return p isa AbstractDict ? join(get(p,"segments",Any[]),'.') : join(p,'.')
    end
    ""
end

function _resolve_call(name, args, state, owner, params)
    vals=Any[_eval_value(a,state,owner,params) for a in args]
    if !isempty(owner)
        base=_statekey(split(owner,'.'),name)
        localkey=isempty(vals) ? base : base*"("*join(string.(vals),",")*")"
        haskey(state.values,localkey) && return state.values[localkey]
    end
    if !isempty(vals)
        candidate=_statekey(split(string(vals[1]),'.'),name)
        length(vals)>1 && (candidate*= "("*join(string.(vals[2:end]),",")*")")
        haskey(state.values,candidate) && return state.values[candidate]
    end
    key=isempty(vals) ? name : name*"("*join(string.(vals),",")*")"
    get(state.values,key,nothing)
end

function _eval_value(expr, state::RuntimeState, owner="", params=Dict{String,Any}(); interface=state.interface)
    expr isa Number && return expr
    expr isa AbstractString && return expr
    kind=get(expr,"kind","")
    if kind == "number"; return _parse_time(expr["value"])
    elseif kind == "symbol"
        string(expr["name"]) == "#t" && return 1.0
        return get(params,string(expr["name"]),string(expr["name"]))
    elseif kind == "variable"; return get(params,string(expr["name"]),nothing)
    elseif kind == "self"; return owner
    elseif kind == "instance"; return _component_path(expr,owner,params)
    elseif kind == "call"
        return _resolve_call(string(expr["name"]),get(expr,"arguments",Any[]),state,owner,params)
    elseif kind == "port_field"
        port=expr["port"]; inst=port["instance"]; anchor=get(inst,"anchor","self")
        base=anchor == "self" ? (isempty(owner) ? String[] : split(owner,'.')) : String[]
        path=vcat(base,String[string(x) for x in get(inst,"segments",Any[])])
        return get(interface,_portkey(path,string(port["port"]))*"."*string(expr["field"]),NaN)
    elseif kind == "arithmetic"
        vals=[_eval_value(a,state,owner,params;interface=interface) for a in expr["arguments"]]
        any(isnothing,vals) && return nothing
        op=expr["operator"]
        op=="+" && return sum(vals); op=="*" && return prod(vals)
        op=="-" && return length(vals)==1 ? -vals[1] : vals[1]-vals[2]
        op=="/" && return vals[1]/vals[2]
        op=="min" && return minimum(vals); op=="max" && return maximum(vals)
    end
    nothing
end

function _objects_for(model, typ)
    isnothing(model) && return String[]
    parent=get(model.provenance,"type_parent",Dict{String,String}())
    subtype(t,wanted)=begin
        wanted=="object" && return true
        while !isempty(t)
            t==wanted && return true
            t=get(parent,t,"")
        end
        false
    end
    String[string(o["name"]) for o in get(model.provenance,"objects",Any[])
        if subtype(string(get(o,"type","object")),string(typ))]
end

function _bindings(model, declarations, params)
    out=[copy(params)]
    for p in declarations
        next=Dict{String,Any}[]
        for env in out, object in _objects_for(model,get(p,"type","object"))
            e=copy(env); e[string(p["name"])]=object; push!(next,e)
        end
        out=next
    end
    out
end

function _eval_formula(f, state::RuntimeState, owner="", params=Dict{String,Any}(); interface=state.interface, model=nothing, derived_stack=Set{String}())
    kind=get(f,"kind","")
    if kind == "boolean"; return Bool(f["value"])
    elseif kind == "atom"
        if !isnothing(model)
            derived=get(model.provenance,"derived_predicates",Dict{String,Any}())
            name=string(f["name"])
            if haskey(derived,name) && !(name in derived_stack)
                d=derived[name]; env=copy(params)
                for (p,a) in zip(get(d,"parameters",Any[]),get(f,"arguments",Any[]))
                    env[string(p["name"])]=_eval_value(a,state,owner,params;interface=interface)
                end
                return _eval_formula(d["body"],state,owner,env;interface=interface,model=model,
                    derived_stack=union(derived_stack,Set([name])))
            end
        end
        v=_resolve_call(string(f["name"]),get(f,"arguments",Any[]),state,owner,params)
        return v === true
    elseif kind == "present"
        return get(state.presence,_component_path(f["component"],owner,params),false)
    elseif kind == "not"; return !_eval_formula(f["item"],state,owner,params;interface=interface,model=model,derived_stack=derived_stack)
    elseif kind == "and"; return all(_eval_formula(x,state,owner,params;interface=interface,model=model,derived_stack=derived_stack) for x in f["items"])
    elseif kind == "or"; return any(_eval_formula(x,state,owner,params;interface=interface,model=model,derived_stack=derived_stack) for x in f["items"])
    elseif kind == "imply"
        return !_eval_formula(f["antecedent"],state,owner,params;interface=interface,model=model,derived_stack=derived_stack) ||
            _eval_formula(f["consequent"],state,owner,params;interface=interface,model=model,derived_stack=derived_stack)
    elseif kind in ("forall","exists")
        vals=(_eval_formula(f["body"],state,owner,e;interface=interface,model=model,derived_stack=derived_stack)
            for e in _bindings(model,get(f,"parameters",Any[]),params))
        return kind=="forall" ? all(vals) : any(vals)
    elseif kind == "preference"
        return _eval_formula(f["body"],state,owner,params;interface=interface,model=model,derived_stack=derived_stack)
    elseif kind == "compare"
        a=_eval_value(f["left"],state,owner,params;interface=interface)
        b=_eval_value(f["right"],state,owner,params;interface=interface)
        (isnothing(a)||isnothing(b)||a isa AbstractFloat&&isnan(a)||b isa AbstractFloat&&isnan(b)) && return false
        op=f["operator"]
        if a isa Number && b isa Number
            tol=1e-8
            return op=="=" ? abs(a-b)<=tol : op=="!=" ? abs(a-b)>tol :
                op=="<" ? a<b-tol : op=="<=" ? a<=b+tol : op==">" ? a>b+tol : a>=b-tol
        end
        return op=="=" ? a==b : op=="!=" ? a!=b : false
    end
    false
end

function _has_port(x)
    x isa AbstractVector && return any(_has_port, x)
    x isa AbstractDict || return false
    get(x,"kind","") == "port_field" && return true
    any(_has_port(v) for v in values(x))
end

function _active(state, component)
    parts=split(component,'.')
    all(get(state.presence,join(parts[1:i],'.'),false) for i in eachindex(parts))
end

function _component_requirements(model,state)
    out=Tuple{String,Any}[]
    for (key,inst) in model.components
        _active(state,key) || continue
        for r in get(model.component_types[inst.component_type],"requirements",Any[])
            push!(out,(key,r["formula"]))
        end
    end
    out
end

function _active_fields(model,state)
    fieldmeta=Dict{String,Dict{String,Any}}()
    for (owner,inst) in model.components
        _active(state,owner) || continue
        for (pname,p) in inst.ports
            ctype=get(model.connector_types,string(p["connector_type"]),nothing)
            isnothing(ctype) && continue
            for f in get(ctype,"fields",Any[])
                fieldmeta["$owner.$pname.$(f["name"])"]=f
            end
        end
    end
    fieldmeta
end

function _interface_equation_formulas(f,owner,state,model=nothing)
    kind=get(f,"kind","")
    if kind == "and"
        return reduce(vcat,(_interface_equation_formulas(x,owner,state,model) for x in f["items"]);init=Tuple{String,Any}[])
    elseif kind == "imply"
        _has_port(f["antecedent"]) && throw(ArgumentError(
            "connector-dependent requirement branches are not supported"))
        return _eval_formula(f["antecedent"],state,owner;model=model) ? _interface_equation_formulas(f["consequent"],owner,state,model) : Tuple{String,Any}[]
    elseif kind == "compare" && _has_port(f)
        return [(owner,f)]
    elseif _has_port(f)
        throw(ArgumentError("connector formula kind '$kind' is not supported"))
    end
    Tuple{String,Any}[]
end

function _residual(f,state,owner,iface)
    a=_eval_value(f["left"],state,owner,Dict{String,Any}();interface=iface)
    b=_eval_value(f["right"],state,owner,Dict{String,Any}();interface=iface)
    Float64(a-b)
end

function _try_symbolic_interface(A,b)
    m=size(A,2); m==0 && return nothing
    try
        ModelingToolkit.@independent_variables t
        ModelingToolkit.@variables y(t)[1:m]
        eqs=[sum(A[i,j]*y[j] for j in 1:m) ~ b[i] for i in axes(A,1)]
        sys=ModelingToolkit.System(eqs,t;name=:pddlica_interface)
        ModelingToolkit.mtkcompile(sys;fully_determined=true)
    catch
        nothing
    end
end

function _resolve_interface(model,state; update_history=true, symbolic_cache=nothing, tolerance=1e-9)
    meta=_active_fields(model,state); unknowns=sort!(collect(keys(meta))); idx=Dict(k=>i for (i,k) in enumerate(unknowns))
    rows=Vector{Vector{Float64}}(); rhs=Float64[]; inequalities=Tuple{String,Any}[]
    function addrow(coeff, value); push!(rows,coeff); push!(rhs,value) end

    # Modelica connection equations.
    for staticset in model.connection_sets
        active=[p for p in staticset if _active(state,rsplit(p,'.';limit=2)[1])]
        isempty(active) && continue
        owner,pname=rsplit(active[1],'.';limit=2); port=model.components[owner].ports[pname]
        ctype=get(model.connector_types,string(port["connector_type"]),Dict{String,Any}())
        for field in get(ctype,"fields",Any[])
            fname=string(field["name"]); category=string(field["category"])
            keys=["$p.$fname" for p in active]
            if length(active)>=2 && category=="potential"
                for k in keys[2:end]
                    row=zeros(length(unknowns)); row[idx[k]]=1; row[idx[keys[1]]]=-1; addrow(row,0.0)
                end
            elseif length(active)>=2 && category=="flow"
                row=zeros(length(unknowns)); for k in keys; row[idx[k]]+=1 end; addrow(row,0.0)
            elseif length(active)==1
                string(port["presence"])=="required" && return nothing, Diagnostic(code="PDDLICA-SIM-IFACE-001",
                    message="required port '$(active[1])' is a singleton")
                key=keys[1]; row=zeros(length(unknowns)); row[idx[key]]=1
                if category=="flow"; addrow(row,0.0)
                elseif haskey(state.boundary,key); addrow(row,state.boundary[key])
                elseif haskey(state.history,key); addrow(row,state.history[key])
                else
                    init=get(model.provenance["initial_interface"],key,nothing)
                    isnothing(init) || addrow(row,Float64(init))
                end
            end
        end
    end

    # Component constitutive equations are numerically affine-linearized.
    for (owner,req) in _component_requirements(model,state)
        if !_has_port(req)
            _eval_formula(req,state,owner;model=model) || return nothing, Diagnostic(code="PDDLICA-SIM-REQ-001",
                message="component requirement failed for '$owner'")
            continue
        end
        formulas=try
            _interface_equation_formulas(req,owner,state,model)
        catch err
            return nothing,Diagnostic(code="PDDLICA-SIM-IFACE-005",
                message=sprint(showerror,err))
        end
        for (reqowner,f) in formulas
            if get(f,"operator","") != "="; push!(inequalities,(reqowner,f)); continue end
            zeroiface=Dict(k=>0.0 for k in unknowns); c=_residual(f,state,reqowner,zeroiface)
            row=zeros(length(unknowns))
            for (k,j) in idx
                one=copy(zeroiface); one[k]=1.0; row[j]=_residual(f,state,reqowner,one)-c
                two=copy(zeroiface); two[k]=2.0
                abs((_residual(f,state,reqowner,two)-c)-2row[j]) <= 1e-7 || return nothing,
                    Diagnostic(code="PDDLICA-SIM-IFACE-004",message="nonlinear interface equation is unsupported")
            end
            names=collect(keys(idx))
            for a in 1:length(names), z in a+1:length(names)
                both=copy(zeroiface); both[names[a]]=1.0; both[names[z]]=1.0
                expected=c+row[idx[names[a]]]+row[idx[names[z]]]
                abs(_residual(f,state,reqowner,both)-expected)<=1e-7 || return nothing,
                    Diagnostic(code="PDDLICA-SIM-IFACE-004",
                        message="nonlinear interface equation is unsupported")
            end
            addrow(row,-c)
        end
    end
    if isempty(unknowns); return Dict{String,Float64}(),nothing end
    A=isempty(rows) ? zeros(0,length(unknowns)) : reduce(vcat,(permutedims(r) for r in rows)); b=rhs
    rA=rank(A;atol=tolerance); rAug=rank(hcat(A,b);atol=tolerance)
    rAug>rA && return nothing,Diagnostic(code="PDDLICA-SIM-IFACE-002",message="active interface has no solution")
    rA<length(unknowns) && return nothing,Diagnostic(code="PDDLICA-SIM-IFACE-003",
        message="active interface has multiple solutions ($(length(unknowns)-rA) free fields)")
    y=A\b; iface=Dict(k=>Float64(y[j]) for (k,j) in idx)
    for (owner,f) in inequalities
        _eval_formula(f,state,owner;interface=iface,model=model) || return nothing,Diagnostic(code="PDDLICA-SIM-REQ-002",
            message="interface requirement failed for '$owner'")
    end
    if update_history
        state.interface=iface
        merge!(state.history,iface)
        for staticset in model.connection_sets
            active=[p for p in staticset if _active(state,rsplit(p,'.';limit=2)[1])]
            length(active)==1 || continue
            p=active[1]; owner,pname=rsplit(p,'.';limit=2); port=model.components[owner].ports[pname]
            string(port["presence"])=="optional" || continue
            ctype=model.connector_types[string(port["connector_type"])]
            for f in get(ctype,"fields",Any[])
                string(f["category"])=="potential" || continue
                key="$p.$(f["name"])"; haskey(iface,key) && (state.boundary[key]=iface[key])
            end
        end
    end
    if !isnothing(symbolic_cache)
        signature=(Tuple(unknowns),size(A),Tuple(findall(!iszero,A)))
        haskey(symbolic_cache,signature) || (symbolic_cache[signature]=_try_symbolic_interface(A,b))
    end
    iface,nothing
end

function _ground_behaviors(model,state,kind)
    out=Tuple{String,Dict{String,Any}}[]
    function emit(owner,b)
        envs=_bindings(model,get(b,"parameters",Any[]),Dict{String,Any}())
        for env in envs
            grounded=isempty(env) ? b : deepcopy(b)
            isempty(env) || (grounded["_ground_params"]=env)
            push!(out,(owner,grounded))
        end
    end
    for b in values(model.behaviors)
        get(b,"_kind","")==kind || continue
        if haskey(b,"_owner_type")
            for (owner,inst) in model.components
                inst.component_type==b["_owner_type"] && _active(state,owner) && emit(owner,b)
            end
        else
            emit("",b)
        end
    end
    out
end

function _target_key(target,state,owner,params)
    name=string(get(target,"name","")); args=get(target,"arguments",Any[])
    if !isempty(owner)
        vals=[_eval_value(a,state,owner,params) for a in args]; base=_statekey(split(owner,'.'),name)
        return isempty(vals) ? base : base*"("*join(string.(vals),",")*")"
    end
    if !isempty(args)
        vals=[_eval_value(a,state,owner,params) for a in args]
        candidate=_statekey(split(string(vals[1]),'.'),name)
        length(vals)>1 && (candidate*= "("*join(string.(vals[2:end]),",")*")")
        haskey(state.values,candidate) && return candidate
    end
    vals=[_eval_value(a,state,owner,params) for a in args]
    isempty(vals) ? name : name*"("*join(string.(vals),",")*")"
end

function _value_reads(v,state,owner,params)
    v isa AbstractDict || return Set{String}()
    kind=get(v,"kind","")
    if kind=="call"
        reads=Set([_target_key(v,state,owner,params)])
        for a in get(v,"arguments",Any[]); union!(reads,_value_reads(a,state,owner,params)) end
        return reads
    elseif kind=="arithmetic"
        return reduce(union,(_value_reads(x,state,owner,params) for x in get(v,"arguments",Any[]));init=Set{String}())
    end
    Set{String}()
end

function _formula_reads(f,state,owner,params)
    f isa AbstractDict || return Set{String}()
    kind=get(f,"kind",""); reads=Set{String}()
    if kind=="atom"
        push!(reads,_target_key(Dict{String,Any}("name"=>f["name"],"arguments"=>get(f,"arguments",Any[])),state,owner,params))
    elseif kind=="compare"
        union!(reads,_value_reads(f["left"],state,owner,params),_value_reads(f["right"],state,owner,params))
    end
    for key in ("item","antecedent","consequent","body")
        haskey(f,key) && union!(reads,_formula_reads(f[key],state,owner,params))
    end
    for x in get(f,"items",Any[]); union!(reads,_formula_reads(x,state,owner,params)) end
    reads
end

function _effect_operations(effect,state,owner,params,model=nothing)
    kind=get(effect,"kind",""); ops=Pair{String,Any}[]
    if kind=="and"
        for e in get(effect,"items",Any[])
            append!(ops,_effect_operations(e,state,owner,params,model))
        end
    elseif kind == "when"
        _eval_formula(effect["condition"],state,owner,params;model=model) &&
            append!(ops,_effect_operations(effect["effect"],state,owner,params,model))
    elseif kind == "forall"
        for env in _bindings(model,get(effect,"parameters",Any[]),params)
            append!(ops,_effect_operations(effect["effect"],state,owner,env,model))
        end
    elseif kind in ("assign","increase","decrease","scale_up","scale_down")
        key=_target_key(effect["target"],state,owner,params); value=_eval_value(effect["value"],state,owner,params)
        push!(ops,key=>(kind,value))
    elseif kind=="set_atom"
        a=effect["atom"]; target=Dict{String,Any}("kind"=>"call","name"=>a["name"],"arguments"=>get(a,"arguments",Any[]))
        push!(ops,_target_key(target,state,owner,params)=>("assign",Bool(effect["value"])))
    elseif kind in ("create","remove")
        component=_component_path(effect["component"],owner,params)
        push!(ops,"@presence:"*component=>("assign",kind=="create"))
    end
    ops
end

function _resolve_operations(state,ops)
    grouped=Dict{String,Vector{Any}}()
    for (key,op) in ops; push!(get!(grouped,key,Any[]),op) end
    writes=Dict{String,Any}()
    for (key,items) in grouped
        kinds=first.(items); values=last.(items); old=get(state.values,key,0.0)
        if all(k->k in ("increase","decrease"),kinds)
            writes[key]=old+sum(k=="increase" ? v : -v for (k,v) in items)
        elseif all(==("assign"),kinds) && all(==(values[1]),values)
            writes[key]=values[1]
        elseif length(items)==1
            k,v=items[1]; writes[key]=k=="assign" ? v : k=="scale_up" ? old*v : k=="scale_down" ? old/v :
                k=="increase" ? old+v : old-v
        else
            throw(ArgumentError("conflicting simultaneous effects on '$key'"))
        end
    end
    writes
end

_effect_writes(effect,state,owner,params,model=nothing) =
    _resolve_operations(state,_effect_operations(effect,state,owner,params,model))

function _params_for(b,occ)
    out=Dict{String,Any}()
    decls=get(b,"parameters",Any[])
    for (i,p) in enumerate(decls)
        i<=length(occ.arguments) || continue
        a=occ.arguments[i]; out[string(p["name"])]=_argument_name(a)
    end
    out
end

function _set_presence!(state,component,value)
    haskey(state.presence,component) || return false
    state.presence[component]=Bool(value)
    true
end

_timed_items(b,timing,key) = Any[get(x,key,Dict{String,Any}()) for x in get(b,
    key=="formula" ? "conditions" : "effects",Any[]) if get(x,"timing","")==timing]

function _durative_condition(b,timing,state,params,model)
    all(_eval_formula(f,state,"",params;model=model) for f in _timed_items(b,timing,"formula"))
end

function _apply_happening!(model,state,occs)
    operations=Pair{String,Any}[]
    occurrence_reads=Set{String}[]; occurrence_writes=Set{String}[]
    for occ in occs
        b=get(model.behaviors,occ.schema_id,nothing)
        isnothing(b) && return Diagnostic(code="PDDLICA-SIM-PLAN-001",message="unknown behavior '$(occ.schema_id)'")
        owner=occ.kind==:method ? join(occ.owner,'.') : ""
        bkind=get(b,"_kind","")
        bkind in ("method","action","durative_action") || return Diagnostic(code="PDDLICA-SIM-PLAN-002",message="behavior is not controllable")
        !isempty(owner) && !_active(state,owner) && return Diagnostic(code="PDDLICA-SIM-PLAN-003",message="component '$owner' is absent")
        params=_params_for(b,occ)
        length(occ.arguments)==length(get(b,"parameters",Any[])) || return Diagnostic(
            code="PDDLICA-SIM-PLAN-008",message="'$(occ.name)' expects $(length(get(b,"parameters",Any[]))) arguments, got $(length(occ.arguments))")
        if bkind=="method"
            haskey(model.components,owner) || return Diagnostic(code="PDDLICA-SIM-PLAN-009",message="unknown method owner '$owner'")
            model.components[owner].component_type==get(b,"_owner_type","") || return Diagnostic(
                code="PDDLICA-SIM-PLAN-010",message="method '$(occ.name)' does not belong to component '$owner'")
        end
        if bkind=="durative_action"
            phase=occ.kind==:durative_end ? "end" : "start"
            params["duration"]=something(occ.duration,0.0)
            if phase=="start" && haskey(b,"duration_constraint") &&
                    !_eval_formula(b["duration_constraint"],state,"",params;model=model)
                return Diagnostic(code="PDDLICA-SIM-DUR-007",message="duration constraint failed for '$(occ.name)'")
            end
            if phase=="start"
                (_durative_condition(b,"start",state,params,model) && _durative_condition(b,"over_all",state,params,model)) ||
                    return Diagnostic(code="PDDLICA-SIM-DUR-001",message="durative start/overall condition failed for '$(occ.name)'")
            else
                haskey(state.open_duratives,replace(occ.id,r"/end$"=>"")) || return Diagnostic(
                    code="PDDLICA-SIM-DUR-002",message="durative endpoint has no matching start")
                (_durative_condition(b,"end",state,params,model) && _durative_condition(b,"over_all",state,params,model)) ||
                    return Diagnostic(code="PDDLICA-SIM-DUR-003",message="durative end/overall condition failed for '$(occ.name)'")
            end
        else
            _eval_formula(b["precondition"],state,owner,params;model=model) || return Diagnostic(code="PDDLICA-SIM-PLAN-004",
                message="precondition failed for '$(occ.name)' at $(state.time)")
        end
        try
            selected=bkind=="durative_action" ? _timed_items(b,occ.kind==:durative_end ? "end" : "start","effect") : Any[b["effect"]]
            localops=Pair{String,Any}[]
            for eff in selected; append!(localops,_effect_operations(eff,state,owner,params,model)) end
            append!(operations,localops); push!(occurrence_writes,Set(first.(localops)))
            if bkind=="durative_action"
                timing=occ.kind==:durative_end ? "end" : "start"
                push!(occurrence_reads,reduce(union,(_formula_reads(f,state,owner,params) for f in _timed_items(b,timing,"formula"));init=Set{String}()))
            else
                push!(occurrence_reads,_formula_reads(b["precondition"],state,owner,params))
            end
        catch err
            return Diagnostic(code="PDDLICA-SIM-PLAN-005",message=sprint(showerror,err))
        end
    end
    for i in eachindex(occurrence_writes), j in eachindex(occurrence_reads)
        i==j && continue
        overlap=intersect(occurrence_writes[i],occurrence_reads[j])
        isempty(overlap) || return Diagnostic(code="PDDLICA-SIM-PLAN-013",
            message="simultaneous happenings violate the no-moving-target rule on '$(first(overlap))'")
    end
    allwrites=try _resolve_operations(state,operations) catch err
        return Diagnostic(code="PDDLICA-SIM-PLAN-005",message=sprint(showerror,err))
    end
    for (k,v) in allwrites
        if startswith(k,"@presence:")
            component=k[11:end]; haskey(state.presence,component) || return Diagnostic(code="PDDLICA-SIM-PLAN-006",message="unknown lifecycle target '$component'")
            _set_presence!(state,component,v)
        else
            state.values[k]=v
        end
    end
    for occ in occs
        b=get(model.behaviors,occ.schema_id,nothing); isnothing(b) && continue
        get(b,"_kind","")=="durative_action" || continue
        if occ.kind==:durative_end
            delete!(state.open_duratives,replace(occ.id,r"/end$"=>""))
        else
            state.open_duratives[occ.id]=Dict{String,Any}("behavior"=>b,"params"=>_params_for(b,occ),
                "end_time"=>state.time+something(occ.duration,0.0))
        end
    end
    nothing
end

function _event_closure!(model,state,steps,cache,options,trajectories)
    seen=Set{String}()
    for layer in 1:options.max_event_layers
        enabled=Tuple{String,Dict{String,Any}}[]
        for (owner,b) in _ground_behaviors(model,state,"event")
            params=get(b,"_ground_params",Dict{String,Any}())
            _eval_formula(b["precondition"],state,owner,params;model=model) && push!(enabled,(owner,b))
        end
        isempty(enabled) && return nothing
        fingerprint=canonical_json(Dict("values"=>state.values,"presence"=>state.presence,"interface"=>state.interface))
        fingerprint in seen && return Diagnostic(code="PDDLICA-SIM-EVENT-002",message="urgent event closure entered a repeated state")
        push!(seen,fingerprint); operations=Pair{String,Any}[]
        for (owner,b) in enabled
            try
                append!(operations,_effect_operations(b["effect"],state,owner,get(b,"_ground_params",Dict{String,Any}()),model))
            catch err; return Diagnostic(code="PDDLICA-SIM-EVENT-001",message=sprint(showerror,err)) end
        end
        writes=try _resolve_operations(state,operations) catch err
            return Diagnostic(code="PDDLICA-SIM-EVENT-001",message=sprint(showerror,err))
        end
        for (k,v) in writes
            if startswith(k,"@presence:")
                _set_presence!(state,k[11:end],v) || return Diagnostic(code="PDDLICA-SIM-PLAN-006",message="unknown lifecycle target '$(k[11:end])'")
            else
                state.values[k]=v
            end
        end
        state.microstep+=1
        iface,diag=_resolve_interface(model,state;symbolic_cache=cache,tolerance=options.absolute_tolerance)
        !isnothing(diag) && return diag
        _record_trajectories!(trajectories,state,:event)
        push!(steps,Dict{String,Any}("kind"=>"event_layer","time"=>state.time,"microstep"=>state.microstep,
            "events"=>[b["id"] for (_,b) in enabled],"state"=>state_dict(state)))
    end
    Diagnostic(code="PDDLICA-SIM-EVENT-003",message="event closure exceeded max_event_layers")
end

function _continuous_keys(model)
    keys=String[]
    for (owner,inst) in model.components
        ct=model.component_types[inst.component_type]
        for v in get(ct,"variables",Any[])
            if string(v["value_type"])=="number" && !Bool(get(v,"static",false))
                base=_statekey(inst.path,string(v["name"]))
                append!(keys,[k for k in Base.keys(model.initial_values) if k==base || startswith(k,base*"(")])
            end
        end
    end
    for (k,v) in model.initial_values; v isa Number && !(k in keys) && push!(keys,k) end
    sort!(unique(keys))
end

function _derivatives!(du,u,model,state,keys,cache,options,t)
    trial=_copy_state(state); trial.time=t
    for (i,k) in enumerate(keys); trial.values[k]=u[i] end
    iface,diag=_resolve_interface(model,trial;update_history=false,symbolic_cache=cache,tolerance=options.absolute_tolerance)
    if !isnothing(diag); fill!(du,NaN); return end
    trial.interface=iface; fill!(du,0.0)
    for (owner,b) in _ground_behaviors(model,trial,"process")
        params=get(b,"_ground_params",Dict{String,Any}())
        _eval_formula(b["precondition"],trial,owner,params;model=model) || continue
        for e in get(b,"effects",Any[])
            key=_target_key(e["target"],trial,owner,params); i=findfirst(==(key),keys); isnothing(i)&&continue
            rate=_eval_value(e["rate"],trial,owner,params); du[i]+=(e["operator"]=="decrease" ? -1 : 1)*Float64(rate)
        end
    end
    for open in values(trial.open_duratives)
        b=open["behavior"]; params=open["params"]
        _durative_condition(b,"over_all",trial,params,model) || continue
        for e in _timed_items(b,"continuous","effect")
            for (key,rate) in _continuous_effect_rates(e,trial,"",params,model)
                i=findfirst(==(key),keys); isnothing(i) || (du[i]+=rate)
            end
        end
    end
end

function _continuous_effect_rates(e,state,owner,params,model)
    kind=get(e,"kind",""); out=Pair{String,Float64}[]
    if kind=="and"
        for x in get(e,"items",Any[]); append!(out,_continuous_effect_rates(x,state,owner,params,model)) end
    elseif kind=="when"
        _eval_formula(e["condition"],state,owner,params;model=model) &&
            append!(out,_continuous_effect_rates(e["effect"],state,owner,params,model))
    elseif kind=="forall"
        for env in _bindings(model,get(e,"parameters",Any[]),params)
            append!(out,_continuous_effect_rates(e["effect"],state,owner,env,model))
        end
    elseif kind in ("increase","decrease")
        rate=_eval_value(e["value"],state,owner,params)
        rate isa Number && push!(out,_target_key(e["target"],state,owner,params)=>Float64(kind=="decrease" ? -rate : rate))
    end
    out
end

function _guard_margin(f,state,owner,model=nothing,params=Dict{String,Any}())
    kind=get(f,"kind","")
    if kind=="compare"
        a=_eval_value(f["left"],state,owner,params); b=_eval_value(f["right"],state,owner,params)
        (a isa Number && b isa Number) || return nothing
        op=f["operator"]
        return op in (">",">=") ? a-b : op in ("<","<=") ? b-a : -abs(a-b)
    elseif kind=="and"
        numeric=Float64[]
        for item in f["items"]
            margin=_guard_margin(item,state,owner,model,params)
            if margin isa Number
                push!(numeric,Float64(margin))
            elseif !_eval_formula(item,state,owner,params;model=model)
                return 1.0
            end
        end
        isempty(numeric) && return nothing
        return minimum(numeric)
    end
    nothing
end

function _advance!(model,state,target,steps,cache,options,trajectories)
    target <= state.time+options.event_tolerance && return nothing
    keys=_continuous_keys(model)
    if isempty(keys)
        state.time=target
        _record_trajectories!(trajectories,state,:continuous)
        return nothing
    end
    segment_start=state.time
    u0=Float64[state.values[k] for k in keys]
    f! = (du,u,p,t) -> _derivatives!(du,u,model,state,keys,cache,options,t)
    callbacks=Any[]
    guards=vcat(_ground_behaviors(model,state,"event"),_ground_behaviors(model,state,"process"))
    for open in values(state.open_duratives), f in _timed_items(open["behavior"],"over_all","formula")
        push!(guards,("",Dict{String,Any}("precondition"=>f)))
    end
    for (owner,b) in guards
        condition=(u,t,integrator)->begin
            trial=_copy_state(state); trial.time=t
            for (i,k) in enumerate(keys); trial.values[k]=u[i] end
            iface,diag=_resolve_interface(model,trial;update_history=false,tolerance=options.absolute_tolerance)
            isnothing(diag) || return 1.0
            trial.interface=iface; m=_guard_margin(b["precondition"],trial,owner,model,get(b,"_ground_params",Dict{String,Any}()))
            isnothing(m) ? 1.0 : Float64(m)
        end
        affect! = integrator -> SciMLBase.terminate!(integrator)
        push!(callbacks,ContinuousCallback(condition,affect!,affect!;abstol=options.event_tolerance,
            reltol=options.event_tolerance,save_positions=(false,true)))
    end
    cb=isempty(callbacks) ? nothing : CallbackSet(callbacks...)
    prob=ODEProblem(f!,u0,(state.time,target))
    kwargs=(reltol=options.relative_tolerance,abstol=options.absolute_tolerance,
        save_everystep=options.save_everystep,maxiters=options.max_internal_steps)
    sol=isnothing(cb) ? solve(prob,AutoTsit5(Rodas5P());kwargs...) : solve(prob,AutoTsit5(Rodas5P());callback=cb,kwargs...)
    SciMLBase.successful_retcode(sol) || return Diagnostic(code="PDDLICA-SIM-NUM-001",message="continuous solver failed: $(sol.retcode)")

    sample_times=Float64[]
    if options.save_everystep
        append!(sample_times,Float64.(sol.t[2:max(1,end-1)]))
    elseif !isnothing(options.trajectory_interval)
        dt=options.trajectory_interval
        append!(sample_times,(segment_start+dt):dt:(sol.t[end]-dt/2))
    end
    for sample_time in sample_times
        trial=_copy_state(state); trial.time=sample_time
        sampled=sol(sample_time)
        for (i,k) in enumerate(keys); trial.values[k]=sampled[i] end
        iface,diag=_resolve_interface(model,trial;update_history=false,tolerance=options.absolute_tolerance)
        !isnothing(diag) && return diag
        trial.interface=iface
        _record_trajectories!(trajectories,trial,:continuous)
    end
    for (i,k) in enumerate(keys); state.values[k]=sol.u[end][i] end
    start=state.time; state.time=sol.t[end]
    iface,diag=_resolve_interface(model,state;symbolic_cache=cache,tolerance=options.absolute_tolerance)
    !isnothing(diag) && return diag
    _record_trajectories!(trajectories,state,:continuous)
    push!(steps,Dict{String,Any}("kind"=>"continuous","start_time"=>start,"end_time"=>state.time,
        "end_reason"=>(state.time<target-options.event_tolerance ? "guard" : "target"),"state"=>state_dict(state)))
    nothing
end

function _apply_timed_initial!(model,state,items)
    operations=Pair{String,Any}[]
    for item in items
        append!(operations,_effect_operations(item["effect"],state,"",Dict{String,Any}(),model))
    end
    writes=try _resolve_operations(state,operations) catch err
        return Diagnostic(code="PDDLICA-SIM-TIL-001",message=sprint(showerror,err))
    end
    for (k,v) in writes; state.values[k]=v end
    nothing
end

function _open_invariants(model,state)
    for (id,open) in state.open_duratives
        _durative_condition(open["behavior"],"over_all",state,open["params"],model) || return Diagnostic(
            code="PDDLICA-SIM-DUR-004",message="over-all condition failed for occurrence '$id' at $(state.time)")
    end
    nothing
end

function _observation_states(model,initial,steps,terminal,trajectories)
    out=RuntimeState[_copy_state(initial)]
    function fromdict(d)
        RuntimeState(time=_parse_time(d["time"]),microstep=Int(get(d,"microstep",0)),
            values=deepcopy(get(d,"stored",Dict{String,Any}())),interface=Dict{String,Float64}(
                string(k)=>Float64(v) for (k,v) in get(d,"interface",Dict{String,Any}())),
            presence=Dict{String,Bool}(string(k)=>Bool(v) for (k,v) in get(d,"presence",Dict{String,Any}())))
    end
    for step in steps
        if haskey(step,"state"); push!(out,fromdict(step["state"]))
        elseif haskey(step,"post_state"); push!(out,fromdict(step["post_state"])) end
    end
    semantic_times=Set(s.time for s in out)
    sample_times=sort!(unique(reduce(vcat,(x.times for x in values(trajectories));init=Float64[])))
    for t in sample_times
        any(x->abs(x-t)<=1e-12,semantic_times) && continue
        s=_copy_state(initial); s.time=t
        for (name,series) in trajectories
            i=findlast(x->x<=t+1e-12,series.times); isnothing(i) && continue
            if series.kind==:stored; s.values[name]=series.values[i]
            elseif series.kind==:interface; s.interface[name]=Float64(series.values[i])
            elseif series.kind==:presence; s.presence[replace(name,"@presence/"=>"")]=Bool(series.values[i]) end
        end
        push!(out,s)
    end
    push!(out,_copy_state(terminal)); sort!(out;by=s->(s.time,s.microstep),alg=Base.Sort.MergeSort)
end

function _constraint_truth(c,states,model,params=Dict{String,Any}())
    kind=get(c,"kind",""); truth(f,s)=_eval_formula(f,s,"",params;model=model)
    if kind=="preference"; return _constraint_truth(c["body"],states,model,params)
    elseif kind in ("forall","exists")
        vals=(_constraint_truth(c["body"],states,model,e) for e in _bindings(model,get(c,"parameters",Any[]),params))
        return kind=="forall" ? all(vals) : any(vals)
    elseif kind in ("and","or")
        vals=(_constraint_truth(x,states,model,params) for x in c["items"])
        return kind=="and" ? all(vals) : any(vals)
    elseif kind=="not"; return !_constraint_truth(c["item"],states,model,params)
    elseif kind=="imply"
        return !_constraint_truth(c["antecedent"],states,model,params) || _constraint_truth(c["consequent"],states,model,params)
    elseif kind=="always"; return all(truth(c["body"],s) for s in states)
    elseif kind=="sometime"; return any(truth(c["body"],s) for s in states)
    elseif kind=="within"
        deadline=_eval_value(c["times"][1],states[1]); return any(s.time<=deadline && truth(c["body"],s) for s in states)
    elseif kind=="at_most_once"
        values=[truth(c["body"],s) for s in states]; return count(i->values[i]&&(i==1||!values[i-1]),eachindex(values))<=1
    elseif kind in ("sometime_before","sometime_after")
        a=findall(s->truth(c["first"],s),states); b=findall(s->truth(c["second"],s),states)
        return kind=="sometime_before" ? all(j->any(i->states[i].time<states[j].time,a),b) :
            all(i->any(j->states[j].time>states[i].time,b),a)
    elseif kind=="always_within"
        delta=_eval_value(c["time"],states[1]); return all(i->any(j->states[j].time>=states[i].time &&
            states[j].time<=states[i].time+delta && truth(c["response"],states[j]),eachindex(states)),
            (i for i in eachindex(states) if truth(c["trigger"],states[i])))
    elseif kind=="hold_during"
        lo=_eval_value(c["times"][1],states[1]); hi=_eval_value(c["times"][2],states[1])
        return all(truth(c["body"],s) for s in states if lo<=s.time<=hi)
    elseif kind=="hold_after"
        lo=_eval_value(c["time"],states[1]); return all(truth(c["body"],s) for s in states if s.time>=lo)
    end
    truth(c,states[end])
end

function _metric_value(expr,state,violations)
    kind=get(expr,"kind","")
    kind=="number" && return _parse_time(expr["value"])
    if kind=="symbol"
        string(expr["name"])=="total-time" && return state.time
        return 0.0
    elseif kind=="call" && string(expr["name"])=="is-violated"
        args=get(expr,"arguments",Any[]); isempty(args) && return 0.0
        name=string(get(args[1],"name","")); return get(violations,name,false) ? 1.0 : 0.0
    elseif kind=="arithmetic"
        vals=[_metric_value(x,state,violations) for x in expr["arguments"]]; op=expr["operator"]
        op=="+" && return sum(vals); op=="*" && return prod(vals)
        op=="-" && return length(vals)==1 ? -vals[1] : vals[1]-vals[2]
        op=="/" && return vals[1]/vals[2]
    end
    value=_eval_value(expr,state); value isa Number ? value : nothing
end

function _diagnostic_status(d::Diagnostic)
    d.code in ("PDDLICA-SIM-IFACE-004","PDDLICA-SIM-IFACE-005") && return :UNSUPPORTED
    d.code in ("PDDLICA-SIM-NUM-001","PDDLICA-SIM-EVENT-003") && return :ERROR
    :INVALID
end

function simulate(model::ElaboratedModel,plan::PlanDocument;options=SimulationOptions())
    diags=Diagnostic[]; steps=Dict{String,Any}[]; cache=Dict{Any,Any}()
    trajectories=Dict{String,VariableTrajectory}()
    !isnothing(options.trajectory_interval) && options.trajectory_interval<=0 && return SimulationResult(
        status=:ERROR,plan=plan,trajectories=trajectories,
        diagnostics=[Diagnostic(code="PDDLICA-SIM-OPTION-001",message="trajectory_interval must be positive or nothing")])
    !isempty(plan.model_digest) && plan.model_digest!=model.digest && return SimulationResult(status=:ERROR,plan=plan,
        trajectories=trajectories,diagnostics=[Diagnostic(code="PDDLICA-SIM-PLAN-000",message="plan model digest mismatch")])
    (!isfinite(plan.horizon) || plan.horizon<0) && return SimulationResult(status=:INVALID,plan=plan,
        diagnostics=[Diagnostic(code="PDDLICA-SIM-PLAN-011",message="plan horizon must be finite and nonnegative")])
    ids=[o.id for o in plan.occurrences]
    length(ids)==length(unique(ids)) || return SimulationResult(status=:INVALID,plan=plan,
        diagnostics=[Diagnostic(code="PDDLICA-SIM-PLAN-012",message="plan occurrence IDs must be unique")])
    any(o.time<0 || o.time>plan.horizon for o in plan.occurrences) && return SimulationResult(status=:INVALID,plan=plan,
        trajectories=trajectories,diagnostics=[Diagnostic(code="PDDLICA-SIM-PLAN-007",message="plan occurrence lies outside its horizon")])
    state=RuntimeState(values=deepcopy(model.initial_values),presence=deepcopy(model.initial_presence))
    merge!(state.history,get(model.provenance,"initial_interface",Dict{String,Float64}()))
    iface,diag=_resolve_interface(model,state;symbolic_cache=cache,tolerance=options.absolute_tolerance)
    !isnothing(diag) && return SimulationResult(status=_diagnostic_status(diag),plan=plan,terminal_state=state,trajectories=trajectories,diagnostics=[diag])
    _record_trajectories!(trajectories,state,:initial)
    initial_state=_copy_state(state)
    diag=_event_closure!(model,state,steps,cache,options,trajectories)
    !isnothing(diag) && return SimulationResult(status=_diagnostic_status(diag),plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
    groups=Dict{Float64,Vector{PlanOccurrence}}()
    for o in plan.occurrences
        b=get(model.behaviors,o.schema_id,nothing)
        if !isnothing(b) && get(b,"_kind","")=="durative_action"
            duration=o.duration
            if isnothing(duration)
                if get(b["duration"],"kind","")!="number"
                    return SimulationResult(status=:UNSUPPORTED,plan=plan,
                        diagnostics=[Diagnostic(code="PDDLICA-SIM-DUR-008",
                            message="state-dependent or symbolic duration for '$(o.id)' must be supplied explicitly by the plan")])
                end
                dv=_eval_value(b["duration"],state,"",_params_for(b,o))
                duration=dv isa Number ? Float64(dv) : nothing
            end
            isnothing(duration) && return SimulationResult(status=:INVALID,plan=plan,diagnostics=[Diagnostic(
                code="PDDLICA-SIM-DUR-000",message="durative occurrence '$(o.id)' needs a numeric duration")])
            duration<0 && return SimulationResult(status=:INVALID,plan=plan,diagnostics=[Diagnostic(
                code="PDDLICA-SIM-DUR-005",message="durative occurrence '$(o.id)' has a negative duration")])
            push!(get!(groups,o.time,PlanOccurrence[]),PlanOccurrence(id=o.id,time=o.time,kind=:durative_start,
                schema_id=o.schema_id,name=o.name,arguments=o.arguments,duration=duration))
            push!(get!(groups,o.time+duration,PlanOccurrence[]),PlanOccurrence(id=o.id*"/end",time=o.time+duration,
                kind=:durative_end,schema_id=o.schema_id,name=o.name,arguments=o.arguments,duration=duration))
        else
            push!(get!(groups,o.time,PlanOccurrence[]),o)
        end
    end
    tils=Dict{Float64,Vector{Any}}()
    for x in get(model.provenance,"timed_initials",Any[])
        push!(get!(tils,_parse_time(x["time"]),Any[]),x)
    end
    alltimes=sort!(unique(vcat(collect(keys(groups)),collect(keys(tils)))))
    any(t>plan.horizon+options.event_tolerance for t in alltimes) && return SimulationResult(status=:INVALID,plan=plan,
        diagnostics=[Diagnostic(code="PDDLICA-SIM-TIME-001",message="a temporal endpoint lies beyond the plan horizon")])
    for time in alltimes
        # A guard may split integration before the planned time.
        while state.time < time-options.event_tolerance
            before=state.time; diag=_advance!(model,state,time,steps,cache,options,trajectories)
            !isnothing(diag) && return SimulationResult(status=_diagnostic_status(diag),plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
            diag=_event_closure!(model,state,steps,cache,options,trajectories)
            !isnothing(diag) && return SimulationResult(status=_diagnostic_status(diag),plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
            state.time <= before+options.event_tolerance && (state.time=min(time,before+10options.event_tolerance))
        end
        state.time=time
        if haskey(tils,time)
            diag=_apply_timed_initial!(model,state,tils[time]); !isnothing(diag) && return SimulationResult(status=:INVALID,
                plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
            iface,diag=_resolve_interface(model,state;symbolic_cache=cache,tolerance=options.absolute_tolerance)
            !isnothing(diag) && return SimulationResult(status=_diagnostic_status(diag),plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
            push!(steps,Dict{String,Any}("kind"=>"timed_initial","time"=>time,"state"=>state_dict(state)))
            diag=_event_closure!(model,state,steps,cache,options,trajectories)
            !isnothing(diag) && return SimulationResult(status=:INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
        end
        haskey(groups,time) || continue
        pre=state_dict(state); diag=_apply_happening!(model,state,groups[time])
        !isnothing(diag) && return SimulationResult(status=:INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
        state.microstep=0; iface,diag=_resolve_interface(model,state;symbolic_cache=cache,tolerance=options.absolute_tolerance)
        !isnothing(diag) && return SimulationResult(status=_diagnostic_status(diag),plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
        _record_trajectories!(trajectories,state,:action)
        push!(steps,Dict{String,Any}("kind"=>"planned_happening","time"=>time,
            "occurrence_ids"=>[o.id for o in groups[time]],"pre_state"=>pre,"post_state"=>state_dict(state)))
        diag=_event_closure!(model,state,steps,cache,options,trajectories)
        !isnothing(diag) && return SimulationResult(status=:INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
        diag=_open_invariants(model,state)
        !isnothing(diag) && return SimulationResult(status=:INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
    end
    while state.time < plan.horizon-options.event_tolerance
        before=state.time; diag=_advance!(model,state,plan.horizon,steps,cache,options,trajectories)
        !isnothing(diag) && return SimulationResult(status=_diagnostic_status(diag),plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
        diag=_event_closure!(model,state,steps,cache,options,trajectories)
        !isnothing(diag) && return SimulationResult(status=_diagnostic_status(diag),plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
        diag=_open_invariants(model,state)
        !isnothing(diag) && return SimulationResult(status=:INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
        state.time <= before+options.event_tolerance && (state.time=min(plan.horizon,before+10options.event_tolerance))
    end
    state.time=plan.horizon
    valid=_eval_formula(model.goal,state;model=model)
    valid || push!(diags,Diagnostic(code="PDDLICA-SIM-GOAL-001",message="terminal goal is not satisfied"))
    !isempty(state.open_duratives) && (valid=false; push!(diags,Diagnostic(code="PDDLICA-SIM-DUR-006",
        message="plan horizon reached with open durative occurrences")))
    observations=_observation_states(model,initial_state,steps,state,trajectories)
    preference_violations=Dict{String,Bool}()
    for (i,c) in enumerate(get(model.provenance,"constraints",Any[]))
        ok=_constraint_truth(c,observations,model)
        if get(c,"kind","")=="preference"
            preference_violations[string(get(c,"name","preference-$i"))]=!ok
        elseif !ok
            valid=false; push!(diags,Diagnostic(code="PDDLICA-SIM-CONSTRAINT-001",message="trajectory constraint $i is not satisfied"))
        end
    end
    for (i,p) in enumerate(get(model.provenance,"preferences",Any[]))
        preference_violations[string(get(p,"name","goal-preference-$i"))]=!_eval_formula(p["body"],state;model=model)
    end
    metric=get(model.provenance,"metric",nothing)
    metric_value=isnothing(metric) ? nothing : _metric_value(metric["expression"],state,preference_violations)
    SimulationResult(status=valid ? :VALID : :INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,
        diagnostics=diags,metadata=Dict{String,Any}("model_digest"=>model.digest,
            "symbolic_regimes"=>length(cache),"relative_tolerance"=>options.relative_tolerance,
            "absolute_tolerance"=>options.absolute_tolerance,"event_tolerance"=>options.event_tolerance,
            "preference_violations"=>preference_violations,
            "metric_value"=>metric_value,
            "metric_direction"=>isnothing(metric) ? nothing : get(metric,"optimization",nothing),
            "trajectory_interval"=>options.trajectory_interval,
            "trajectory_uses_solver_steps"=>options.save_everystep))
end

function simulate(domain_source::AbstractString,problem_source::AbstractString,plan;options=SimulationOptions())
    parsed=parse_model(domain_source,problem_source)
    isnothing(parsed.document) && return SimulationResult(status=:ERROR,diagnostics=parsed.diagnostics)
    elab=elaborate(parsed.document)
    isnothing(elab.model) && return SimulationResult(status=:ERROR,diagnostics=elab.diagnostics)
    pd=try
        plan isa PlanDocument ? plan : plan isa IO ? read_plan_json(plan) : read_plan_json(string(plan))
    catch err
        return SimulationResult(status=:ERROR,diagnostics=[Diagnostic(code="PDDLICA-SIM-PLAN-014",
            message=sprint(showerror,err))])
    end
    simulate(elab.model,pd;options=options)
end
