"""Normalized effect value used by the mathematical planning model."""
struct MILPEffectValue
    expression::Any
    owner::String
    parameters::Dict{String,Any}
end

"""One grounded state update from the elaborated PDDLica model."""
struct MILPOperation
    key::String
    operator::String
    value::Any
    conditions::Vector{Any}
    owner::String
    parameters::Dict{String,Any}
end

struct MILPEvent
    name::String
    owner::String
    precondition::Any
    parameters::Dict{String,Any}
    operations::Vector{MILPOperation}
end

struct MILPEventPoint
    side::Symbol
    index::Int
    layer::Int
end

struct MILPTranscriptionError <: Exception
    message::String
end

Base.showerror(io::IO, e::MILPTranscriptionError) = print(io, e.message)
milp_unsupported(message) = throw(MILPTranscriptionError(message))

function collect_symbols!(out, x)
    x isa AbstractVector && (foreach(v->collect_symbols!(out,v),x); return)
    x isa AbstractDict || return
    get(x,"kind","")=="symbol" && push!(out,string(x["name"]))
    foreach(v->collect_symbols!(out,v),values(x))
end

function static_keys(model::ElaboratedModel)
    out=Set{String}()
    for (owner,instance) in model.components
        component=model.component_types[instance.component_type]
        for variable in get(component,"variables",Any[])
            Bool(get(variable,"static",false)) || continue
            base="$owner.$(variable["name"])"
            for key in keys(model.initial_values)
                (key==base || startswith(key,base*"(")) && push!(out,key)
            end
        end
    end
    out
end

function predicate_keys(model::ElaboratedModel)
    out=String[]
    for predicate in get(model.document.domain,"predicates",Any[])
        for arguments in _argument_product(model,get(predicate,"parameters",Any[]))
            values=String[string(get(argument,"name","")) for argument in arguments]
            key=string(predicate["name"])
            push!(out,isempty(values) ? key : key*"("*join(values,",")*")")
        end
    end
    out
end

control_occurrence(control) = PlanOccurrence(kind=control.kind,
    schema_id=control.schema_id,name=control.name,owner=control.owner,
    arguments=control.arguments,duration=control.duration)

function ground_effect(effect, state, owner, parameters, model; conditions=Any[])
    kind=get(effect,"kind","")
    operations=MILPOperation[]

    if kind=="and"
        for item in get(effect,"items",Any[])
            append!(operations,ground_effect(item,state,owner,parameters,model;
                conditions=conditions))
        end
    elseif kind=="when"
        append!(operations,ground_effect(effect["effect"],state,owner,parameters,model;
            conditions=vcat(conditions,Any[effect["condition"]])))
    elseif kind=="forall"
        for environment in _bindings(model,get(effect,"parameters",Any[]),parameters)
            append!(operations,ground_effect(effect["effect"],state,owner,environment,model;
                conditions=conditions))
        end
    elseif kind in ("assign","increase","decrease","scale_up","scale_down")
        key=_target_key(effect["target"],state,owner,parameters)
        value=effect["value"]
        if kind in ("scale_up","scale_down")
            current=Dict{String,Any}("kind"=>"call",
                "name"=>string(get(effect["target"],"name","")),
                "arguments"=>deepcopy(get(effect["target"],"arguments",Any[])))
            value=Dict{String,Any}("kind"=>"arithmetic",
                "operator"=>kind=="scale_up" ? "*" : "/",
                "arguments"=>Any[current,deepcopy(value)])
            kind="assign"
        end
        initial=get(state.values,key,nothing)
        resolved=initial isa Number && !(initial isa Bool) ?
            MILPEffectValue(value,owner,deepcopy(parameters)) :
            _eval_value(value,state,owner,parameters)
        push!(operations,MILPOperation(key,kind,resolved,copy(conditions),owner,
            deepcopy(parameters)))
    elseif kind=="set_atom"
        atom=effect["atom"]
        target=Dict{String,Any}("kind"=>"call","name"=>atom["name"],
            "arguments"=>get(atom,"arguments",Any[]))
        global_name=any(predicate->string(get(predicate,"name",""))==
            string(atom["name"]),get(model.document.domain,"predicates",Any[]))
        key=_target_key(target,state,global_name ? "" : owner,parameters)
        push!(operations,MILPOperation(key,"assign",Bool(effect["value"]),
            copy(conditions),owner,deepcopy(parameters)))
    elseif kind in ("create","remove")
        component=_component_path(effect["component"],owner,parameters)
        push!(operations,MILPOperation("@presence:"*component,"assign",
            kind=="create",copy(conditions),owner,deepcopy(parameters)))
    else
        milp_unsupported("effect kind '$kind' is not supported by the MILP transcription")
    end
    operations
