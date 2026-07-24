mutable struct _MILPContext
    source::ElaboratedModel
    options::HybridMILPOptions
    jump::JuMP.Model
    controls::Vector{_GroundControl}
    operations::Vector{Vector{MILPOperation}}
    end_operations::Vector{Vector{MILPOperation}}
    continuous_operations::Vector{Vector{MILPOperation}}
    durations::Vector{Int}
    timed::Dict{Int,Vector{MILPOperation}}
    events::Vector{MILPEvent}
    initial::RuntimeState
    numeric::Vector{String}
    statics::Set{String}
    booleans::Vector{String}
    enum_domains::Dict{String,Vector{String}}
    components::Vector{String}
    fields::Vector{String}
    memory_fields::Vector{String}
    action::Dict{Tuple{Int,Int},Any}
    xpre::Dict{Tuple{String,Int},Any}
    xpost::Dict{Tuple{String,Int},Any}
    bpre::Dict{Tuple{String,Int},Any}
    bpost::Dict{Tuple{String,Int},Any}
    zpre::Dict{Tuple{String,String,Int},Any}
    zpost::Dict{Tuple{String,String,Int},Any}
    λpre::Dict{Tuple{String,Int},Any}
    λpost::Dict{Tuple{String,Int},Any}
    ypre::Dict{Tuple{String,Int},Any}
    ypost::Dict{Tuple{String,Int},Any}
    hpre::Dict{Tuple{String,Int},Any}
    hpost::Dict{Tuple{String,Int},Any}
    event_numeric::Dict{Tuple{Symbol,String,Int,Int},Any}
    event_boolean::Dict{Tuple{Symbol,String,Int,Int},Any}
    event_symbolic::Dict{Tuple{Symbol,String,String,Int,Int},Any}
    event_presence::Dict{Tuple{Symbol,String,Int,Int},Any}
    event_fields::Dict{Tuple{Symbol,String,Int,Int},Any}
    event_history::Dict{Tuple{Symbol,String,Int,Int},Any}
    preference_violation::Dict{String,Any}
end

function capabilities(backend::HybridMILPBackend)
    CapabilityReport(supported=true,backend=backend.name,
        profile="time-indexed-linear-hybrid-milp-0.2",
        restrictions=[
            "fixed time grid and finite grounded controllable schemas",
            "affine numeric expressions and process rates",
            "discrete Boolean and finite symbolic state",
            "component lifecycle changes at grid boundaries",
            "linear acausal connector equations",
            "autonomous event roots are resolved on the configured grid",
        ],
        details=Dict{String,Any}("formulation"=>"time-indexed hybrid MILP",
            "modeling_layer"=>"JuMP/MathOptInterface","default_solver"=>"HiGHS",
            "objective"=>"source metric when affine, otherwise minimum selected actions",
            "durative_actions"=>true,"timed_initial_literals"=>true,
            "conditional_and_quantified_effects"=>true,
            "derived_predicates"=>"acyclic",
            "pddl3_constraints_preferences_metrics"=>true,
            "autonomous_events"=>"bounded grid closure",
            "component_lifecycle"=>true,
            "optional_boundary_memory"=>true,
            "continuous_dynamics"=>"fixed-step affine"))
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
    options.max_event_layers>=1 || push!(out,
        Diagnostic(code="PDDLICA-MILP-007",message="max_event_layers must be positive"))
    out
end

function analyze(backend::HybridMILPBackend,model::ElaboratedModel,
                 options::HybridMILPOptions=HybridMILPOptions())
    diags=_milp_option_diagnostics(options)
    base=capabilities(backend)
    CapabilityReport(supported=isempty(diags),backend=base.backend,profile=base.profile,
        restrictions=base.restrictions,diagnostics=diags,
        details=merge(base.details,Dict{String,Any}("steps"=>options.steps,
            "makespan"=>options.makespan,"step_duration"=>options.makespan/options.steps,
            "max_event_layers"=>options.max_event_layers)))
end

function _bounds(options,key)
    get(options.numeric_bounds,key,(-options.numeric_bound,options.numeric_bound))
end

