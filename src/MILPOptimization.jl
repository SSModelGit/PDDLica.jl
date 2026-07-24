struct _MILPBuildError <: Exception
    message::String
end
Base.showerror(io::IO,e::_MILPBuildError)=print(io,e.message)
_milp_unsupported(message)=throw(_MILPBuildError(message))

struct _MILPEffectValue
    expression::Any
    owner::String
    parameters::Dict{String,Any}
end

mutable struct _MILPContext
    source::ElaboratedModel
    options::HybridMILPOptions
    jump::JuMP.Model
    controls::Vector{_GroundControl}
    operations::Vector{Vector{Pair{String,Any}}}
    initial::RuntimeState
    numeric::Vector{String}
    statics::Set{String}
    booleans::Vector{String}
    enum_domains::Dict{String,Vector{String}}
    fields::Vector{String}
    action::Dict{Tuple{Int,Int},Any}
    xpre::Dict{Tuple{String,Int},Any}
    xpost::Dict{Tuple{String,Int},Any}
    bpre::Dict{Tuple{String,Int},Any}
    bpost::Dict{Tuple{String,Int},Any}
    zpre::Dict{Tuple{String,String,Int},Any}
    zpost::Dict{Tuple{String,String,Int},Any}
    ypre::Dict{Tuple{String,Int},Any}
    ypost::Dict{Tuple{String,Int},Any}
end

function capabilities(backend::HybridMILPBackend)
    CapabilityReport(supported=true,backend=backend.name,
        profile="time-indexed-linear-hybrid-milp-0.1",
        restrictions=[
            "fixed time grid and finite grounded controllable schemas",
            "affine numeric expressions and process rates",
            "discrete Boolean and finite symbolic state",
            "static component presence and connection topology",
            "linear acausal connector equations",
            "autonomous events and conditional effects are not yet transcribed",
        ],
        details=Dict{String,Any}("formulation"=>"time-indexed hybrid MILP",
            "modeling_layer"=>"JuMP/MathOptInterface","default_solver"=>"HiGHS",
            "objective"=>"source metric when affine, otherwise minimum selected actions"))
end

function _milp_option_diagnostics(options::HybridMILPOptions)
    out=Diagnostic[]
    options.steps>=1 || push!(out,Diagnostic(code="PDDLICA-MILP-001",
        message="steps must be positive"))
    isfinite(options.makespan) && options.makespan>0 || push!(out,
        Diagnostic(code="PDDLICA-MILP-002",message="makespan must be positive and finite"))
    options.max_simultaneous_actions>=1 || push!(out,Diagnostic(code="PDDLICA-MILP-003",
        message="max_simultaneous_actions must be positive"))
    isfinite(options.numeric_bound) && options.numeric_bound>0 || push!(out,
        Diagnostic(code="PDDLICA-MILP-004",message="numeric_bound must be positive and finite"))
    options.strict_epsilon>0 || push!(out,Diagnostic(code="PDDLICA-MILP-005",
        message="strict_epsilon must be positive"))
    options.objective in (:source_metric_or_actions,:min_actions) || push!(out,
        Diagnostic(code="PDDLICA-MILP-006",message="unknown MILP objective policy"))
    out
end

function _contains_kind(x,kinds)
    x isa AbstractVector && return any(v->_contains_kind(v,kinds),x)
    x isa AbstractDict || return false
    string(get(x,"kind","")) in kinds && return true
    any(v->_contains_kind(v,kinds),values(x))
end

function _contains_operator(x,operators)
    x isa AbstractVector && return any(v->_contains_operator(v,operators),x)
    x isa AbstractDict || return false
    string(get(x,"operator","")) in operators && return true
    any(v->_contains_operator(v,operators),values(x))
end

function _contains_call(x,names)
    x isa AbstractVector && return any(v->_contains_call(v,names),x)
    x isa AbstractDict || return false
    get(x,"kind","")=="call" && string(get(x,"name","")) in names && return true
    any(v->_contains_call(v,names),values(x))
end

