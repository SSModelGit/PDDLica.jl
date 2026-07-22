_copy_state(s::RuntimeState) = RuntimeState(time=s.time,microstep=s.microstep,
    values=deepcopy(s.values),interface=deepcopy(s.interface),presence=deepcopy(s.presence),
    boundary=deepcopy(s.boundary),history=deepcopy(s.history))

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
        localkey=_statekey(split(owner,'.'),name)
        isempty(args) && haskey(state.values,localkey) && return state.values[localkey]
    end
    if !isempty(vals)
        candidate=_statekey(split(string(vals[1]),'.'),name)
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
    elseif kind == "symbol"; return get(params,string(expr["name"]),string(expr["name"]))
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

function _eval_formula(f, state::RuntimeState, owner="", params=Dict{String,Any}(); interface=state.interface)
    kind=get(f,"kind","")
    if kind == "boolean"; return Bool(f["value"])
    elseif kind == "atom"
        v=_resolve_call(string(f["name"]),get(f,"arguments",Any[]),state,owner,params)
        return v === true
    elseif kind == "present"
        return get(state.presence,_component_path(f["component"],owner,params),false)
    elseif kind == "not"; return !_eval_formula(f["item"],state,owner,params;interface=interface)
    elseif kind == "and"; return all(_eval_formula(x,state,owner,params;interface=interface) for x in f["items"])
    elseif kind == "or"; return any(_eval_formula(x,state,owner,params;interface=interface) for x in f["items"])
    elseif kind == "imply"
        return !_eval_formula(f["antecedent"],state,owner,params;interface=interface) ||
            _eval_formula(f["consequent"],state,owner,params;interface=interface)
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
    get(state.presence,component,false)
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