function _make_context(model,options)
    initial=_initial_runtime(model)
    controls=ground_controls(model,options)
    operations=ground_operations(model,controls,initial)
    end_operations=ground_operations(model,controls,initial;timing=:end)
    continuous_operations=ground_operations(model,controls,initial;timing=:continuous)
    durations=duration_steps(controls,options)
    timed=ground_timed_initials(model,initial,options)
    events=ground_events(model,initial)
    statics=static_keys(model)
    numeric=sort!([key for (key,value) in model.initial_values
        if value isa Number && !(value isa Bool) && !(key in statics)])
    booleans=Set(predicate_keys(model))
    union!(booleans,[key for (key,value) in model.initial_values if value isa Bool])
    symbols=Set{String}(); collect_symbols!(symbols,model.document.domain)
    collect_symbols!(symbols,model.document.problem)
    enum_domains=Dict{String,Vector{String}}()
    for (key,value) in model.initial_values
        value isa AbstractString || continue
        enum_domains[key]=sort!(unique(vcat([string(value)],collect(symbols))))
    end
    all_operations=vcat(operations,end_operations,continuous_operations,
        collect(values(timed)))
    for ops in all_operations, operation in ops
        key=operation.key; value=operation.value
        if value isa Bool
            push!(booleans,key)
        elseif value isa AbstractString
            domain=get!(enum_domains,key,String[])
            push!(domain,string(value)); sort!(unique!(domain))
        elseif value isa Number
            key in numeric || key in statics || push!(numeric,key)
        end
    end
    components=sort!(collect(keys(model.components)))
    fields=String[]
    memory_fields=String[]
    for (owner,instance) in model.components
        for (port_name,port) in instance.ports
            connector=model.connector_types[string(port["connector_type"])]
            for field in get(connector,"fields",Any[])
                key="$owner.$port_name.$(field["name"])"
                push!(fields,key)
                string(port["presence"])=="optional" &&
                    string(field["category"])=="potential" &&
                    push!(memory_fields,key)
            end
        end
    end
    sort!(unique!(fields))
    sort!(unique!(memory_fields))
    jm=JuMP.Model(HiGHS.Optimizer)
    options.silent && JuMP.set_silent(jm)
    !isnothing(options.time_limit_seconds) &&
        JuMP.set_time_limit_sec(jm,options.time_limit_seconds)
    !isnothing(options.mip_relative_gap) &&
        JuMP.set_optimizer_attribute(jm,"mip_rel_gap",options.mip_relative_gap)
    _MILPContext(model,options,jm,controls,operations,end_operations,
        continuous_operations,durations,timed,events,initial,sort!(unique(numeric)),
        statics,sort!(collect(booleans)),enum_domains,components,fields,memory_fields,
        Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),
        Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict())
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
        for k in 1:N+1
            ctx.xpost[(key,k)]=@variable(ctx.jump,lower_bound=lo,upper_bound=hi,
                base_name="xpost[$key,$k]")
        end
    end
    for key in ctx.booleans
        for k in 1:N+1
            ctx.bpre[(key,k)]=@variable(ctx.jump,binary=true,base_name="b[$key,$k]")
        end
        for k in 1:N+1
            ctx.bpost[(key,k)]=@variable(ctx.jump,binary=true,base_name="bpost[$key,$k]")
        end
    end
    for (key,domain) in ctx.enum_domains, value in domain
        for k in 1:N+1
            ctx.zpre[(key,value,k)]=@variable(ctx.jump,binary=true,
                base_name="z[$key,$value,$k]")
        end
        for k in 1:N+1
            ctx.zpost[(key,value,k)]=@variable(ctx.jump,binary=true,
                base_name="zpost[$key,$value,$k]")
        end
    end
    for component in ctx.components
        for k in 1:N+1
            ctx.λpre[(component,k)]=@variable(ctx.jump,binary=true,
                base_name="present[$component,$k]")
        end
        for k in 1:N+1
            ctx.λpost[(component,k)]=@variable(ctx.jump,binary=true,
                base_name="present_post[$component,$k]")
        end
    end
    for key in ctx.fields
        for k in 1:N+1
            ctx.ypre[(key,k)]=@variable(ctx.jump,lower_bound=-M,upper_bound=M,
                base_name="y[$key,$k]")
        end
        for k in 1:N+1
            ctx.ypost[(key,k)]=@variable(ctx.jump,lower_bound=-M,upper_bound=M,
                base_name="ypost[$key,$k]")
        end
    end
    for key in ctx.memory_fields, k in 1:N+1
        ctx.hpre[(key,k)]=@variable(ctx.jump,lower_bound=-M,upper_bound=M,
            base_name="history[$key,$k]")
        ctx.hpost[(key,k)]=@variable(ctx.jump,lower_bound=-M,upper_bound=M,
            base_name="history_post[$key,$k]")
    end
    _uses_event_points(ctx) || return
    for side in (:pre,:post), k in 1:N+1, layer in 0:_event_layers(ctx)
        for key in ctx.numeric
            lo,hi=_bounds(ctx.options,key)
            ctx.event_numeric[(side,key,k,layer)]=@variable(ctx.jump,
                lower_bound=lo,upper_bound=hi,
                base_name="event_$side[$key,$k,$layer]")
        end
        for key in ctx.booleans
            ctx.event_boolean[(side,key,k,layer)]=@variable(ctx.jump,binary=true,
                base_name="event_$side[$key,$k,$layer]")
        end
        for (key,domain) in ctx.enum_domains, value in domain
            ctx.event_symbolic[(side,key,value,k,layer)]=@variable(ctx.jump,
                binary=true,base_name="event_$side[$key,$value,$k,$layer]")
        end
        for component in ctx.components
            ctx.event_presence[(side,component,k,layer)]=@variable(ctx.jump,
                binary=true,base_name="event_$(side)_present[$component,$k,$layer]")
        end
        for key in ctx.fields
            ctx.event_fields[(side,key,k,layer)]=@variable(ctx.jump,
                lower_bound=-M,upper_bound=M,
                base_name="event_$side[$key,$k,$layer]")
        end
        for key in ctx.memory_fields
            ctx.event_history[(side,key,k,layer)]=@variable(ctx.jump,
                lower_bound=-M,upper_bound=M,
                base_name="event_$(side)_history[$key,$k,$layer]")
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

_uses_event_points(ctx)=!isempty(ctx.events) || !isempty(ctx.memory_fields)
_event_layers(ctx)=isempty(ctx.events) ? 1 : ctx.options.max_event_layers
_raw_phase(ctx,side,k) = _uses_event_points(ctx) ?
    MILPEventPoint(side,k,0) : side

function _numeric(ctx,key,phase,k)
    phase isa MILPEventPoint &&
        return ctx.event_numeric[(phase.side,key,phase.index,phase.layer)]
    phase==:pre ? ctx.xpre[(key,k)] : ctx.xpost[(key,k)]
end

function _boolean(ctx,key,phase,k)
    phase isa MILPEventPoint &&
        return ctx.event_boolean[(phase.side,key,phase.index,phase.layer)]
    phase==:pre ? ctx.bpre[(key,k)] : ctx.bpost[(key,k)]
end

function _symbolic(ctx,key,value,phase,k)
    phase isa MILPEventPoint &&
        return ctx.event_symbolic[(phase.side,key,value,phase.index,phase.layer)]
    phase==:pre ? ctx.zpre[(key,value,k)] : ctx.zpost[(key,value,k)]
end

function _field(ctx,key,phase,k)
    phase isa MILPEventPoint &&
        return ctx.event_fields[(phase.side,key,phase.index,phase.layer)]
    phase==:pre ? ctx.ypre[(key,k)] : ctx.ypost[(key,k)]
end

function _history(ctx,key,phase,k)
    phase isa MILPEventPoint &&
        return ctx.event_history[(phase.side,key,phase.index,phase.layer)]
    phase==:pre ? ctx.hpre[(key,k)] : ctx.hpost[(key,k)]
end

function _presence(ctx,component,phase,k)
    component in ctx.components || milp_unsupported(
        "unknown component '$component' in MILP formula")
    phase isa MILPEventPoint &&
        return ctx.event_presence[(phase.side,component,phase.index,phase.layer)]
    phase==:pre ? ctx.λpre[(component,k)] : ctx.λpost[(component,k)]
end

function _active_presence(ctx,component,phase,k)
    path=split(component,'.')
    values=Any[_presence(ctx,join(path[1:i],'.'),phase,k)
        for i in eachindex(path)]
    _logic_and!(ctx,values;name="effective_presence")
end

function _lin(ctx,expr,phase,k,owner="",params=Dict{String,Any}())
    expr isa Number && return Float64(expr)
    kind=get(expr,"kind","")
    kind=="number" && return Float64(_parse_time(expr["value"]))
    if kind=="variable"
        name=string(expr["name"])
        haskey(params,name) || milp_unsupported("unbound numeric variable '?$name'")
        value=params[name]
        value isa Number || milp_unsupported("'?$name' is not numeric")
        return Float64(value)
    end
    if kind=="symbol"
        string(expr["name"])=="total-time" && return ctx.options.makespan
        string(expr["name"])=="#t" && return 1.0
        milp_unsupported("symbol '$(expr["name"])' is not a numeric MILP value")
    end
    if kind=="call"
        if string(expr["name"])=="is-violated"
            arguments=get(expr,"arguments",Any[])
            isempty(arguments) && milp_unsupported("is-violated requires a preference name")
            name=string(get(arguments[1],"name",""))
            haskey(ctx.preference_violation,name) || milp_unsupported(
                "unknown preference '$name' in metric")
            return ctx.preference_violation[name]
        end
        key=_state_key(ctx,expr,owner,params)
        key in ctx.statics && return Float64(ctx.source.initial_values[key])
        key in ctx.numeric || milp_unsupported("'$key' is not a numeric MILP fluent")
        return _numeric(ctx,key,phase,k)
    elseif kind=="port_field"
        key=_field_key(expr,owner)
        key in ctx.fields || milp_unsupported("inactive or unknown connector field '$key'")
        return _field(ctx,key,phase,k)
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
                    milp_unsupported("non-affine multiplication in MILP expression")
                end
            end
            return result
        elseif op=="/"
            args[2] isa Number || milp_unsupported("division by a MILP variable is non-affine")
            return args[1]/args[2]
        end
    end
    milp_unsupported("unsupported affine value node '$kind'")