function _milp_surface_diagnostics(model)
    out=Diagnostic[]; domain=model.document.domain; problem=model.document.problem
    !isempty(get(problem,"timed_initials",Any[])) && push!(out,Diagnostic(
        code="PDDLICA-MILP-023",
        message="timed initial literals are not yet transcribed"))
    !isempty(get(problem,"constraints",Any[])) && push!(out,Diagnostic(
        code="PDDLICA-MILP-024",
        message="PDDL3 trajectory constraints are not yet transcribed"))
    !isempty(get(problem,"preferences",Any[])) && push!(out,Diagnostic(
        code="PDDLICA-MILP-025",
        message="PDDL3 preferences are not yet transcribed"))
    !isempty(get(domain,"derived_predicates",Any[])) && push!(out,Diagnostic(
        code="PDDLICA-MILP-026",
        message="derived predicates are not yet expanded by the MILP backend"))
    _contains_kind(get(problem,"goal",Dict{String,Any}()),Set(["preference"])) &&
        push!(out,Diagnostic(code="PDDLICA-MILP-025",
            message="goal preferences are not yet transcribed"))
    formulas=Any[get(problem,"goal",Dict{String,Any}())]
    append!(formulas,[b["precondition"] for b in values(model.behaviors)
        if haskey(b,"precondition")])
    append!(formulas,[r["formula"] for ct in values(model.component_types)
        for r in get(ct,"requirements",Any[])])
    _contains_kind(formulas,Set(["or","forall","exists","preference","always","sometime",
        "at_most_once","within","hold_during","hold_after","sometime_before",
        "sometime_after","always_within"])) && push!(out,Diagnostic(
            code="PDDLICA-MILP-027",
            message="quantified, preference, or trajectory formulas are outside the MILP profile"))
    _contains_operator(formulas,Set(["!="])) && push!(out,Diagnostic(
        code="PDDLICA-MILP-031",
        message="numeric or symbolic disequality is not yet transcribed"))
    effects=Any[]
    for b in values(model.behaviors)
        haskey(b,"effect") && push!(effects,b["effect"])
    end
    _contains_kind(effects,Set(["when","forall","scale_up","scale_down",
        "create","remove"])) &&
        push!(out,Diagnostic(code="PDDLICA-MILP-028",
            message="conditional, quantified, scaling, and lifecycle effects are not yet transcribed"))
    metric=get(problem,"metric",nothing)
    !isnothing(metric) && _contains_call(metric,Set(["is-violated"])) &&
        push!(out,Diagnostic(code="PDDLICA-MILP-029",
            message="preference-dependent metrics are not yet transcribed"))
    seen=Set{Tuple{String,String}}()
    filter!(out) do diagnostic
        key=(diagnostic.code,diagnostic.message)
        key in seen && return false
        push!(seen,key)
        true
    end
    out
end

function analyze(backend::HybridMILPBackend,model::ElaboratedModel,
                 options::HybridMILPOptions=HybridMILPOptions())
    diags=_milp_option_diagnostics(options)
    append!(diags,_milp_surface_diagnostics(model))
    !isempty(get(model.document.domain,"events",Any[])) && push!(diags,
        Diagnostic(code="PDDLICA-MILP-020",message="global autonomous events are not yet transcribed"))
    any(!isempty(get(ct,"events",Any[])) for ct in values(model.component_types)) && push!(diags,
        Diagnostic(code="PDDLICA-MILP-020",message="component autonomous events are not yet transcribed"))
    any(!present for present in values(model.initial_presence)) && push!(diags,
        Diagnostic(code="PDDLICA-MILP-021",message="initially absent components require lifecycle transcription"))
    !isempty(get(model.document.domain,"durative_actions",Any[])) && push!(diags,
        Diagnostic(code="PDDLICA-MILP-022",message="durative-action start/end linking is not yet in the MILP profile"))
    base=capabilities(backend)
    CapabilityReport(supported=isempty(diags),backend=base.backend,profile=base.profile,
        restrictions=base.restrictions,diagnostics=diags,
        details=merge(base.details,Dict{String,Any}("steps"=>options.steps,
            "makespan"=>options.makespan,"step_duration"=>options.makespan/options.steps)))
end

function _collect_symbols!(out,x)
    x isa AbstractVector && (foreach(v->_collect_symbols!(out,v),x); return)
    x isa AbstractDict || return
    get(x,"kind","")=="symbol" && push!(out,string(x["name"]))
    foreach(v->_collect_symbols!(out,v),values(x))
end

function _static_keys(model)
    out=Set{String}()
    for (owner,instance) in model.components
        ct=model.component_types[instance.component_type]
        for variable in get(ct,"variables",Any[])
            Bool(get(variable,"static",false)) || continue
            base="$owner.$(variable["name"])"
            for key in keys(model.initial_values)
                (key==base || startswith(key,base*"(")) && push!(out,key)
            end
        end
    end
    out
end

function _ground_predicate_keys(model)
    keys=String[]
    for predicate in get(model.document.domain,"predicates",Any[])
        for args in _argument_product(model,get(predicate,"parameters",Any[]))
            values=String[string(get(a,"name","")) for a in args]
            push!(keys,isempty(values) ? string(predicate["name"]) :
                string(predicate["name"])*"("*join(values,",")*")")
        end
    end
    keys
end

function _control_occurrence(control)
    PlanOccurrence(kind=control.kind,schema_id=control.schema_id,name=control.name,
        owner=control.owner,arguments=control.arguments,duration=control.duration)
end

function _effect_supported(effect)
    kind=get(effect,"kind","")
    kind in ("when","forall") && return false
    kind=="and" && return all(_effect_supported,get(effect,"items",Any[]))
    true
end

function _control_operations(model,controls,initial)
    out=Vector{Vector{Pair{String,Any}}}()
    for control in controls
        behavior=model.behaviors[control.schema_id]
        _effect_supported(behavior["effect"]) || _milp_unsupported(
            "conditional and quantified controllable effects are not in the MILP profile")
        occurrence=_control_occurrence(control)
        owner=control.kind==:method ? join(control.owner,'.') : ""
        params=_params_for(behavior,occurrence)
        operations=_milp_effect_operations(behavior["effect"],initial,owner,params)
        any(startswith(first(op),"@presence:") for op in operations) &&
            _milp_unsupported("component lifecycle effects are not yet transcribed by the MILP backend")
        push!(out,operations)
    end
    out
