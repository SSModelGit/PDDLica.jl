function _cli_value(args,key; default=nothing)
    i=findfirst(==(key),args); isnothing(i)||i==length(args) ? default : args[i+1]
end

function run_cli(args=ARGS)
    isempty(args) && (println(stderr,"usage: pddlica <parse|simulate|simulate-json> ..."); return 2)
    command=args[1]; output=_cli_value(args,"--output";default="-")
    try
        if command=="parse" && length(args)>=3
            result=parse_model(args[2],args[3])
            if isnothing(result.document)
                foreach(d->println(stderr,d),result.diagnostics); return 1
            end
            output=="-" ? write_pddlica_json(stdout,result.document) : write_pddlica_json(output,result.document)
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
        else
            println(stderr,"usage: pddlica parse DOMAIN.plca PROBLEM.plca --output MODEL.json")
            println(stderr,"       pddlica simulate DOMAIN.plca PROBLEM.plca PLAN --output EXECUTION.json")
            println(stderr,"       pddlica simulate-json MODEL PLAN --output EXECUTION.json")
            return 2
        end
        0
    catch err
        println(stderr,sprint(showerror,err)); 1
    end
end