end

function _state_points(ctx)
    N=ctx.options.steps; Δt=ctx.options.makespan/N
    points=Tuple{Symbol,Int,Float64}[]
    for k in 1:N
        t=(k-1)*Δt
        push!(points,(:pre,k,t),(:post,k,t))
    end
    push!(points,(:pre,N+1,ctx.options.makespan),
        (:post,N+1,ctx.options.makespan))
    points
end

function _trajectory_truth(ctx,formula,params=Dict{String,Any}())
    kind=get(formula,"kind",""); points=_state_points(ctx)
    truth(body,point)=_truth(ctx,body,point[1],point[2],"",params)

    if kind=="preference"
        return _trajectory_truth(ctx,formula["body"],params)
    elseif kind in ("forall","exists")
        values=Any[_trajectory_truth(ctx,formula["body"],environment)
            for environment in _bindings(ctx.source,get(formula,"parameters",Any[]),params)]
        return kind=="forall" ? _logic_and!(ctx,values;name="trajectory_forall") :
            _logic_or!(ctx,values;name="trajectory_exists")
    elseif kind in ("and","or")
        values=Any[_trajectory_truth(ctx,item,params) for item in formula["items"]]
        return kind=="and" ? _logic_and!(ctx,values;name="trajectory_and") :
            _logic_or!(ctx,values;name="trajectory_or")
    elseif kind=="not"
        return 1-_trajectory_truth(ctx,formula["item"],params)
    elseif kind=="imply"
        a=_trajectory_truth(ctx,formula["antecedent"],params)
        b=_trajectory_truth(ctx,formula["consequent"],params)
        return _logic_or!(ctx,Any[1-a,b];name="trajectory_imply")
    elseif kind=="always"
        return _logic_and!(ctx,Any[truth(formula["body"],point) for point in points];
            name="always")
    elseif kind=="sometime"
        return _logic_or!(ctx,Any[truth(formula["body"],point) for point in points];
            name="sometime")
    elseif kind=="within"
        deadline=_parse_time(formula["times"][1]["value"])
        values=Any[truth(formula["body"],point) for point in points
            if point[3]<=deadline+ctx.options.strict_epsilon]
        return _logic_or!(ctx,values;name="within")
    elseif kind=="hold_during"
        lo=_parse_time(formula["times"][1]["value"])
        hi=_parse_time(formula["times"][2]["value"])
        values=Any[truth(formula["body"],point) for point in points
            if lo-ctx.options.strict_epsilon<=point[3]<=hi+ctx.options.strict_epsilon]
        return _logic_and!(ctx,values;name="hold_during")
    elseif kind=="hold_after"
        lo=_parse_time(formula["time"]["value"])
        values=Any[truth(formula["body"],point) for point in points
            if point[3]>=lo-ctx.options.strict_epsilon]
        return _logic_and!(ctx,values;name="hold_after")
    elseif kind=="at_most_once"
        values=Any[truth(formula["body"],point) for point in points]
        rises=Any[]
        for i in eachindex(values)
            previous=i==1 ? 0.0 : values[i-1]
            push!(rises,_logic_and!(ctx,Any[values[i],1-previous];name="rising_edge"))
        end
        count=sum(rises); satisfied=@variable(ctx.jump,binary=true,
            base_name="at_most_once")
        @constraint(ctx.jump,count<=1+length(rises)*(1-satisfied))
        @constraint(ctx.jump,count>=2*(1-satisfied))
        return satisfied
    elseif kind in ("sometime_before","sometime_after")
        first=Any[truth(formula["first"],point) for point in points]
        second=Any[truth(formula["second"],point) for point in points]
        implications=Any[]
        if kind=="sometime_before"
            for j in eachindex(points)
                earlier=Any[first[i] for i in eachindex(points)
                    if points[i][3]<points[j][3]-ctx.options.strict_epsilon]
                push!(implications,_logic_or!(ctx,vcat(Any[1-second[j]],earlier);
                    name="sometime_before"))
            end
        else
            for i in eachindex(points)
                later=Any[second[j] for j in eachindex(points)
                    if points[j][3]>points[i][3]+ctx.options.strict_epsilon]
                push!(implications,_logic_or!(ctx,vcat(Any[1-first[i]],later);
                    name="sometime_after"))
            end
        end
        return _logic_and!(ctx,implications;name=kind)
    elseif kind=="always_within"
        Δ=_parse_time(formula["time"]["value"]); implications=Any[]
        for i in eachindex(points)
            responses=Any[truth(formula["response"],points[j]) for j in eachindex(points)
                if points[i][3]-ctx.options.strict_epsilon<=points[j][3]<=
                    points[i][3]+Δ+ctx.options.strict_epsilon]
            trigger=truth(formula["trigger"],points[i])
            push!(implications,_logic_or!(ctx,vcat(Any[1-trigger],responses);
                name="always_within"))
        end
        return _logic_and!(ctx,implications;name="always_within_all")
    end
    _truth(ctx,formula,:pre,ctx.options.steps+1,"",params)
end

function _preference_constraints!(ctx)
    constraints=get(ctx.source.provenance,"constraints",Any[])
    preferences=copy(get(ctx.source.provenance,"preferences",Any[]))
    append!(preferences,Any[c for c in constraints if get(c,"kind","")=="preference"])

    for (i,preference) in enumerate(preferences)
        name=string(get(preference,"name","preference-$i"))
        satisfied=_trajectory_truth(ctx,preference)
        violation=@variable(ctx.jump,binary=true,base_name="violated[$name]")
        @constraint(ctx.jump,violation==1-satisfied)
        ctx.preference_violation[name]=violation
    end
    for constraint in constraints
        get(constraint,"kind","")=="preference" && continue
        @constraint(ctx.jump,_trajectory_truth(ctx,constraint)==1)
    end
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
    variable=_symbolic(ctx,key,value,phase,k)
    op=="=" ? variable : 1-variable
end