end

function _milp_effect_operations(effect,state,owner,params)
    kind=get(effect,"kind",""); operations=Pair{String,Any}[]
    if kind=="and"
        for item in get(effect,"items",Any[])
            append!(operations,_milp_effect_operations(item,state,owner,params))
        end
    elseif kind in ("assign","increase","decrease")
        key=_target_key(effect["target"],state,owner,params)
        current=get(state.values,key,nothing)
        value=current isa Number && !(current isa Bool) ?
            _MILPEffectValue(effect["value"],owner,deepcopy(params)) :
            _eval_value(effect["value"],state,owner,params)
        push!(operations,key=>(kind,value))
    elseif kind in ("scale_up","scale_down")
        _milp_unsupported("scale-up and scale-down effects are not yet transcribed")
    elseif kind=="set_atom"
        atom=effect["atom"]
        target=Dict{String,Any}("kind"=>"call","name"=>atom["name"],
            "arguments"=>get(atom,"arguments",Any[]))
        push!(operations,_target_key(target,state,owner,params)=>
            ("assign",Bool(effect["value"])))
    elseif kind in ("create","remove")
        component=_component_path(effect["component"],owner,params)
        push!(operations,"@presence:"*component=>("assign",kind=="create"))
    else
        _milp_unsupported("effect kind '$kind' is not in the MILP transcription profile")
    end
    operations
end

function _milp_controls(model,options)
    search_options=OptimizationOptions(max_macrosteps=options.steps,
        max_makespan=options.makespan,
        max_simultaneous_actions=options.max_simultaneous_actions)
    controls=_ground_controls(model,search_options)
    any(c.kind==:durative_action for c in controls) &&
        _milp_unsupported("durative actions are not yet transcribed by the MILP backend")
    controls
end

function _bounds(options,key)
    get(options.numeric_bounds,key,(-options.numeric_bound,options.numeric_bound))
end

function _make_context(model,options)
    initial=_initial_runtime(model)
    controls=_milp_controls(model,options)
    operations=_control_operations(model,controls,initial)
    statics=_static_keys(model)
    numeric=sort!([key for (key,value) in model.initial_values
        if value isa Number && !(value isa Bool) && !(key in statics)])
    booleans=Set(_ground_predicate_keys(model))
    union!(booleans,[key for (key,value) in model.initial_values if value isa Bool])
    symbols=Set{String}(); _collect_symbols!(symbols,model.document.domain)
    _collect_symbols!(symbols,model.document.problem)
    enum_domains=Dict{String,Vector{String}}()
    for (key,value) in model.initial_values
        value isa AbstractString || continue
        enum_domains[key]=sort!(unique(vcat([string(value)],collect(symbols))))
    end
    for ops in operations, (key,(kind,value)) in ops
        if value isa Bool
            push!(booleans,key)
        elseif value isa AbstractString
            domain=get!(enum_domains,key,String[])
            push!(domain,string(value)); sort!(unique!(domain))
        elseif value isa Number
            key in numeric || key in statics || push!(numeric,key)
        end
    end
    meta=_active_fields(model,initial)
    fields=sort!(collect(keys(meta)))
    jm=JuMP.Model(HiGHS.Optimizer)
    options.silent && JuMP.set_silent(jm)
    !isnothing(options.time_limit_seconds) &&
        JuMP.set_time_limit_sec(jm,options.time_limit_seconds)
    !isnothing(options.mip_relative_gap) &&
        JuMP.set_optimizer_attribute(jm,"mip_rel_gap",options.mip_relative_gap)
    _MILPContext(model,options,jm,controls,operations,initial,sort!(unique(numeric)),
        statics,sort!(collect(booleans)),enum_domains,fields,
        Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict())
end

function _new_variables!(ctx)
    N=ctx.options.steps; M=ctx.options.numeric_bound
    for i in eachindex(ctx.controls), k in 1:N
        ctx.action[(i,k)]=@variable(ctx.jump,binary=true,
            base_name="take[$i,$k]")
    end
    for key in ctx.numeric
        lo,hi=_bounds(ctx.options,key)
        for k in 1:N+1
            ctx.xpre[(key,k)]=@variable(ctx.jump,lower_bound=lo,upper_bound=hi,
                base_name="x[$key,$k]")
        end
        for k in 1:N
            ctx.xpost[(key,k)]=@variable(ctx.jump,lower_bound=lo,upper_bound=hi,
                base_name="xpost[$key,$k]")
        end
    end
    for key in ctx.booleans
        for k in 1:N+1
            ctx.bpre[(key,k)]=@variable(ctx.jump,binary=true,base_name="b[$key,$k]")
        end
        for k in 1:N
            ctx.bpost[(key,k)]=@variable(ctx.jump,binary=true,base_name="bpost[$key,$k]")
        end
    end
    for (key,domain) in ctx.enum_domains, value in domain
        for k in 1:N+1
            ctx.zpre[(key,value,k)]=@variable(ctx.jump,binary=true,
                base_name="z[$key,$value,$k]")
        end
        for k in 1:N
            ctx.zpost[(key,value,k)]=@variable(ctx.jump,binary=true,
                base_name="zpost[$key,$value,$k]")
        end
    end
    for key in ctx.fields
        for k in 1:N+1
            ctx.ypre[(key,k)]=@variable(ctx.jump,lower_bound=-M,upper_bound=M,
                base_name="y[$key,$k]")
        end
        for k in 1:N
            ctx.ypost[(key,k)]=@variable(ctx.jump,lower_bound=-M,upper_bound=M,
                base_name="ypost[$key,$k]")
        end
    end
