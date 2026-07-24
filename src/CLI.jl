function _cli_value(args,key; default=nothing)
    i=findfirst(==(key),args); isnothing(i)||i==length(args) ? default : args[i+1]
end

function _optimization_cli(args)
    backend_name=lowercase(string(_cli_value(args,"--backend";default="milp")))
    raw_step=_cli_value(args,"--time-step";default=nothing)
    raw_limit=_cli_value(args,"--time-limit";default=nothing)
    if backend_name in ("milp","jump","highs")
        raw_gap=_cli_value(args,"--mip-gap";default=nothing)
        return HybridMILPBackend(),HybridMILPOptions(
            steps=parse(Int,string(_cli_value(args,"--max-steps";default="10"))),
            makespan=parse(Float64,string(_cli_value(args,"--makespan";default="10"))),
            max_simultaneous_actions=parse(Int,string(
                _cli_value(args,"--max-simultaneous";default="2"))),
            numeric_bound=parse(Float64,string(
                _cli_value(args,"--numeric-bound";default="10000"))),
            time_limit_seconds=isnothing(raw_limit) ? nothing :
                parse(Float64,string(raw_limit)),
            mip_relative_gap=isnothing(raw_gap) ? nothing :
                parse(Float64,string(raw_gap)))
    elseif backend_name in ("search","native")
        return NativeSearchBackend(),OptimizationOptions(
            max_macrosteps=parse(Int,string(_cli_value(args,"--max-steps";default="6"))),
            max_makespan=parse(Float64,string(_cli_value(args,"--makespan";default="10"))),
            time_step=isnothing(raw_step) ? nothing : parse(Float64,string(raw_step)),
            max_simultaneous_actions=parse(Int,string(
                _cli_value(args,"--max-simultaneous";default="2"))),
            max_candidates=parse(Int,string(
                _cli_value(args,"--max-candidates";default="100000"))),
            time_limit_seconds=isnothing(raw_limit) ? nothing :
                parse(Float64,string(raw_limit)))
    end
    throw(ArgumentError("unknown optimizer backend '$backend_name'; use milp or search"))
end

function _cli_json(output,payload)
    if output=="-"
        JSON3.pretty(stdout,payload); println()
    else
        open(io->JSON3.pretty(io,payload),output,"w")
    end
end

function _checked_json_model(path)
    loaded=read_pddlica_json(path)
    isnothing(loaded.document) &&
        return nothing,loaded.diagnostics
    checked=elaborate(loaded.document)
    checked.model,checked.diagnostics
end

function run_cli(args=ARGS)
    isempty(args) && (println(stderr,"usage: pddlica <parse|check|inspect|simulate|simulate-json|optimize|optimize-json|capabilities> ..."); return 2)
    command=args[1]; output=_cli_value(args,"--output";default="-")
    try
        if command=="parse" && length(args)>=3
            result=parse_model(args[2],args[3])
            if isnothing(result.document)
                foreach(d->println(stderr,d),result.diagnostics); return 1
            end
            output=="-" ? write_pddlica_json(stdout,result.document) : write_pddlica_json(output,result.document)
        elseif command=="check" && length(args)>=2
            model,diagnostics=_checked_json_model(args[2])
            _cli_json(output,Dict{String,Any}("status"=>isnothing(model) ? "invalid" : "valid",
                "model_digest"=>isnothing(model) ? nothing : model.digest,
                "diagnostics"=>diagnostic_dict.(diagnostics)))
            return isnothing(model) ? 1 : 0
        elseif command=="inspect" && length(args)>=2
            model,diagnostics=_checked_json_model(args[2])
            isnothing(model) && (_cli_json(output,Dict("status"=>"invalid",
                "diagnostics"=>diagnostic_dict.(diagnostics))); return 1)
            _cli_json(output,Dict{String,Any}("status"=>"valid","model_digest"=>model.digest,
                "domain"=>model.document.domain["name"],"problem"=>model.document.problem["name"],
                "components"=>sort!(collect(keys(model.components))),
                "connection_sets"=>model.connection_sets,
                "stored_values"=>sort!(collect(keys(model.initial_values))),
                "behaviors"=>sort!(collect(keys(model.behaviors)))))
        elseif command=="simulate" && length(args)>=4
            result=simulate(args[2],args[3],args[4])
            output=="-" ? write_execution_json(stdout,result) : write_execution_json(output,result)
            return result.status==:VALID ? 0 : 1
        elseif command=="simulate-json" && length(args)>=3
            loaded=read_pddlica_json(args[2]); isnothing(loaded.document) && error(join(string.(loaded.diagnostics),'\n'))
            elab=elaborate(loaded.document); isnothing(elab.model) && error(join(string.(elab.diagnostics),'\n'))
            result=simulate(elab.model,read_plan_json(args[3]))
            output=="-" ? write_execution_json(stdout,result) : write_execution_json(output,result)
            return result.status==:VALID ? 0 : 1
        elseif command=="optimize" && length(args)>=3
            backend,options=_optimization_cli(args)
            result=optimize(args[2],args[3];backend=backend,options=options)
            output=="-" ? write_optimization_result_json(stdout,result) :
                write_optimization_result_json(output,result)
            return result.status==:FEASIBLE ? 0 : 1
        elseif command=="optimize-json" && length(args)>=2
            loaded=read_pddlica_json(args[2]); isnothing(loaded.document) &&
                error(join(string.(loaded.diagnostics),'\n'))
            checked=elaborate(loaded.document); isnothing(checked.model) &&
                error(join(string.(checked.diagnostics),'\n'))
            backend,options=_optimization_cli(args)
            result=optimize(checked.model;backend=backend,options=options)
            output=="-" ? write_optimization_result_json(stdout,result) :
                write_optimization_result_json(output,result)
            return result.status==:FEASIBLE ? 0 : 1
        elseif command=="capabilities" && length(args)>=3
            parsed=parse_model(args[2],args[3])
            isnothing(parsed.document) &&
                (_cli_json(output,Dict("supported"=>false,
                    "diagnostics"=>diagnostic_dict.(parsed.diagnostics))); return 1)
            checked=elaborate(parsed.document)
            isnothing(checked.model) &&
                (_cli_json(output,Dict("supported"=>false,
                    "diagnostics"=>diagnostic_dict.(checked.diagnostics))); return 1)
            backend,options=_optimization_cli(args)
            report=analyze(backend,checked.model,options)
            _cli_json(output,capability_dict(report))
            return report.supported ? 0 : 1
        else
            println(stderr,"usage: pddlica parse DOMAIN.plca PROBLEM.plca --output MODEL.json")
            println(stderr,"       pddlica check MODEL.json")
            println(stderr,"       pddlica inspect MODEL.json")
            println(stderr,"       pddlica simulate DOMAIN.plca PROBLEM.plca PLAN --output EXECUTION.json")
            println(stderr,"       pddlica simulate-json MODEL PLAN --output EXECUTION.json")
            println(stderr,"       pddlica optimize DOMAIN.plca PROBLEM.plca [--backend milp|search] --max-steps N --makespan T --output RESULT.json")
            println(stderr,"       pddlica optimize-json MODEL [--backend milp|search] --max-steps N --makespan T --output RESULT.json")
            println(stderr,"       pddlica capabilities DOMAIN.plca PROBLEM.plca [--backend milp|search]")
            return 2
        end
        0
    catch err
        println(stderr,sprint(showerror,err)); 1
    end
end