function _logic_and!(ctx,items;name="logic_and")
    isempty(items) && return 1.0
    all(x->x isa Number,items) && return all(x->x>=1-1e-9,items) ? 1.0 : 0.0
    result=@variable(ctx.jump,binary=true,base_name=name)
    foreach(x->@constraint(ctx.jump,result<=x),items)
    @constraint(ctx.jump,result>=sum(items;init=0.0)-(length(items)-1))
    result
end

function _logic_or!(ctx,items;name="logic_or")
    isempty(items) && return 0.0
    all(x->x isa Number,items) && return any(x->x>=1-1e-9,items) ? 1.0 : 0.0
    result=@variable(ctx.jump,binary=true,base_name=name)
    foreach(x->@constraint(ctx.jump,result>=x),items)
    @constraint(ctx.jump,result<=sum(items;init=0.0))
    result
end

function _numeric_comparison_truth(ctx,f,phase,k,owner,params)
    diff=_lin(ctx,f["left"],phase,k,owner,params)-
        _lin(ctx,f["right"],phase,k,owner,params)
    op=string(f["operator"]); M=2ctx.options.numeric_bound
    eps=ctx.options.strict_epsilon
    diff isa Number && return _eval_formula(f,ctx.initial,owner,params;
        model=ctx.source) ? 1.0 : 0.0
    if op=="!="
        return 1-_numeric_comparison_truth(ctx,
            Dict{String,Any}("kind"=>"compare","operator"=>"=",
                "left"=>f["left"],"right"=>f["right"]),phase,k,owner,params)
    elseif op=="="
        ge=_numeric_comparison_truth(ctx,
            Dict{String,Any}("kind"=>"compare","operator"=>">=",
                "left"=>f["left"],"right"=>f["right"]),phase,k,owner,params)
        le=_numeric_comparison_truth(ctx,
            Dict{String,Any}("kind"=>"compare","operator"=>"<=",
                "left"=>f["left"],"right"=>f["right"]),phase,k,owner,params)
        return _logic_and!(ctx,Any[ge,le];name="numeric_equal")
    end
    result=@variable(ctx.jump,binary=true,base_name="numeric_compare")
    if op==">="
        @constraint(ctx.jump,diff>=-M*(1-result))
        @constraint(ctx.jump,diff<=-eps+M*result)
    elseif op==">"
        @constraint(ctx.jump,diff>=eps-M*(1-result))
        @constraint(ctx.jump,diff<=M*result)
    elseif op=="<="
        @constraint(ctx.jump,diff<=M*(1-result))
        @constraint(ctx.jump,diff>=eps-M*result)
    elseif op=="<"
        @constraint(ctx.jump,diff<=-eps+M*(1-result))
        @constraint(ctx.jump,diff>=-M*result)
    else
        milp_unsupported("unknown comparison operator '$op'")
    end
    result
end

function _derived_formula(ctx,f,owner,params,derived_stack)
    name=string(f["name"])
    derived=get(ctx.source.provenance,"derived_predicates",Dict{String,Any}())
    haskey(derived,name) || return nothing
    name in derived_stack && milp_unsupported(
        "recursive derived predicate '$name' cannot be finitely expanded")
    declaration=derived[name]; env=copy(params)
    for (parameter,argument) in zip(get(declaration,"parameters",Any[]),
                                    get(f,"arguments",Any[]))
        value=_eval_value(argument,ctx.initial,owner,params)
        env[string(parameter["name"])]=value
    end
    declaration["body"],env,union(derived_stack,Set([name]))
end

function _truth(ctx,f,phase,k,owner="",params=Dict{String,Any}();
                derived_stack=Set{String}())
    kind=get(f,"kind","")
    kind=="boolean" && return Bool(f["value"]) ? 1.0 : 0.0
    enum=_enum_condition(ctx,f,phase,k,owner,params)
    !isnothing(enum) && return enum
    if kind=="atom"
        expanded=_derived_formula(ctx,f,owner,params,derived_stack)
        !isnothing(expanded) && return _truth(ctx,expanded[1],phase,k,owner,
            expanded[2];derived_stack=expanded[3])
        key=_state_key(ctx,Dict{String,Any}("name"=>f["name"],
            "arguments"=>get(f,"arguments",Any[])),owner,params)
        key in ctx.booleans || milp_unsupported("unknown Boolean MILP fluent '$key'")
        return _boolean(ctx,key,phase,k)
    elseif kind=="not"
        return 1-_truth(ctx,f["item"],phase,k,owner,params;
            derived_stack=derived_stack)
    elseif kind in ("and","or")
        items=[_truth(ctx,x,phase,k,owner,params;
            derived_stack=derived_stack) for x in f["items"]]
        return kind=="and" ? _logic_and!(ctx,items) : _logic_or!(ctx,items)
    elseif kind=="imply"
        a=_truth(ctx,f["antecedent"],phase,k,owner,params;
            derived_stack=derived_stack)
        b=_truth(ctx,f["consequent"],phase,k,owner,params;
            derived_stack=derived_stack)
        return _logic_or!(ctx,Any[1-a,b];name="implication")
    elseif kind in ("forall","exists")
        items=Any[_truth(ctx,f["body"],phase,k,owner,env;
            derived_stack=derived_stack)
            for env in _bindings(ctx.source,get(f,"parameters",Any[]),params)]
        return kind=="forall" ? _logic_and!(ctx,items;name="forall") :
            _logic_or!(ctx,items;name="exists")
    elseif kind=="preference"
        return _truth(ctx,f["body"],phase,k,owner,params;
            derived_stack=derived_stack)
    elseif kind=="compare"
        return _numeric_comparison_truth(ctx,f,phase,k,owner,params)
    elseif kind=="present"
        component=_component_path(f["component"],owner,params)
        return _presence(ctx,component,phase,k)
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
    if op=="!="
        truth=_numeric_comparison_truth(ctx,f,phase,k,owner,params)
        isnothing(gate) ? @constraint(ctx.jump,truth==1) :
            @constraint(ctx.jump,gate<=truth)
        return
    end
    op==">=" && (@constraint(ctx.jump,diff>=-slack); return)
    op==">" && (@constraint(ctx.jump,diff>=eps-slack); return)
    op=="<=" && (@constraint(ctx.jump,diff<=slack); return)
    op=="<" && (@constraint(ctx.jump,diff<=-eps+slack); return)
    milp_unsupported("unknown comparison operator '$op'")
end