end

function _state_key(ctx,expr,owner,params)
    _target_key(expr,ctx.initial,owner,params)
end

function _field_key(expr,owner)
    port=expr["port"]; instance=port["instance"]
    base=get(instance,"anchor","self")=="self" ?
        (isempty(owner) ? String[] : split(owner,'.')) : String[]
    path=vcat(base,String[string(x) for x in get(instance,"segments",Any[])])
    _portkey(path,string(port["port"]))*"."*string(expr["field"])
end

function _lin(ctx,expr,phase,k,owner="",params=Dict{String,Any}())
    expr isa Number && return Float64(expr)
    kind=get(expr,"kind","")
    kind=="number" && return Float64(_parse_time(expr["value"]))
    if kind=="call"
        key=_state_key(ctx,expr,owner,params)
        key in ctx.statics && return Float64(ctx.source.initial_values[key])
        key in ctx.numeric || _milp_unsupported("'$key' is not a numeric MILP fluent")
        return phase==:pre ? ctx.xpre[(key,k)] : ctx.xpost[(key,k)]
    elseif kind=="port_field"
        key=_field_key(expr,owner)
        key in ctx.fields || _milp_unsupported("inactive or unknown connector field '$key'")
        return phase==:pre ? ctx.ypre[(key,k)] : ctx.ypost[(key,k)]
    elseif kind=="arithmetic"
        args=[_lin(ctx,x,phase,k,owner,params) for x in expr["arguments"]]
        op=string(expr["operator"])
        op=="+" && return sum(args)
        op=="-" && return length(args)==1 ? -args[1] : args[1]-args[2]
        if op=="*"
            result=1.0
            for value in args
                if value isa Number
                    result*=value
                elseif result isa Number
                    result=value*result
                else
                    _milp_unsupported("non-affine multiplication in MILP expression")
                end
            end
            return result
        elseif op=="/"
            args[2] isa Number || _milp_unsupported("division by a MILP variable is non-affine")
            return args[1]/args[2]
        end
    end
    _milp_unsupported("unsupported affine value node '$kind'")
end

function _enum_condition(ctx,f,phase,k,owner,params)
    get(f,"kind","")=="compare" || return nothing
    op=string(f["operator"]); op in ("=","!=") || return nothing
    left,right=f["left"],f["right"]
    call,symbol=get(left,"kind","")=="call" && get(right,"kind","")=="symbol" ?
        (left,right) : get(right,"kind","")=="call" && get(left,"kind","")=="symbol" ?
        (right,left) : return nothing
    key=_state_key(ctx,call,owner,params); value=string(symbol["name"])
    haskey(ctx.enum_domains,key) || return nothing
    value in ctx.enum_domains[key] || return op=="=" ? 0.0 : 1.0
    variable=phase==:pre ? ctx.zpre[(key,value,k)] : ctx.zpost[(key,value,k)]
    op=="=" ? variable : 1-variable
end

function _truth(ctx,f,phase,k,owner="",params=Dict{String,Any}())
    kind=get(f,"kind","")
    kind=="boolean" && return Bool(f["value"]) ? 1.0 : 0.0
    enum=_enum_condition(ctx,f,phase,k,owner,params)
    !isnothing(enum) && return enum
    if kind=="atom"
        key=_state_key(ctx,Dict{String,Any}("name"=>f["name"],
            "arguments"=>get(f,"arguments",Any[])),owner,params)
        key in ctx.booleans || _milp_unsupported("unknown Boolean MILP fluent '$key'")
        return phase==:pre ? ctx.bpre[(key,k)] : ctx.bpost[(key,k)]
    elseif kind=="not"
        return 1-_truth(ctx,f["item"],phase,k,owner,params)
    elseif kind in ("and","or")
        items=[_truth(ctx,x,phase,k,owner,params) for x in f["items"]]
        isempty(items) && return kind=="and" ? 1.0 : 0.0
        result=@variable(ctx.jump,binary=true,base_name="logic")
        if kind=="and"
            foreach(x->@constraint(ctx.jump,result<=x),items)
            @constraint(ctx.jump,result>=sum(items)-(length(items)-1))
        else
            foreach(x->@constraint(ctx.jump,result>=x),items)
            @constraint(ctx.jump,result<=sum(items))
        end
        return result
    end
    nothing
end

