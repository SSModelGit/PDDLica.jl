@with_kw_noshow struct _GroundControl
    schema_id::String
    name::String
    kind::Symbol
    owner::Vector{String} = String[]
    arguments::Vector{Any} = Any[]
    duration::Union{Nothing,Float64} = nothing
end

capabilities(backend::NativeSearchBackend) = CapabilityReport(
    supported=true, backend=backend.name,
    restrictions=[
        "finite object and component universe",
        "bounded number of controllable happening times",
        "candidate timestamps lie on the configured search grid",
        "first simulator-validated feasible plan is returned",
        "no optimality or bounded-infeasibility claim is made",
    ],
    details=Dict{String,Any}(
        "actions"=>true, "methods"=>true, "durative_actions"=>true,
        "simultaneous_actions"=>true, "events_and_processes"=>true,
        "components_and_connectors"=>true, "pddl3_validation"=>true))

function _optimization_options_diagnostics(options::OptimizationOptions)
    out=Diagnostic[]
    options.max_macrosteps>=0 || push!(out,Diagnostic(code="PDDLICA-OPT-001",
        message="max_macrosteps must be nonnegative"))
    isfinite(options.max_makespan) && options.max_makespan>=0 || push!(out,
        Diagnostic(code="PDDLICA-OPT-002",message="max_makespan must be finite and nonnegative"))
    options.max_simultaneous_actions>=1 || push!(out,Diagnostic(code="PDDLICA-OPT-003",
        message="max_simultaneous_actions must be positive"))
    options.max_candidates>=1 || push!(out,Diagnostic(code="PDDLICA-OPT-004",
        message="max_candidates must be positive"))
    !isnothing(options.time_step) && (!(isfinite(options.time_step)) || options.time_step<=0) &&
        push!(out,Diagnostic(code="PDDLICA-OPT-005",message="time_step must be positive and finite"))
    !isnothing(options.time_limit_seconds) &&
        (!(isfinite(options.time_limit_seconds)) || options.time_limit_seconds<=0) &&
        push!(out,Diagnostic(code="PDDLICA-OPT-006",message="time_limit_seconds must be positive and finite"))
    options.candidate_preference==:first_feasible || push!(out,Diagnostic(code="PDDLICA-OPT-007",
        message="only candidate_preference=:first_feasible is implemented"))
    options.validate_candidates || push!(out,Diagnostic(code="PDDLICA-OPT-008",
        message="candidate validation cannot be disabled"))
    out
end

function analyze(backend::NativeSearchBackend,model::ElaboratedModel,
                 options::OptimizationOptions=OptimizationOptions())
    diags=_optimization_options_diagnostics(options)
    for b in values(model.behaviors)
        get(b,"_kind","")=="durative_action" || continue
        duration=get(b,"duration",nothing)
        if isnothing(duration)
            push!(diags,Diagnostic(code="PDDLICA-OPT-020",
                message="durative action '$(b["name"])' has no duration expression"))
        end
    end
    base=capabilities(backend)
    CapabilityReport(supported=isempty(diags),backend=base.backend,profile=base.profile,
        restrictions=base.restrictions,diagnostics=diags,
        details=merge(base.details,Dict{String,Any}(
            "max_macrosteps"=>options.max_macrosteps,
            "max_makespan"=>options.max_makespan,
            "max_simultaneous_actions"=>options.max_simultaneous_actions)))
end

function _argument_product(model,parameters,index=1,current=Any[])
    index>length(parameters) && return [copy(current)]
    out=Vector{Vector{Any}}()
    p=parameters[index]
    for name in _objects_for(model,get(p,"type","object"))
        argument=Dict{String,Any}("kind"=>"symbol","name"=>name)
        append!(out,_argument_product(model,parameters,index+1,vcat(current,[argument])))
    end
    out
end

function _initial_runtime(model)
    RuntimeState(values=deepcopy(model.initial_values),presence=deepcopy(model.initial_presence))
end

function _duration_values(model,b,arguments,options,initial)
    occ=PlanOccurrence(arguments=arguments)
    params=_params_for(b,occ)
    candidates=Float64[]
    direct=_eval_value(b["duration"],initial,"",params)
    direct isa Number && push!(candidates,Float64(direct))
    grid=_search_times(options)
    append!(candidates,[stop-start for start in grid for stop in grid if stop>start])
    options.max_makespan>0 && push!(candidates,options.max_makespan)
    filter!(>(0),candidates)
    sort!(unique(candidates))
end

function _ground_controls(model,options)
    controls=_GroundControl[]
    initial=_initial_runtime(model)
    for b in sort!(collect(values(model.behaviors));by=x->string(x["id"]))
        kind=string(get(b,"_kind",""))
        kind in ("action","method","durative_action") || continue
        owners=kind=="method" ?
            [split(name,'.') for (name,instance) in sort!(collect(model.components);by=first)
                if instance.component_type==get(b,"_owner_type","")] : [String[]]
        for owner in owners, arguments in _argument_product(model,get(b,"parameters",Any[]))
            if kind=="durative_action"
                for duration in _duration_values(model,b,arguments,options,initial)
                    push!(controls,_GroundControl(schema_id=string(b["id"]),name=string(b["name"]),
                        kind=:durative_action,owner=String.(owner),arguments=deepcopy(arguments),
                        duration=duration))
                end
            else
                push!(controls,_GroundControl(schema_id=string(b["id"]),name=string(b["name"]),
                    kind=kind=="method" ? :method : :action,owner=String.(owner),
                    arguments=deepcopy(arguments)))
            end
        end
    end
    controls