function _formula_constraint!(ctx,f,phase,k,owner="",params=Dict{String,Any}();gate=nothing)
    kind=get(f,"kind","")
    if kind=="boolean"
        !Bool(f["value"]) && (isnothing(gate) ? milp_unsupported("hard false formula") :
            @constraint(ctx.jump,gate==0))
    elseif kind=="and"
        foreach(x->_formula_constraint!(ctx,x,phase,k,owner,params;gate=gate),f["items"])
    elseif kind=="compare"
        _compare_constraint!(ctx,f,phase,k,owner,params;gate=gate)
    elseif kind in ("atom","not","or","forall","exists","preference")
        truth=_truth(ctx,f,phase,k,owner,params)
        isnothing(gate) ? @constraint(ctx.jump,truth==1) : @constraint(ctx.jump,gate<=truth)
    elseif kind=="imply"
        antecedent=_truth(ctx,f["antecedent"],phase,k,owner,params)
        isnothing(antecedent) && milp_unsupported("MILP implication antecedent must be discrete")
        combined=isnothing(gate) ? antecedent : begin
            g=@variable(ctx.jump,binary=true,base_name="implication_gate")
            @constraint(ctx.jump,g<=gate); @constraint(ctx.jump,g<=antecedent)
            @constraint(ctx.jump,g>=gate+antecedent-1); g
        end
        _formula_constraint!(ctx,f["consequent"],phase,k,owner,params;gate=combined)
    elseif kind=="present"
        present=_truth(ctx,f,phase,k,owner,params)
        isnothing(gate) ? @constraint(ctx.jump,present==1) :
            @constraint(ctx.jump,gate<=present)
    else
        milp_unsupported("formula kind '$kind' is not in the MILP transcription profile")
    end
end

function _operation_gate(ctx,operation::MILPOperation,control_gate,phase,k)
    isempty(operation.conditions) && return control_gate
    condition=_logic_and!(ctx,Any[_truth(ctx,c,phase,k,operation.owner,
        operation.parameters) for c in operation.conditions];
        name="conditional_effect")
    condition isa Number && return condition>=1-1e-9 ? control_gate : 0.0
    gate=@variable(ctx.jump,binary=true,base_name="effect_gate")
    @constraint(ctx.jump,gate<=control_gate)
    @constraint(ctx.jump,gate<=condition)
    @constraint(ctx.jump,gate>=control_gate+condition-1)
    gate
end

function _initial_constraints!(ctx)
    phase=_raw_phase(ctx,:pre,1)
    for key in ctx.numeric
        haskey(ctx.source.initial_values,key) || milp_unsupported("numeric fluent '$key' lacks an initial value")
        value=Float64(ctx.source.initial_values[key])
        for operation in get(ctx.timed,1,MILPOperation[])
            operation.key==key || continue
            update=_constant_effect(operation)
            value=operation.operator=="assign" ? update :
                operation.operator=="increase" ? value+update : value-update
        end
        @constraint(ctx.jump,_numeric(ctx,key,phase,1)==value)
    end
    for key in ctx.booleans
        value=get(ctx.source.initial_values,key,false)
        for operation in get(ctx.timed,1,MILPOperation[])
            operation.key==key || continue
            operation.operator=="assign" || milp_unsupported(
                "timed Boolean update on '$key' must be an assignment")
            value=Bool(operation.value)
        end
        @constraint(ctx.jump,_boolean(ctx,key,phase,1)==(value ? 1 : 0))
    end
    for (key,domain) in ctx.enum_domains
        initial=string(ctx.source.initial_values[key])
        for operation in get(ctx.timed,1,MILPOperation[])
            operation.key==key || continue
            operation.operator=="assign" || milp_unsupported(
                "timed symbolic update on '$key' must be an assignment")
            initial=string(operation.value)
        end
        @constraint(ctx.jump,sum(_symbolic(ctx,key,value,phase,1)
            for value in domain)==1)
        for value in domain
            @constraint(ctx.jump,_symbolic(ctx,key,value,phase,1)==
                (value==initial ? 1 : 0))
        end
    end
    for component in ctx.components
        initial=get(ctx.source.initial_presence,component,false)
        for operation in get(ctx.timed,1,MILPOperation[])
            operation.key=="@presence:"*component || continue
            initial=Bool(operation.value)
        end
        @constraint(ctx.jump,_presence(ctx,component,phase,1)==
            (initial ? 1 : 0))
    end
end

_effect_affine(ctx,value::MILPEffectValue,k;phase=:pre)=
    _lin(ctx,value.expression,phase,k,value.owner,value.parameters)
_effect_affine(ctx,value,k;phase=:pre)=value

function _constant_effect(operation::MILPOperation)
    value=operation.value
    value isa Number && return Float64(value)
    value isa MILPEffectValue || milp_unsupported(
        "timed numeric effect on '$(operation.key)' is not numeric")
    expression=value.expression
    get(expression,"kind","")=="number" || milp_unsupported(
        "timed numeric effect on '$(operation.key)' must use a constant value")
    Float64(_parse_time(expression["value"]))
end

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
    occurrence=control_occurrence(control)
    owner=control.kind==:method ? join(control.owner,'.') : ""
    params=_params_for(behavior,occurrence)
    formulas=control.kind==:durative_action ?
        Any[x["formula"] for x in get(behavior,"conditions",Any[])] :
        Any[behavior["precondition"]]
    reads=reduce(union,(_formula_reads(formula,ctx.initial,owner,params)
        for formula in formulas);init=Set{String}())
    for operation in ctx.operations[i]
        value=operation.value
        value isa MILPEffectValue &&
            union!(reads,_value_reads(value.expression,ctx.initial,
                value.owner,value.parameters))
        for condition in operation.conditions
            union!(reads,_formula_reads(condition,ctx.initial,
                operation.owner,operation.parameters))
        end
    end
    reads
end

function _transition_operations(ctx,k)
    N=ctx.options.steps
    instances=Tuple{Any,MILPOperation}[]
    if k<=N
        for i in eachindex(ctx.controls), operation in ctx.operations[i]
            gate=_operation_gate(ctx,operation,ctx.action[(i,k)],:pre,k)
            push!(instances,(gate,operation))
        end
    end
    for i in eachindex(ctx.controls)
        duration=ctx.durations[i]
        duration>0 || continue
        start=k-duration
        1<=start<=N || continue
        for operation in ctx.end_operations[i]
            gate=_operation_gate(ctx,operation,ctx.action[(i,start)],:pre,k)
            push!(instances,(gate,operation))
        end
    end
    instances
end

function _durative_constraints!(ctx,i,k)
    control=ctx.controls[i]; control.kind==:durative_action || return
    behavior=ctx.source.behaviors[control.schema_id]
    occurrence=control_occurrence(control)
    parameters=_params_for(behavior,occurrence)
    parameters["duration"]=something(control.duration,0.0)
    gate=ctx.action[(i,k)]; endpoint=k+ctx.durations[i]
    if endpoint>ctx.options.steps+1
        @constraint(ctx.jump,gate==0)
        return
    end
    haskey(behavior,"duration_constraint") &&
        _formula_constraint!(ctx,behavior["duration_constraint"],:pre,k,"",parameters;
            gate=gate)
    for condition in _timed_items(behavior,"start","formula")
        _formula_constraint!(ctx,condition,:pre,k,"",parameters;gate=gate)
    end
    for condition in _timed_items(behavior,"end","formula")
        _formula_constraint!(ctx,condition,:pre,endpoint,"",parameters;gate=gate)
    end
    for condition in _timed_items(behavior,"over_all","formula")
        for point in k:endpoint-1
            _formula_constraint!(ctx,condition,:post,point,"",parameters;gate=gate)
        end
        for point in k+1:endpoint
            _formula_constraint!(ctx,condition,:pre,point,"",parameters;gate=gate)
        end
    end