function _compare_constraint!(ctx,f,phase,k,owner,params;gate=nothing)
    enum=_enum_condition(ctx,f,phase,k,owner,params)
    if !isnothing(enum)
        isnothing(gate) ? @constraint(ctx.jump,enum==1) : @constraint(ctx.jump,gate<=enum)
        return
    end
    diff=_lin(ctx,f["left"],phase,k,owner,params)-
        _lin(ctx,f["right"],phase,k,owner,params)
    op=string(f["operator"]); M=ctx.options.numeric_bound; eps=ctx.options.strict_epsilon
    slack=isnothing(gate) ? 0.0 : M*(1-gate)
    op=="=" && (@constraint(ctx.jump,diff<=slack); @constraint(ctx.jump,diff>=-slack); return)
    op=="!=" && _milp_unsupported("numeric disequality is disjunctive and not in the MILP profile")
    op==">=" && (@constraint(ctx.jump,diff>=-slack); return)
    op==">" && (@constraint(ctx.jump,diff>=eps-slack); return)
    op=="<=" && (@constraint(ctx.jump,diff<=slack); return)
    op=="<" && (@constraint(ctx.jump,diff<=-eps+slack); return)
    _milp_unsupported("unknown comparison operator '$op'")
end

function _formula_constraint!(ctx,f,phase,k,owner="",params=Dict{String,Any}();gate=nothing)
    kind=get(f,"kind","")
    if kind=="boolean"
        !Bool(f["value"]) && (isnothing(gate) ? _milp_unsupported("hard false formula") :
            @constraint(ctx.jump,gate==0))
    elseif kind=="and"
        foreach(x->_formula_constraint!(ctx,x,phase,k,owner,params;gate=gate),f["items"])
    elseif kind=="compare"
        _compare_constraint!(ctx,f,phase,k,owner,params;gate=gate)
    elseif kind in ("atom","not")
        truth=_truth(ctx,f,phase,k,owner,params)
        isnothing(gate) ? @constraint(ctx.jump,truth==1) : @constraint(ctx.jump,gate<=truth)
    elseif kind=="imply"
        antecedent=_truth(ctx,f["antecedent"],phase,k,owner,params)
        isnothing(antecedent) && _milp_unsupported("MILP implication antecedent must be discrete")
        combined=isnothing(gate) ? antecedent : begin
            g=@variable(ctx.jump,binary=true,base_name="implication_gate")
            @constraint(ctx.jump,g<=gate); @constraint(ctx.jump,g<=antecedent)
            @constraint(ctx.jump,g>=gate+antecedent-1); g
        end
        _formula_constraint!(ctx,f["consequent"],phase,k,owner,params;gate=combined)
    elseif kind=="present"
        present=get(ctx.initial.presence,_component_path(f["component"],owner,params),false)
        !present && (isnothing(gate) ? _milp_unsupported("hard absent-component condition") :
            @constraint(ctx.jump,gate==0))
    else
        _milp_unsupported("formula kind '$kind' is not in the MILP transcription profile")
    end
end

function _initial_constraints!(ctx)
    for key in ctx.numeric
        haskey(ctx.source.initial_values,key) || _milp_unsupported("numeric fluent '$key' lacks an initial value")
        @constraint(ctx.jump,ctx.xpre[(key,1)]==Float64(ctx.source.initial_values[key]))
    end
    for key in ctx.booleans
        @constraint(ctx.jump,ctx.bpre[(key,1)]==(get(ctx.source.initial_values,key,false) ? 1 : 0))
    end
    for (key,domain) in ctx.enum_domains
        initial=string(ctx.source.initial_values[key])
        @constraint(ctx.jump,sum(ctx.zpre[(key,value,1)] for value in domain)==1)
        for value in domain
            @constraint(ctx.jump,ctx.zpre[(key,value,1)]==(value==initial ? 1 : 0))
        end
    end
end

_effect_affine(ctx,value::_MILPEffectValue,k)=
    _lin(ctx,value.expression,:pre,k,value.owner,value.parameters)
_effect_affine(ctx,value,k)=value

function _gated_affine!(ctx,expression,gate,k)
    expression isa Number && return Float64(expression)*gate
    M=ctx.options.numeric_bound
    product=@variable(ctx.jump,lower_bound=-M,upper_bound=M,
        base_name="effect_product[$k]")
    @constraint(ctx.jump,product<=M*gate)
    @constraint(ctx.jump,product>=-M*gate)
    @constraint(ctx.jump,product-expression<=M*(1-gate))
    @constraint(ctx.jump,product-expression>=-M*(1-gate))
    product
end

function _control_reads(ctx,i)
    control=ctx.controls[i]
    behavior=ctx.source.behaviors[control.schema_id]
    occurrence=_control_occurrence(control)
    owner=control.kind==:method ? join(control.owner,'.') : ""
    params=_params_for(behavior,occurrence)
    reads=_formula_reads(behavior["precondition"],ctx.initial,owner,params)
    for (_,operation) in ctx.operations[i]
        value=operation[2]
        value isa _MILPEffectValue &&
            union!(reads,_value_reads(value.expression,ctx.initial,
                value.owner,value.parameters))
    end
    reads
end