end

function _search_times(options)
    options.max_macrosteps==0 && return Float64[]
    if !isnothing(options.time_step)
        return collect(0.0:options.time_step:options.max_makespan)
    end
    options.max_makespan==0 && return [0.0]
    step=options.max_makespan/max(options.max_macrosteps,1)
    Float64[k*step for k in 0:options.max_macrosteps-1]
end

function _combinations(items,max_size)
    out=Vector{Vector{eltype(items)}}()
    function visit(start,remaining,current)
        remaining==0 && (push!(out,copy(current)); return)
        for i in start:(length(items)-remaining+1)
            push!(current,items[i]); visit(i+1,remaining-1,current); pop!(current)
        end
    end
    for size in 1:min(max_size,length(items)); visit(1,size,eltype(items)[]) end
    out
end

function _occurrences(happening,time,sequence)
    PlanOccurrence[PlanOccurrence(id="search/$sequence/$i",time=time,kind=c.kind,
        schema_id=c.schema_id,name=c.name,owner=c.owner,arguments=deepcopy(c.arguments),
        duration=c.duration) for (i,c) in enumerate(happening)]
end

function _candidate_plan(model,occurrences,options)
    PlanDocument(model_digest=model.digest,horizon=options.max_makespan,
        occurrences=sort!(copy(occurrences);by=x->(x.time,x.id)),
        metadata=Dict{String,Any}("producer"=>"pddlica-native-search",
            "producer_version"=>"0.1.0","extensions"=>Dict{String,Any}()))
end

_elapsed_seconds(start_ns)=Float64(time_ns()-start_ns)/1e9

function _time_exhausted(options,start_ns)
    !isnothing(options.time_limit_seconds) &&
        _elapsed_seconds(start_ns)>=options.time_limit_seconds
end

function _extendable_candidate(validation)
    validation.status==:INVALID || return false
    !isempty(validation.diagnostics) && all(d->d.code in
        ("PDDLICA-SIM-GOAL-001","PDDLICA-SIM-CONSTRAINT-001"),validation.diagnostics)
end

function _search_result(status,backend,report;plan=nothing,validation=nothing,
                        diagnostics=Diagnostic[],statistics=Dict{String,Any}(),options=nothing,
                        objective=nothing,metadata=Dict{String,Any}())
    resolved_objective=objective
    if isnothing(resolved_objective) && !isnothing(validation) &&
       !isnothing(get(validation.metadata,"metric_value",nothing))
        resolved_objective=Dict{String,Any}(
            "direction"=>get(validation.metadata,"metric_direction",nothing),
            "value"=>get(validation.metadata,"metric_value",nothing),
            "provenance"=>"reference-simulator")
    end
    OptimizationResult(status=status,backend=backend.name,capability=report,plan=plan,
        validation=validation,objective=resolved_objective,diagnostics=diagnostics,
        statistics=statistics,
        metadata=merge(Dict{String,Any}("profile"=>report.profile,
            "candidate_preference"=>"first_feasible",
            "search_limits"=>isnothing(options) ? Dict{String,Any}() : Dict{String,Any}(
                "max_macrosteps"=>options.max_macrosteps,
                "max_makespan"=>options.max_makespan,
                "time_step"=>options.time_step,
                "max_simultaneous_actions"=>options.max_simultaneous_actions,
                "max_candidates"=>options.max_candidates,
                "time_limit_seconds"=>options.time_limit_seconds)),metadata))
end