end

function _state_transition!(ctx,source,target,k,instances)
    for key in ctx.numeric
        assigns=[(gate,operation.value) for (gate,operation) in instances
            if operation.key==key && operation.operator=="assign"]
        updates=[(gate,operation.value,
            operation.operator=="increase" ? 1.0 : -1.0)
            for (gate,operation) in instances
            if operation.key==key && operation.operator in ("increase","decrease")]
        for (assignment,_) in assigns, (update,_,_) in updates
            @constraint(ctx.jump,assignment+update<=1)
        end
        for p in 1:length(assigns), q in p+1:length(assigns)
            @constraint(ctx.jump,assigns[p][1]+assigns[q][1]<=1)
        end
        assigned=sum(gate for (gate,_) in assigns;init=0.0)
        update=sum(sign*_gated_affine!(ctx,
            _effect_affine(ctx,value,k;phase=source),gate,k)
            for (gate,value,sign) in updates;init=0.0)
        old=_numeric(ctx,key,source,k)
        new=_numeric(ctx,key,target,k)
        M=ctx.options.numeric_bound
        @constraint(ctx.jump,new-(old+update)<=M*assigned)
        @constraint(ctx.jump,new-(old+update)>=-M*assigned)
        for (gate,value) in assigns
            affine=_effect_affine(ctx,value,k;phase=source)
            @constraint(ctx.jump,new-affine<=M*(1-gate))
            @constraint(ctx.jump,new-affine>=-M*(1-gate))
        end
    end

    for key in ctx.booleans
        writers=[(gate,Bool(operation.value)) for (gate,operation) in instances
            if operation.key==key && operation.operator=="assign" &&
                operation.value isa Bool]
        written=sum(gate for (gate,_) in writers;init=0.0)
        old=_boolean(ctx,key,source,k); new=_boolean(ctx,key,target,k)
        @constraint(ctx.jump,new-old<=written)
        @constraint(ctx.jump,old-new<=written)
        for p in 1:length(writers), q in p+1:length(writers)
            writers[p][2]==writers[q][2] ||
                @constraint(ctx.jump,writers[p][1]+writers[q][1]<=1)
        end
        for (gate,value) in writers
            value ? @constraint(ctx.jump,new>=gate) :
                @constraint(ctx.jump,new<=1-gate)
        end
    end

    for (key,domain) in ctx.enum_domains
        @constraint(ctx.jump,sum(_symbolic(ctx,key,value,target,k)
            for value in domain)==1)
        writers=[(gate,string(operation.value)) for (gate,operation) in instances
            if operation.key==key && operation.operator=="assign" &&
                operation.value isa AbstractString]
        written=sum(gate for (gate,_) in writers;init=0.0)
        for value in domain
            old=_symbolic(ctx,key,value,source,k)
            new=_symbolic(ctx,key,value,target,k)
            @constraint(ctx.jump,new-old<=written)
            @constraint(ctx.jump,old-new<=written)
            for (gate,assigned) in writers
                assigned==value ? @constraint(ctx.jump,new>=gate) :
                    @constraint(ctx.jump,new<=1-gate)
            end
        end
        for p in 1:length(writers), q in p+1:length(writers)
            writers[p][2]==writers[q][2] ||
                @constraint(ctx.jump,writers[p][1]+writers[q][1]<=1)
        end
    end

    for component in ctx.components
        key="@presence:"*component
        writers=[(gate,Bool(operation.value)) for (gate,operation) in instances
            if operation.key==key]
        written=sum(gate for (gate,_) in writers;init=0.0)
        old=_presence(ctx,component,source,k)
        new=_presence(ctx,component,target,k)
        @constraint(ctx.jump,new-old<=written)
        @constraint(ctx.jump,old-new<=written)
        for p in 1:length(writers), q in p+1:length(writers)
            writers[p][2]==writers[q][2] ||
                @constraint(ctx.jump,writers[p][1]+writers[q][1]<=1)
        end
        for (gate,value) in writers
            value ? @constraint(ctx.jump,new>=gate) :
                @constraint(ctx.jump,new<=1-gate)
        end
    end
end

function _action_and_discrete_constraints!(ctx)
    N=ctx.options.steps
    reads=[_control_reads(ctx,i) for i in eachindex(ctx.controls)]
    writes=[Set(operation.key for operation in
        vcat(ctx.operations[i],ctx.end_operations[i]))
        for i in eachindex(ctx.controls)]
    for k in 1:N+1
        if k<=N
            @constraint(ctx.jump,sum(ctx.action[(i,k)] for i in eachindex(ctx.controls))<=
                ctx.options.max_simultaneous_actions)
            for (i,control) in enumerate(ctx.controls)
                behavior=ctx.source.behaviors[control.schema_id]
                occurrence=control_occurrence(control)
                owner=control.kind==:method ? join(control.owner,'.') : ""
                params=_params_for(behavior,occurrence)
                if control.kind==:durative_action
                    _durative_constraints!(ctx,i,k)
                else
                    _formula_constraint!(ctx,behavior["precondition"],:pre,k,
                        owner,params;gate=ctx.action[(i,k)])
                end
                control.kind==:method && @constraint(ctx.jump,ctx.action[(i,k)]<=
                    _active_presence(ctx,owner,:pre,k))
            end
        end

        happening=Tuple{Any,Int}[]
        k<=N && append!(happening,[(ctx.action[(i,k)],i)
            for i in eachindex(ctx.controls)])
        for i in eachindex(ctx.controls)
            start=k-ctx.durations[i]
            ctx.durations[i]>0 && 1<=start<=N &&
                push!(happening,(ctx.action[(i,start)],i))
        end
        for p in eachindex(happening), q in p+1:length(happening)
            gate_i,i=happening[p]; gate_j,j=happening[q]
            (!isempty(intersect(writes[i],reads[j])) ||
             !isempty(intersect(writes[j],reads[i]))) &&
                @constraint(ctx.jump,gate_i+gate_j<=1)
        end

        _state_transition!(ctx,:pre,_raw_phase(ctx,:post,k),k,
            _transition_operations(ctx,k))
    end
end