function _action_and_discrete_constraints!(ctx)
    N=ctx.options.steps
    reads=[_control_reads(ctx,i) for i in eachindex(ctx.controls)]
    writes=[Set(first.(ctx.operations[i])) for i in eachindex(ctx.controls)]
    for k in 1:N
        @constraint(ctx.jump,sum(ctx.action[(i,k)] for i in eachindex(ctx.controls))<=
            ctx.options.max_simultaneous_actions)
        for i in eachindex(ctx.controls), j in i+1:length(ctx.controls)
            (!isempty(intersect(writes[i],reads[j])) ||
             !isempty(intersect(writes[j],reads[i]))) &&
                @constraint(ctx.jump,ctx.action[(i,k)]+ctx.action[(j,k)]<=1)
        end
        for (i,control) in enumerate(ctx.controls)
            behavior=ctx.source.behaviors[control.schema_id]
            occurrence=_control_occurrence(control)
            owner=control.kind==:method ? join(control.owner,'.') : ""
            params=_params_for(behavior,occurrence)
            _formula_constraint!(ctx,behavior["precondition"],:pre,k,owner,params;
                gate=ctx.action[(i,k)])
        end

        for key in ctx.numeric
            assigns=[(i,op[2][2]) for (i,ops) in enumerate(ctx.operations) for op in ops
                if op[1]==key && first(op[2])=="assign"]
            updates=[(i,first(op[2])=="increase" ? op[2][2] : op[2][2], 
                first(op[2])=="increase" ? 1.0 : -1.0)
                for (i,ops) in enumerate(ctx.operations) for op in ops
                if op[1]==key && first(op[2]) in ("increase","decrease")]
            for (ia,_) in assigns, (iu,_,_) in updates
                @constraint(ctx.jump,ctx.action[(ia,k)]+ctx.action[(iu,k)]<=1)
            end
            for p in 1:length(assigns), q in p+1:length(assigns)
                @constraint(ctx.jump,
                    ctx.action[(assigns[p][1],k)]+ctx.action[(assigns[q][1],k)]<=1)
            end
            wa=sum(ctx.action[(i,k)] for (i,_) in assigns;init=0.0)
            update=sum(sign*_gated_affine!(ctx,_effect_affine(ctx,value,k),
                ctx.action[(i,k)],k) for (i,value,sign) in updates;init=0.0)
            M=ctx.options.numeric_bound
            @constraint(ctx.jump,ctx.xpost[(key,k)]-(ctx.xpre[(key,k)]+update)<=M*wa)
            @constraint(ctx.jump,ctx.xpost[(key,k)]-(ctx.xpre[(key,k)]+update)>=-M*wa)
            for (i,value) in assigns
                affine=_effect_affine(ctx,value,k)
                @constraint(ctx.jump,ctx.xpost[(key,k)]-affine<=M*(1-ctx.action[(i,k)]))
                @constraint(ctx.jump,ctx.xpost[(key,k)]-affine>=-M*(1-ctx.action[(i,k)]))
            end
        end

        for key in ctx.booleans
            writers=[(i,Bool(last(op[2]))) for (i,ops) in enumerate(ctx.operations) for op in ops
                if op[1]==key && first(op[2])=="assign" && last(op[2]) isa Bool]
            w=sum(ctx.action[(i,k)] for (i,_) in writers;init=0.0)
            @constraint(ctx.jump,ctx.bpost[(key,k)]-ctx.bpre[(key,k)]<=w)
            @constraint(ctx.jump,ctx.bpre[(key,k)]-ctx.bpost[(key,k)]<=w)
            for p in 1:length(writers), q in p+1:length(writers)
                writers[p][2]==writers[q][2] || @constraint(ctx.jump,
                    ctx.action[(writers[p][1],k)]+ctx.action[(writers[q][1],k)]<=1)
            end
            for (i,value) in writers
                value ? @constraint(ctx.jump,ctx.bpost[(key,k)]>=ctx.action[(i,k)]) :
                    @constraint(ctx.jump,ctx.bpost[(key,k)]<=1-ctx.action[(i,k)])
            end
            @constraint(ctx.jump,ctx.bpre[(key,k+1)]==ctx.bpost[(key,k)])
        end

        for (key,domain) in ctx.enum_domains
            @constraint(ctx.jump,sum(ctx.zpost[(key,value,k)] for value in domain)==1)
            writers=[(i,string(last(op[2]))) for (i,ops) in enumerate(ctx.operations) for op in ops
                if op[1]==key && first(op[2])=="assign" && last(op[2]) isa AbstractString]
            w=sum(ctx.action[(i,k)] for (i,_) in writers;init=0.0)
            for value in domain
                @constraint(ctx.jump,ctx.zpost[(key,value,k)]-ctx.zpre[(key,value,k)]<=w)
                @constraint(ctx.jump,ctx.zpre[(key,value,k)]-ctx.zpost[(key,value,k)]<=w)
                for (i,target) in writers
                    target==value ? @constraint(ctx.jump,ctx.zpost[(key,value,k)]>=ctx.action[(i,k)]) :
                        @constraint(ctx.jump,ctx.zpost[(key,value,k)]<=1-ctx.action[(i,k)])
                end
                @constraint(ctx.jump,ctx.zpre[(key,value,k+1)]==ctx.zpost[(key,value,k)])
            end
            for p in 1:length(writers), q in p+1:length(writers)
                writers[p][2]==writers[q][2] || @constraint(ctx.jump,
                    ctx.action[(writers[p][1],k)]+ctx.action[(writers[q][1],k)]<=1)
            end
        end
    end