function optimize(backend::NativeSearchBackend,model::ElaboratedModel,
                  options::OptimizationOptions=OptimizationOptions())
    report=analyze(backend,model,options)
    if !report.supported
        configuration_error=any(d->d.code in ("PDDLICA-OPT-001","PDDLICA-OPT-002",
            "PDDLICA-OPT-003","PDDLICA-OPT-004","PDDLICA-OPT-005",
            "PDDLICA-OPT-006","PDDLICA-OPT-007","PDDLICA-OPT-008"),report.diagnostics)
        return _search_result(configuration_error ? :BACKEND_ERROR : :UNSUPPORTED,backend,report;
            diagnostics=report.diagnostics,options=options)
    end
    start_ns=time_ns(); candidates=0; invalid=0; unsupported=0
    controls=_ground_controls(model,options)
    happenings=_combinations(controls,options.max_simultaneous_actions)
    times=_search_times(options)
    stats()=Dict{String,Any}("elapsed_seconds"=>_elapsed_seconds(start_ns),
        "lifted_controllables"=>count(b->get(b,"_kind","") in ("action","method","durative_action"),
            values(model.behaviors)),
        "ground_controllables"=>length(controls),"ground_happenings"=>length(happenings),
        "candidate_times"=>length(times),"candidates_simulated"=>candidates,
        "invalid_candidates"=>invalid,"unsupported_candidates"=>unsupported)

    empty_plan=_candidate_plan(model,PlanOccurrence[],options)
    validation=simulate(model,empty_plan;options=options.simulation_options)
    candidates+=1
    validation.status==:VALID && return _search_result(:FEASIBLE,backend,report;
        plan=empty_plan,validation=validation,statistics=stats(),options=options)
    validation.status==:UNSUPPORTED && return _search_result(:UNSUPPORTED,backend,report;
        validation=validation,diagnostics=validation.diagnostics,statistics=stats(),options=options)
    validation.status==:ERROR && return _search_result(:BACKEND_ERROR,backend,report;
        validation=validation,diagnostics=validation.diagnostics,statistics=stats(),options=options)
    _time_exhausted(options,start_ns) && return _search_result(:TIME_LIMIT,backend,report;
        diagnostics=[Diagnostic(code="PDDLICA-OPT-101",message="optimization time limit reached")],
        statistics=stats(),options=options)

    frontier=[(PlanOccurrence[],0)]
    for depth in 1:options.max_macrosteps
        next_frontier=Tuple{Vector{PlanOccurrence},Int}[]
        for (prefix,min_time_index) in frontier
            first_time=max(1,min_time_index+1)
            first_time>length(times) && continue
            for ti in first_time:length(times), happening in happenings
                _time_exhausted(options,start_ns) && return _search_result(:TIME_LIMIT,backend,report;
                    diagnostics=[Diagnostic(code="PDDLICA-OPT-101",message="optimization time limit reached")],
                    statistics=stats(),options=options)
                candidates>=options.max_candidates && return _search_result(:RESOURCE_LIMIT,backend,report;
                    diagnostics=[Diagnostic(code="PDDLICA-OPT-102",message="candidate limit reached")],
                    statistics=stats(),options=options)
                occurrences=vcat(prefix,_occurrences(happening,times[ti],depth))
                plan=_candidate_plan(model,occurrences,options)
                validation=simulate(model,plan;options=options.simulation_options)
                candidates+=1
                if validation.status==:VALID
                    return _search_result(:FEASIBLE,backend,report;plan=plan,
                        validation=validation,statistics=stats(),options=options)
                elseif validation.status==:UNSUPPORTED
                    unsupported+=1
                else
                    invalid+=1
                end
                _extendable_candidate(validation) && push!(next_frontier,(occurrences,ti))
            end
        end
        frontier=next_frontier
        isempty(frontier) && break
        options.iterative_deepening || break
    end
    _search_result(:NOT_FOUND,backend,report;
        diagnostics=[Diagnostic(code="PDDLICA-OPT-100",
            message="configured bounded search did not find a feasible plan",
            notes=["This is not a proof that the PDDLica problem is infeasible."])],
        statistics=stats(),options=options)
end

function _optimization_options(base,kwargs)
    values=Dict{Symbol,Any}(name=>getfield(base,name) for name in fieldnames(OptimizationOptions))
    for (name,value) in kwargs; values[name==:max_steps ? :max_macrosteps : name]=value end
    OptimizationOptions(;values...)
end

function optimize(model::ElaboratedModel;backend=HybridMILPBackend(),
                  options=nothing,kwargs...)
    if backend isa HybridMILPBackend
        base=isnothing(options) ? HybridMILPOptions() : options
        base isa HybridMILPOptions || throw(ArgumentError(
            "HybridMILPBackend requires HybridMILPOptions"))
        return optimize(backend,model,_milp_options(base,kwargs))
    elseif backend isa NativeSearchBackend
        base=isnothing(options) ? OptimizationOptions() : options
        base isa OptimizationOptions || throw(ArgumentError(
            "NativeSearchBackend requires OptimizationOptions"))
        return optimize(backend,model,_optimization_options(base,kwargs))
    end
    throw(ArgumentError("unsupported optimizer backend $(typeof(backend))"))
end

function optimize(domain_path::AbstractString,problem_path::AbstractString;
                  backend=HybridMILPBackend(),options=nothing,kwargs...)
    for (role,path) in (("domain",domain_path),("problem",problem_path))
        isfile(path) || throw(ArgumentError(
            "$role optimizer input must be a .plca file: '$path'"))
        lowercase(splitext(path)[2])==".plca" || throw(ArgumentError(
            "$role optimizer input must use the .plca extension: '$path'"))
    end
    parsed=parse_model(domain_path,problem_path)
    isnothing(parsed.document) && return OptimizationResult(status=:BACKEND_ERROR,
        backend=backend.name,diagnostics=parsed.diagnostics)
    checked=elaborate(parsed.document)
    isnothing(checked.model) && return OptimizationResult(status=:BACKEND_ERROR,
        backend=backend.name,diagnostics=checked.diagnostics)
    optimize(checked.model;backend=backend,options=options,kwargs...)
end