function _connection_constraints!(ctx,phase,k)
    M=ctx.options.numeric_bound
    for staticset in ctx.source.connection_sets
        owner,pname=rsplit(staticset[1],'.';limit=2)
        port=ctx.source.components[owner].ports[pname]
        connector=ctx.source.connector_types[string(port["connector_type"])]
        for field in get(connector,"fields",Any[])
            name=string(field["name"]); category=string(field["category"])
            keys=["$p.$name" for p in staticset]
            active=Any[]
            for (port,key) in zip(staticset,keys)
                component=rsplit(port,'.';limit=2)[1]
                presence=_active_presence(ctx,component,phase,k)
                push!(active,presence)
                field_value=_field(ctx,key,phase,k)
                @constraint(ctx.jump,field_value<=M*presence)
                @constraint(ctx.jump,field_value>=-M*presence)
            end
            if length(keys)>=2 && category=="potential"
                for i in 1:length(keys), j in i+1:length(keys)
                    @constraint(ctx.jump,_field(ctx,keys[j],phase,k)-
                        _field(ctx,keys[i],phase,k)<=
                        M*(2-active[j]-active[i]))
                    @constraint(ctx.jump,_field(ctx,keys[j],phase,k)-
                        _field(ctx,keys[i],phase,k)>=
                        -M*(2-active[j]-active[i]))
                end
            elseif category=="flow"
                @constraint(ctx.jump,sum(_field(ctx,key,phase,k)
                    for key in keys)==0)
            end
            for (j,port_path) in enumerate(staticset)
                component,port_name=rsplit(port_path,'.';limit=2)
                declaration=ctx.source.components[component].ports[port_name]
                string(declaration["presence"])=="required" || continue
                others=sum(active[q] for q in eachindex(active) if q!=j;init=0.0)
                @constraint(ctx.jump,active[j]<=others)
            end
        end
    end
end

function _requirements!(ctx,phase,k)
    _connection_constraints!(ctx,phase,k)
    for (owner,instance) in ctx.source.components
        ct=ctx.source.component_types[instance.component_type]
        active=_active_presence(ctx,owner,phase,k)
        for requirement in get(ct,"requirements",Any[])
            _formula_constraint!(ctx,requirement["formula"],phase,k,owner;
                gate=active)
        end
    end
end

function _event_gate(ctx,event::MILPEvent,phase,k)
    condition=_truth(ctx,event.precondition,phase,k,event.owner,event.parameters)
    isnothing(condition) && milp_unsupported(
        "event '$(event.name)' has a non-discrete guard")
    isempty(event.owner) && return condition
    _logic_and!(ctx,Any[condition,
        _active_presence(ctx,event.owner,phase,k)];name="enabled_event")
end

function _equate_event_state!(ctx,point::MILPEventPoint,phase,k)
    for key in ctx.numeric
        @constraint(ctx.jump,_numeric(ctx,key,point,k)==_numeric(ctx,key,phase,k))
    end
    for key in ctx.booleans
        @constraint(ctx.jump,_boolean(ctx,key,point,k)==_boolean(ctx,key,phase,k))
    end
    for (key,domain) in ctx.enum_domains, value in domain
        @constraint(ctx.jump,_symbolic(ctx,key,value,point,k)==
            _symbolic(ctx,key,value,phase,k))
    end
    for component in ctx.components
        @constraint(ctx.jump,_presence(ctx,component,point,k)==
            _presence(ctx,component,phase,k))
    end
    for key in ctx.fields
        @constraint(ctx.jump,_field(ctx,key,point,k)==_field(ctx,key,phase,k))
    end
    for key in ctx.memory_fields
        @constraint(ctx.jump,_history(ctx,key,point,k)==
            _history(ctx,key,phase,k))
    end
end

function _incoming_history(ctx,key,incoming)
    if isnothing(incoming)
        initial=get(ctx.source.provenance,"initial_interface",Dict{String,Any}())
        return get(initial,key,nothing)
    end
    phase,k=incoming
    _history(ctx,key,phase,k)
end

function _boundary_history!(ctx,point::MILPEventPoint,k,incoming)
    M=ctx.options.numeric_bound
    for staticset in ctx.source.connection_sets
        active=Any[_active_presence(ctx,rsplit(port,'.';limit=2)[1],point,k)
            for port in staticset]
        for (j,port_path) in enumerate(staticset)
            owner,port_name=rsplit(port_path,'.';limit=2)
            port=ctx.source.components[owner].ports[port_name]
            string(port["presence"])=="optional" || continue
            connector=ctx.source.connector_types[string(port["connector_type"])]
            for field in get(connector,"fields",Any[])
                string(field["category"])=="potential" || continue
                key="$port_path.$(field["name"])"
                key in ctx.memory_fields || continue
                current=_history(ctx,key,point,k)
                potential=_field(ctx,key,point,k)
                present=active[j]
                prior=_incoming_history(ctx,key,incoming)
                @constraint(ctx.jump,current-potential<=M*(1-present))
                @constraint(ctx.jump,current-potential>=-M*(1-present))
                if isnothing(prior)
                    @constraint(ctx.jump,current<=M*present)
                    @constraint(ctx.jump,current>=-M*present)
                    continue
                end
                @constraint(ctx.jump,current-prior<=M*present)
                @constraint(ctx.jump,current-prior>=-M*present)
                singleton=_logic_and!(ctx,vcat(Any[present],
                    Any[1-active[q] for q in eachindex(active) if q!=j]);
                    name="optional_singleton")
                @constraint(ctx.jump,potential-prior<=M*(1-singleton))
                @constraint(ctx.jump,potential-prior>=-M*(1-singleton))
            end
        end
    end
end

function _event_invariants!(ctx,point::MILPEventPoint,k)
    for (i,control) in enumerate(ctx.controls)
        control.kind==:durative_action || continue
        duration=ctx.durations[i]
        behavior=ctx.source.behaviors[control.schema_id]
        occurrence=control_occurrence(control)
        parameters=_params_for(behavior,occurrence)
        parameters["duration"]=something(control.duration,0.0)
        for start in 1:ctx.options.steps
            endpoint=start+duration
            open=point.side==:pre ? start<k<=endpoint :
                start<=k<endpoint
            open || continue
            for condition in _timed_items(behavior,"over_all","formula")
                _formula_constraint!(ctx,condition,point,k,"",parameters;
                    gate=ctx.action[(i,start)])
            end
        end
    end
end

function _event_closure_constraints!(ctx)
    _uses_event_points(ctx) || return
    layers=_event_layers(ctx)
    for side in (:pre,:post), k in 1:ctx.options.steps+1
        source=MILPEventPoint(side,k,0)
        incoming=side==:pre ?
            (k==1 ? nothing : (:post,k-1)) : (:pre,k)
        _boundary_history!(ctx,source,k,incoming)
        _requirements!(ctx,source,k)
        _event_invariants!(ctx,source,k)
        for layer in 1:layers
            target=MILPEventPoint(side,k,layer)
            instances=Tuple{Any,MILPOperation}[]
            for event in ctx.events
                gate=_event_gate(ctx,event,source,k)
                for operation in event.operations
                    effect_gate=_operation_gate(ctx,operation,gate,source,k)
                    push!(instances,(effect_gate,operation))
                end
            end
            _state_transition!(ctx,source,target,k,instances)
            _boundary_history!(ctx,target,k,(source,k))
            _requirements!(ctx,target,k)
            _event_invariants!(ctx,target,k)
            source=target
        end
        for event in ctx.events
            @constraint(ctx.jump,_event_gate(ctx,event,source,k)==0)
        end
        _equate_event_state!(ctx,source,side,k)
    end