end

function _connection_constraints!(ctx,phase,k)
    y=phase==:pre ? ctx.ypre : ctx.ypost
    for staticset in ctx.source.connection_sets
        owner,pname=rsplit(staticset[1],'.';limit=2)
        port=ctx.source.components[owner].ports[pname]
        connector=ctx.source.connector_types[string(port["connector_type"])]
        for field in get(connector,"fields",Any[])
            name=string(field["name"]); category=string(field["category"])
            keys=["$p.$name" for p in staticset]
            if length(keys)>=2 && category=="potential"
                for key in keys[2:end]; @constraint(ctx.jump,y[(key,k)]==y[(keys[1],k)]) end
            elseif length(keys)>=2 && category=="flow"
                @constraint(ctx.jump,sum(y[(key,k)] for key in keys)==0)
            elseif length(keys)==1 && category=="flow"
                string(port["presence"])=="required" &&
                    _milp_unsupported("required singleton port '$(staticset[1])'")
                @constraint(ctx.jump,y[(keys[1],k)]==0)
            end
        end
    end
end

function _requirements!(ctx,phase,k)
    _connection_constraints!(ctx,phase,k)
    for (owner,instance) in ctx.source.components
        ct=ctx.source.component_types[instance.component_type]
        for requirement in get(ct,"requirements",Any[])
            _formula_constraint!(ctx,requirement["formula"],phase,k,owner)
        end
    end
end

function _process_rates(ctx,k)
    rates=Dict{String,Any}(key=>0.0 for key in ctx.numeric)
    for (owner,behavior) in _ground_behaviors(ctx.source,ctx.initial,"process")
        params=get(behavior,"_ground_params",Dict{String,Any}())
        active=_truth(ctx,behavior["precondition"],:post,k,owner,params)
        isnothing(active) && _milp_unsupported(
            "process '$(behavior["name"])' needs a discrete MILP activation condition")
        for effect in get(behavior,"effects",Any[])
            key=_target_key(effect["target"],ctx.initial,owner,params)
            key in ctx.numeric || _milp_unsupported("process target '$key' is not dynamic numeric state")
            rate=_lin(ctx,effect["rate"],:post,k,owner,params)
            sign=effect["operator"]=="decrease" ? -1.0 : 1.0
            if active isa Number
                rates[key]+=sign*active*rate
            elseif rate isa Number
                rates[key]+=sign*Float64(rate)*active
            else
                _milp_unsupported("state-dependent rate gated by a discrete mode is bilinear")
            end
        end
    end
    rates
end

function _continuous_constraints!(ctx)
    N=ctx.options.steps; dt=ctx.options.makespan/N
    for k in 1:N
        _requirements!(ctx,:pre,k)
        _requirements!(ctx,:post,k)
        rates=_process_rates(ctx,k)
        for key in ctx.numeric
            @constraint(ctx.jump,ctx.xpre[(key,k+1)]==ctx.xpost[(key,k)]+dt*rates[key])
        end
    end
    _requirements!(ctx,:pre,N+1)
end

function _objective_and_goal!(ctx)
    N=ctx.options.steps
    _formula_constraint!(ctx,ctx.source.goal,:pre,N+1)
    metric=get(ctx.source.provenance,"metric",nothing)
    if ctx.options.objective==:source_metric_or_actions && !isnothing(metric)
        expr=_lin(ctx,metric["expression"],:pre,N+1)
        direction=string(get(metric,"optimization","minimize"))
        direction=="maximize" ? @objective(ctx.jump,Max,expr) : @objective(ctx.jump,Min,expr)
    else
        @objective(ctx.jump,Min,sum(ctx.action[(i,k)] for i in eachindex(ctx.controls), k in 1:N))
    end
end

function _build_milp(model,options)
    ctx=_make_context(model,options)
    _new_variables!(ctx)
    _initial_constraints!(ctx)
    _action_and_discrete_constraints!(ctx)
    _continuous_constraints!(ctx)
    _objective_and_goal!(ctx)
    ctx
end

function _recover_plan(ctx)
    occurrences=PlanOccurrence[]; dt=ctx.options.makespan/ctx.options.steps; sequence=0
    for k in 1:ctx.options.steps, (i,control) in enumerate(ctx.controls)
        JuMP.value(ctx.action[(i,k)])>0.5 || continue
        sequence+=1
        push!(occurrences,PlanOccurrence(id="milp/$sequence",time=(k-1)*dt,
            kind=control.kind,schema_id=control.schema_id,name=control.name,
            owner=control.owner,arguments=deepcopy(control.arguments),duration=control.duration))
    end
    PlanDocument(model_digest=ctx.source.digest,horizon=ctx.options.makespan,
        occurrences=occurrences,metadata=Dict{String,Any}(
            "producer"=>"pddlica-hybrid-milp","producer_version"=>"0.1.0",
            "extensions"=>Dict{String,Any}()))