function _interface_equation_formulas(f,owner,state)
    kind=get(f,"kind","")
    if kind == "and"
        return reduce(vcat,(_interface_equation_formulas(x,owner,state) for x in f["items"]);init=Tuple{String,Any}[])
    elseif kind == "imply"
        _has_port(f["antecedent"]) && return Tuple{String,Any}[]
        return _eval_formula(f["antecedent"],state,owner) ? _interface_equation_formulas(f["consequent"],owner,state) : Tuple{String,Any}[]
    elseif kind == "compare" && _has_port(f)
        return [(owner,f)]
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
            _eval_formula(req,state,owner) || return nothing, Diagnostic(code="PDDLICA-SIM-REQ-001",
                message="component requirement failed for '$owner'")
            continue
        end
        for (reqowner,f) in _interface_equation_formulas(req,owner,state)
            if get(f,"operator","") != "="; push!(inequalities,(reqowner,f)); continue end
            zeroiface=Dict(k=>0.0 for k in unknowns); c=_residual(f,state,reqowner,zeroiface)
            row=zeros(length(unknowns))
            for (k,j) in idx
                one=copy(zeroiface); one[k]=1.0; row[j]=_residual(f,state,reqowner,one)-c
                two=copy(zeroiface); two[k]=2.0
                abs((_residual(f,state,reqowner,two)-c)-2row[j]) <= 1e-7 || return nothing,
                    Diagnostic(code="PDDLICA-SIM-IFACE-004",message="nonlinear interface equation is unsupported")
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
        _eval_formula(f,state,owner;interface=iface) || return nothing,Diagnostic(code="PDDLICA-SIM-REQ-002",
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
    for b in values(model.behaviors)
        get(b,"_kind","")==kind || continue
        if haskey(b,"_owner_type")
            for (owner,inst) in model.components
                inst.component_type==b["_owner_type"] && _active(state,owner) && push!(out,(owner,b))
            end
        else
            push!(out,("",b))
        end
    end
    out
end

function _target_key(target,state,owner,params)
    name=string(get(target,"name","")); args=get(target,"arguments",Any[])
    if isempty(args) && !isempty(owner); return _statekey(split(owner,'.'),name) end
    if !isempty(args)
        firstval=_eval_value(args[1],state,owner,params)
        candidate=_statekey(split(string(firstval),'.'),name)
        haskey(state.values,candidate) && return candidate
    end
    vals=[_eval_value(a,state,owner,params) for a in args]
    isempty(vals) ? name : name*"("*join(string.(vals),",")*")"
end

function _effect_writes(effect,state,owner,params)
    kind=get(effect,"kind",""); writes=Dict{String,Any}()
    if kind=="and"
        for e in get(effect,"items",Any[])
            for (k,v) in _effect_writes(e,state,owner,params)
                haskey(writes,k) && writes[k]!=v && throw(ArgumentError("conflicting effects on '$k'"))
                writes[k]=v
            end
        end
    elseif kind in ("assign","increase","decrease","scale_up","scale_down")
        key=_target_key(effect["target"],state,owner,params); value=_eval_value(effect["value"],state,owner,params)
        old=get(state.values,key,0.0)
        writes[key]=kind=="assign" ? value : kind=="increase" ? old+value : kind=="decrease" ? old-value :
            kind=="scale_up" ? old*value : old/value
    elseif kind=="set_atom"
        a=effect["atom"]; target=Dict{String,Any}("kind"=>"call","name"=>a["name"],"arguments"=>get(a,"arguments",Any[]))
        writes[_target_key(target,state,owner,params)]=Bool(effect["value"])
    elseif kind in ("create","remove")
        component=_component_path(effect["component"],owner,params)
        writes["@presence:"*component]=(kind=="create")
    end
    writes
end

function _params_for(b,occ)
    out=Dict{String,Any}()
    decls=get(b,"parameters",Any[])
    for (i,p) in enumerate(decls)
        i<=length(occ.arguments) || continue
        a=occ.arguments[i]; out[string(p["name"])]=_argument_name(a)
    end
    out
end

function _apply_happening!(model,state,occs)
    allwrites=Dict{String,Any}()
    for occ in occs
        b=get(model.behaviors,occ.schema_id,nothing)
        isnothing(b) && return Diagnostic(code="PDDLICA-SIM-PLAN-001",message="unknown behavior '$(occ.schema_id)'")
        owner=occ.kind==:method ? join(occ.owner,'.') : ""
        get(b,"_kind","") in ("method","action") || return Diagnostic(code="PDDLICA-SIM-PLAN-002",message="behavior is not controllable")
        !isempty(owner) && !_active(state,owner) && return Diagnostic(code="PDDLICA-SIM-PLAN-003",message="component '$owner' is absent")
        params=_params_for(b,occ)
        _eval_formula(b["precondition"],state,owner,params) || return Diagnostic(code="PDDLICA-SIM-PLAN-004",
            message="precondition failed for '$(occ.name)' at $(state.time)")
        try
            for (k,v) in _effect_writes(b["effect"],state,owner,params)
                haskey(allwrites,k) && allwrites[k]!=v && return Diagnostic(code="PDDLICA-SIM-PLAN-005",message="conflicting simultaneous effects on '$k'")
                allwrites[k]=v
            end
        catch err
            return Diagnostic(code="PDDLICA-SIM-PLAN-005",message=sprint(showerror,err))
        end
    end
    for (k,v) in allwrites
        if startswith(k,"@presence:")
            component=k[11:end]; haskey(state.presence,component) || return Diagnostic(code="PDDLICA-SIM-PLAN-006",message="unknown lifecycle target '$component'")
            state.presence[component]=Bool(v)
            # Static descendants follow their ancestor.
            for child in keys(state.presence); startswith(child,component*".") && (state.presence[child]=Bool(v)) end
        else
            state.values[k]=v
        end
    end
    nothing
end

function _event_closure!(model,state,steps,cache,options,trajectories)
    seen=Set{String}()
    for layer in 1:options.max_event_layers
        enabled=Tuple{String,Dict{String,Any}}[]
        for (owner,b) in _ground_behaviors(model,state,"event")
            _eval_formula(b["precondition"],state,owner) && push!(enabled,(owner,b))
        end
        isempty(enabled) && return nothing
        fingerprint=canonical_json(Dict("values"=>state.values,"presence"=>state.presence,"interface"=>state.interface))
        fingerprint in seen && return Diagnostic(code="PDDLICA-SIM-EVENT-002",message="urgent event closure entered a repeated state")
        push!(seen,fingerprint); writes=Dict{String,Any}()
        for (owner,b) in enabled
            try
                for (k,v) in _effect_writes(b["effect"],state,owner,Dict{String,Any}())
                    haskey(writes,k)&&writes[k]!=v && return Diagnostic(code="PDDLICA-SIM-EVENT-001",message="conflicting mandatory event effects on '$k'")
                    writes[k]=v
                end
            catch err; return Diagnostic(code="PDDLICA-SIM-EVENT-001",message=sprint(showerror,err)) end
        end
        for (k,v) in writes
            startswith(k,"@presence:") ? (state.presence[k[11:end]]=Bool(v)) : (state.values[k]=v)
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
            string(v["value_type"])=="number" && !Bool(get(v,"static",false)) && push!(keys,_statekey(inst.path,string(v["name"])))
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
        _eval_formula(b["precondition"],trial,owner) || continue
        for e in get(b,"effects",Any[])
            key=_target_key(e["target"],trial,owner,Dict{String,Any}()); i=findfirst(==(key),keys); isnothing(i)&&continue
            rate=_eval_value(e["rate"],trial,owner); du[i]+=(e["operator"]=="decrease" ? -1 : 1)*Float64(rate)
        end
    end
end

function _guard_margin(f,state,owner)
    kind=get(f,"kind","")
    if kind=="compare"
        a=_eval_value(f["left"],state,owner); b=_eval_value(f["right"],state,owner)
        (a isa Number && b isa Number) || return nothing
        op=f["operator"]
        return op in (">",">=") ? a-b : op in ("<","<=") ? b-a : -abs(a-b)
    elseif kind=="and"
        numeric=Float64[]
        for item in f["items"]
            margin=_guard_margin(item,state,owner)
            if margin isa Number
                push!(numeric,Float64(margin))
            elseif !_eval_formula(item,state,owner)
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
    for (owner,b) in guards
        condition=(u,t,integrator)->begin
            trial=_copy_state(state); trial.time=t
            for (i,k) in enumerate(keys); trial.values[k]=u[i] end
            iface,diag=_resolve_interface(model,trial;update_history=false,tolerance=options.absolute_tolerance)
            isnothing(diag) || return 1.0
            trial.interface=iface; m=_guard_margin(b["precondition"],trial,owner)
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

function simulate(model::ElaboratedModel,plan::PlanDocument;options=SimulationOptions())
    diags=Diagnostic[]; steps=Dict{String,Any}[]; cache=Dict{Any,Any}()
    trajectories=Dict{String,VariableTrajectory}()
    !isnothing(options.trajectory_interval) && options.trajectory_interval<=0 && return SimulationResult(
        status=:ERROR,plan=plan,trajectories=trajectories,
        diagnostics=[Diagnostic(code="PDDLICA-SIM-OPTION-001",message="trajectory_interval must be positive or nothing")])
    !isempty(plan.model_digest) && plan.model_digest!=model.digest && return SimulationResult(status=:ERROR,plan=plan,
        trajectories=trajectories,diagnostics=[Diagnostic(code="PDDLICA-SIM-PLAN-000",message="plan model digest mismatch")])
    any(o.time<0 || o.time>plan.horizon for o in plan.occurrences) && return SimulationResult(status=:INVALID,plan=plan,
        trajectories=trajectories,diagnostics=[Diagnostic(code="PDDLICA-SIM-PLAN-007",message="plan occurrence lies outside its horizon")])
    state=RuntimeState(values=deepcopy(model.initial_values),presence=deepcopy(model.initial_presence))
    merge!(state.history,get(model.provenance,"initial_interface",Dict{String,Float64}()))
    iface,diag=_resolve_interface(model,state;symbolic_cache=cache,tolerance=options.absolute_tolerance)
    !isnothing(diag) && return SimulationResult(status=:INVALID,plan=plan,terminal_state=state,trajectories=trajectories,diagnostics=[diag])
    _record_trajectories!(trajectories,state,:initial)
    diag=_event_closure!(model,state,steps,cache,options,trajectories)
    !isnothing(diag) && return SimulationResult(status=:INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
    groups=Dict{Float64,Vector{PlanOccurrence}}()
    for o in plan.occurrences; push!(get!(groups,o.time,PlanOccurrence[]),o) end
    for time in sort!(collect(keys(groups)))
        # A guard may split integration before the planned time.
        while state.time < time-options.event_tolerance
            before=state.time; diag=_advance!(model,state,time,steps,cache,options,trajectories)
            !isnothing(diag) && return SimulationResult(status=:ERROR,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
            diag=_event_closure!(model,state,steps,cache,options,trajectories)
            !isnothing(diag) && return SimulationResult(status=:INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
            state.time <= before+options.event_tolerance && (state.time=min(time,before+10options.event_tolerance))
        end
        state.time=time; pre=state_dict(state); diag=_apply_happening!(model,state,groups[time])
        !isnothing(diag) && return SimulationResult(status=:INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
        state.microstep=0; iface,diag=_resolve_interface(model,state;symbolic_cache=cache,tolerance=options.absolute_tolerance)
        !isnothing(diag) && return SimulationResult(status=:INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
        _record_trajectories!(trajectories,state,:action)
        push!(steps,Dict{String,Any}("kind"=>"planned_happening","time"=>time,
            "occurrence_ids"=>[o.id for o in groups[time]],"pre_state"=>pre,"post_state"=>state_dict(state)))
        diag=_event_closure!(model,state,steps,cache,options,trajectories)
        !isnothing(diag) && return SimulationResult(status=:INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
    end
    while state.time < plan.horizon-options.event_tolerance
        before=state.time; diag=_advance!(model,state,plan.horizon,steps,cache,options,trajectories)
        !isnothing(diag) && return SimulationResult(status=:ERROR,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
        diag=_event_closure!(model,state,steps,cache,options,trajectories)
        !isnothing(diag) && return SimulationResult(status=:INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,diagnostics=[diag])
        state.time <= before+options.event_tolerance && (state.time=min(plan.horizon,before+10options.event_tolerance))
    end
    state.time=plan.horizon
    valid=_eval_formula(model.goal,state)
    valid || push!(diags,Diagnostic(code="PDDLICA-SIM-GOAL-001",message="terminal goal is not satisfied"))
    SimulationResult(status=valid ? :VALID : :INVALID,plan=plan,terminal_state=state,steps=steps,trajectories=trajectories,
        diagnostics=diags,metadata=Dict{String,Any}("model_digest"=>model.digest,
            "symbolic_regimes"=>length(cache),"relative_tolerance"=>options.relative_tolerance,
            "absolute_tolerance"=>options.absolute_tolerance,"event_tolerance"=>options.event_tolerance,
            "trajectory_interval"=>options.trajectory_interval,
            "trajectory_uses_solver_steps"=>options.save_everystep))
end

function simulate(domain_source::AbstractString,problem_source::AbstractString,plan;options=SimulationOptions())
    parsed=parse_model(domain_source,problem_source)
    isnothing(parsed.document) && return SimulationResult(status=:ERROR,diagnostics=parsed.diagnostics)
    elab=elaborate(parsed.document)
    isnothing(elab.model) && return SimulationResult(status=:ERROR,diagnostics=elab.diagnostics)
    pd=plan isa PlanDocument ? plan : plan isa IO ? read_plan_json(plan) : read_plan_json(string(plan))
    simulate(elab.model,pd;options=options)
end