end

function _process_rates(ctx,k)
    rates=Dict{String,Any}(key=>0.0 for key in ctx.numeric)
    for (owner,behavior) in _ground_behaviors(ctx.source,ctx.initial,"process")
        params=get(behavior,"_ground_params",Dict{String,Any}())
        condition=_truth(ctx,behavior["precondition"],:post,k,owner,params)
        present=isempty(owner) ? 1.0 : _active_presence(ctx,owner,:post,k)
        active=_logic_and!(ctx,Any[condition,present];name="active_process")
        isnothing(active) && milp_unsupported(
            "process '$(behavior["name"])' needs a discrete MILP activation condition")
        for effect in get(behavior,"effects",Any[])
            key=_target_key(effect["target"],ctx.initial,owner,params)
            key in ctx.numeric || milp_unsupported("process target '$key' is not dynamic numeric state")
            rate=_lin(ctx,effect["rate"],:post,k,owner,params)
            sign=effect["operator"]=="decrease" ? -1.0 : 1.0
            if active isa Number
                rates[key]+=sign*active*rate
            else
                rates[key]+=sign*_gated_affine!(ctx,rate,active,k)
            end
        end
    end
    for i in eachindex(ctx.controls)
        ctx.durations[i]>0 || continue
        for start in max(1,k-ctx.durations[i]+1):k
            start<=ctx.options.steps || continue
            ctx.durations[i]>k-start || continue
            for operation in ctx.continuous_operations[i]
                operation.operator in ("increase","decrease") || milp_unsupported(
                    "durative continuous effect must increase or decrease")
                operation.key in ctx.numeric || milp_unsupported(
                    "durative continuous target '$(operation.key)' is not numeric")
                gate=_operation_gate(ctx,operation,ctx.action[(i,start)],:post,k)
                rate=_effect_affine(ctx,operation.value,k;phase=:post)
                signed=operation.operator=="decrease" ? -1.0 : 1.0
                if gate isa Number
                    rates[operation.key]+=signed*gate*rate
                else
                    rates[operation.key]+=signed*_gated_affine!(ctx,rate,gate,k)
                end
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
        target=_raw_phase(ctx,:pre,k+1)
        for key in ctx.numeric
            assignments=MILPOperation[]
            update=0.0
            for operation in get(ctx.timed,k+1,MILPOperation[])
                operation.key==key || continue
                if operation.operator=="assign"
                    push!(assignments,operation)
                elseif operation.operator=="increase"
                    update+=_constant_effect(operation)
                elseif operation.operator=="decrease"
                    update-=_constant_effect(operation)
                end
            end
            length(assignments)<=1 || milp_unsupported(
                "conflicting timed assignments on '$key'")
            if isempty(assignments)
                @constraint(ctx.jump,_numeric(ctx,key,target,k+1)==
                    ctx.xpost[(key,k)]+dt*rates[key]+update)
            else
                @constraint(ctx.jump,_numeric(ctx,key,target,k+1)==
                    _constant_effect(only(assignments)))
            end
        end
        for key in ctx.booleans
            assignments=[operation for operation in get(ctx.timed,k+1,MILPOperation[])
                if operation.key==key]
            length(assignments)<=1 || milp_unsupported(
                "conflicting timed assignments on '$key'")
            if isempty(assignments)
                @constraint(ctx.jump,_boolean(ctx,key,target,k+1)==
                    ctx.bpost[(key,k)])
            else
                operation=only(assignments)
                operation.operator=="assign" || milp_unsupported(
                    "timed Boolean update on '$key' must be an assignment")
                @constraint(ctx.jump,_boolean(ctx,key,target,k+1)==
                    (Bool(operation.value) ? 1 : 0))
            end
        end
        for (key,domain) in ctx.enum_domains
            assignments=[operation for operation in get(ctx.timed,k+1,MILPOperation[])
                if operation.key==key]
            length(assignments)<=1 || milp_unsupported(
                "conflicting timed assignments on '$key'")
            for value in domain
                if isempty(assignments)
                    @constraint(ctx.jump,_symbolic(ctx,key,value,target,k+1)==
                        ctx.zpost[(key,value,k)])
                else
                    operation=only(assignments)
                    operation.operator=="assign" || milp_unsupported(
                        "timed symbolic update on '$key' must be an assignment")
                    @constraint(ctx.jump,_symbolic(ctx,key,value,target,k+1)==
                        (string(operation.value)==value ? 1 : 0))
                end
            end
        end
        for component in ctx.components
            assignments=[operation for operation in get(ctx.timed,k+1,MILPOperation[])
                if operation.key=="@presence:"*component]
            length(assignments)<=1 || milp_unsupported(
                "conflicting timed lifecycle assignments on '$component'")
            if isempty(assignments)
                @constraint(ctx.jump,_presence(ctx,component,target,k+1)==
                    ctx.λpost[(component,k)])
            else
                @constraint(ctx.jump,_presence(ctx,component,target,k+1)==
                    (Bool(only(assignments).value) ? 1 : 0))
            end
        end
    end
    _requirements!(ctx,:pre,N+1)
    _requirements!(ctx,:post,N+1)
end

function _objective_and_goal!(ctx)
    N=ctx.options.steps
    _formula_constraint!(ctx,ctx.source.goal,:post,N+1)
    _preference_constraints!(ctx)
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
    _event_closure_constraints!(ctx)
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
        "ground_events"=>length(ctx.events),
        "steps"=>ctx.options.steps,"step_duration"=>ctx.options.makespan/ctx.options.steps,
        "objective_value"=>JuMP.has_values(ctx.jump) ? JuMP.objective_value(ctx.jump) : nothing,
        "objective_bound"=>try JuMP.objective_bound(ctx.jump) catch; nothing end)
end

function optimize(backend::HybridMILPBackend,model::ElaboratedModel,
                  options::HybridMILPOptions=HybridMILPOptions())
    report=analyze(backend,model,options)
    if !report.supported
        configuration_error=any(d->startswith(d.code,"PDDLICA-MILP-00"),
            report.diagnostics)
        return _search_result(configuration_error ? :BACKEND_ERROR : :UNSUPPORTED,
            backend,report;diagnostics=report.diagnostics,options=nothing)
    end
    started=time_ns(); ctx=nothing
    try
        ctx=_build_milp(model,options)
    catch err
        if err isa MILPTranscriptionError
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
                "max_event_layers"=>options.max_event_layers,
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