end

function _milp_statistics(ctx,started,status)
    Dict{String,Any}("elapsed_seconds"=>_elapsed_seconds(started),
        "solver"=>"HiGHS","termination_status"=>string(status),
        "variables"=>JuMP.num_variables(ctx.jump),
        "constraints"=>JuMP.num_constraints(ctx.jump;
            count_variable_in_set_constraints=true),
        "ground_controllables"=>length(ctx.controls),
        "steps"=>ctx.options.steps,"step_duration"=>ctx.options.makespan/ctx.options.steps,
        "objective_value"=>JuMP.has_values(ctx.jump) ? JuMP.objective_value(ctx.jump) : nothing,
        "objective_bound"=>try JuMP.objective_bound(ctx.jump) catch; nothing end)
end

function optimize(backend::HybridMILPBackend,model::ElaboratedModel,
                  options::HybridMILPOptions=HybridMILPOptions())
    report=analyze(backend,model,options)
    !report.supported && return _search_result(:UNSUPPORTED,backend,report;
        diagnostics=report.diagnostics,options=nothing)
    started=time_ns(); ctx=nothing
    try
        ctx=_build_milp(model,options)
    catch err
        if err isa _MILPBuildError
            diagnostic=Diagnostic(code="PDDLICA-MILP-030",message=err.message)
            unsupported=CapabilityReport(supported=false,backend=report.backend,
                profile=report.profile,restrictions=report.restrictions,
                diagnostics=[diagnostic],details=report.details)
            return _search_result(:UNSUPPORTED,backend,unsupported;
                diagnostics=[diagnostic],options=nothing)
        end
        return _search_result(:BACKEND_ERROR,backend,report;
            diagnostics=[Diagnostic(code="PDDLICA-MILP-900",message=sprint(showerror,err))],
            options=nothing)
    end
    try
        JuMP.optimize!(ctx.jump)
    catch err
        return _search_result(:BACKEND_ERROR,backend,report;
            diagnostics=[Diagnostic(code="PDDLICA-MILP-901",message=sprint(showerror,err))],
            statistics=_milp_statistics(ctx,started,:SOLVER_ERROR),options=nothing)
    end
    status=JuMP.termination_status(ctx.jump)
    statistics=_milp_statistics(ctx,started,status)
    if JuMP.has_values(ctx.jump)
        plan=_recover_plan(ctx)
        validation=simulate(model,plan;options=options.simulation_options)
        validation.status==:VALID || return _search_result(:INVALID_WITNESS,backend,report;
            plan=plan,validation=validation,diagnostics=validation.diagnostics,
            statistics=statistics,options=nothing)
        direction=JuMP.objective_sense(ctx.jump)==JuMP.MOI.MIN_SENSE ? "minimize" : "maximize"
        objective=Dict{String,Any}("direction"=>direction,
            "value"=>statistics["objective_value"],
            "bound"=>statistics["objective_bound"],
            "provenance"=>"JuMP/HiGHS time-indexed MILP",
            "termination_status"=>string(status),
            "optimal_within_unrolling"=>status==JuMP.MOI.OPTIMAL)
        return _search_result(:FEASIBLE,backend,report;plan=plan,validation=validation,
            statistics=statistics,objective=objective,options=nothing,
            metadata=Dict{String,Any}("candidate_preference"=>"MILP objective",
                "formulation"=>"fixed-grid hybrid MILP",
                "steps"=>options.steps,"makespan"=>options.makespan,
                "step_duration"=>options.makespan/options.steps,
                "numeric_bound"=>options.numeric_bound))
    elseif status==JuMP.MOI.TIME_LIMIT
        return _search_result(:TIME_LIMIT,backend,report;
            diagnostics=[Diagnostic(code="PDDLICA-MILP-101",message="HiGHS reached its time limit")],
            statistics=statistics,options=nothing)
    elseif status in (JuMP.MOI.INFEASIBLE,JuMP.MOI.INFEASIBLE_OR_UNBOUNDED)
        return _search_result(:NOT_FOUND,backend,report;
            diagnostics=[Diagnostic(code="PDDLICA-MILP-100",
                message="the configured MILP unrolling has no feasible solution",
                notes=["This does not prove the unbounded PDDLica problem infeasible."])],
            statistics=statistics,options=nothing)
    end
    _search_result(:BACKEND_ERROR,backend,report;
        diagnostics=[Diagnostic(code="PDDLICA-MILP-902",
            message="HiGHS terminated with status $status and no primal solution")],
        statistics=statistics,options=nothing)
end

function _milp_options(base::HybridMILPOptions,kwargs)
    values=Dict{Symbol,Any}(name=>getfield(base,name)
        for name in fieldnames(HybridMILPOptions))
    for (name,value) in kwargs
        target=name in (:max_steps,:max_macrosteps) ? :steps :
            name in (:max_makespan,) ? :makespan : name
        values[target]=value
    end
    HybridMILPOptions(;values...)
end