end

function ground_controls(model::ElaboratedModel, options::HybridMILPOptions)
    search_options=OptimizationOptions(max_macrosteps=options.steps,
        max_makespan=options.makespan,
        max_simultaneous_actions=options.max_simultaneous_actions)
    _ground_controls(model,search_options)
end

function ground_events(model::ElaboratedModel, initial)
    events=MILPEvent[]
    for behavior in sort!(collect(values(model.behaviors));by=x->string(x["id"]))
        get(behavior,"_kind","")=="event" || continue
        owners=haskey(behavior,"_owner_type") ?
            [name for (name,instance) in sort!(collect(model.components);by=first)
                if instance.component_type==behavior["_owner_type"]] : [""]
        for owner in owners
            for parameters in _bindings(model,get(behavior,"parameters",Any[]),
                                        Dict{String,Any}())
                operations=ground_effect(behavior["effect"],initial,owner,
                    parameters,model)
                push!(events,MILPEvent(string(behavior["name"]),owner,
                    behavior["precondition"],deepcopy(parameters),operations))
            end
        end
    end
    events
end

function timed_effect(behavior, timing)
    effects=Any[x["effect"] for x in get(behavior,"effects",Any[])
        if get(x,"timing","")==timing]
    Dict{String,Any}("kind"=>"and","items"=>effects)
end

function ground_operations(model::ElaboratedModel, controls, initial; timing=:start)
    operations=Vector{Vector{MILPOperation}}()
    for control in controls
        behavior=model.behaviors[control.schema_id]
        occurrence=control_occurrence(control)
        owner=control.kind==:method ? join(control.owner,'.') : ""
        parameters=_params_for(behavior,occurrence)
        control.kind==:durative_action &&
            (parameters["duration"]=something(control.duration,0.0))
        effect=control.kind==:durative_action ?
            timed_effect(behavior,String(timing)) :
            timing==:start ? behavior["effect"] :
            Dict{String,Any}("kind"=>"and","items"=>Any[])
        push!(operations,ground_effect(effect,initial,owner,parameters,model))
    end
    operations
end

function duration_steps(controls, options::HybridMILPOptions)
    Δt=options.makespan/options.steps
    durations=Int[]
    for control in controls
        if control.kind!=:durative_action
            push!(durations,0)
        else
            duration=something(control.duration,0.0)
            steps=round(Int,duration/Δt)
            abs(steps*Δt-duration)<=options.strict_epsilon || milp_unsupported(
                "duration $duration for '$(control.name)' is not on the configured MILP grid")
            push!(durations,steps)
        end
    end
    durations
end

function ground_timed_initials(model::ElaboratedModel, initial,
                               options::HybridMILPOptions)
    Δt=options.makespan/options.steps
    timed=Dict{Int,Vector{MILPOperation}}()
    for item in get(model.provenance,"timed_initials",Any[])
        t=_parse_time(item["time"]); index=round(Int,t/Δt)+1
        abs((index-1)*Δt-t)<=options.strict_epsilon || milp_unsupported(
            "timed initial at $t is not on the configured MILP grid")
        1<=index<=options.steps+1 || milp_unsupported(
            "timed initial at $t lies outside the configured horizon")
        operations=ground_effect(item["effect"],initial,"",Dict{String,Any}(),model)
        any(!isempty(operation.conditions) for operation in operations) &&
            milp_unsupported("conditional timed initial effects are not supported")
        append!(get!(timed,index,MILPOperation[]),operations)
    end
    timed
end
