@with_kw_noshow struct SourceSpan
    document::String = ""
    start_byte::Int = 0
    end_byte::Int = 0
    start_line::Int = 1
    start_column::Int = 1
    end_line::Int = 1
    end_column::Int = 1
end

@with_kw_noshow struct Diagnostic
    severity::Symbol = :error
    code::String = "PDDLICA-ERROR"
    message::String = ""
    location::Union{Nothing,SourceSpan} = nothing
    related::Vector{Any} = Any[]
    notes::Vector{String} = String[]
    data::Dict{String,Any} = Dict{String,Any}()
end

Base.show(io::IO, d::Diagnostic) = print(io, d.code, ": ", d.message)

@with_kw_noshow struct PDDLicaDocument
    format::String = "pddlica-json"
    version::String = "0.1"
    language::Dict{String,Any} = Dict{String,Any}(
        "name" => "pddlica", "version" => "0.5",
        "host_language" => "pddl", "host_features" => String[])
    domain::Dict{String,Any} = Dict{String,Any}()
    problem::Dict{String,Any} = Dict{String,Any}()
    source_map::Dict{String,Any} = Dict{String,Any}(
        "documents" => Any[], "locations" => Dict{String,Any}())
    metadata::Dict{String,Any} = Dict{String,Any}(
        "producer" => "pddlica-parser-julia",
        "producer_version" => "0.1.0", "extensions" => Dict{String,Any}())
end

@with_kw_noshow struct ParseResult
    document::Union{Nothing,PDDLicaDocument} = nothing
    diagnostics::Vector{Diagnostic} = Diagnostic[]
end
Base.isempty(r::ParseResult) = isnothing(r.document)

@with_kw_noshow struct PlanOccurrence
    id::String = ""
    time::Float64 = 0.0
    kind::Symbol = :action
    schema_id::String = ""
    name::String = ""
    owner::Vector{String} = String[]
    arguments::Vector{Any} = Any[]
    duration::Union{Nothing,Float64} = nothing
end

@with_kw_noshow struct PlanDocument
    format::String = "pddlica-plan"
    version::String = "0.1"
    model_digest::String = ""
    horizon::Float64 = 0.0
    occurrences::Vector{PlanOccurrence} = PlanOccurrence[]
    metadata::Dict{String,Any} = Dict{String,Any}(
        "producer" => "user", "producer_version" => "0.1.0",
        "extensions" => Dict{String,Any}())
end

@with_kw_noshow struct ComponentInstance
    path::Vector{String} = String[]
    component_type::String = ""
    parent::Union{Nothing,String} = nothing
    ports::Dict{String,Dict{String,Any}} = Dict{String,Dict{String,Any}}()
end

@with_kw_noshow struct ElaboratedModel
    document::PDDLicaDocument = PDDLicaDocument()
    digest::String = ""
    components::Dict{String,ComponentInstance} = Dict{String,ComponentInstance}()
    component_types::Dict{String,Dict{String,Any}} = Dict{String,Dict{String,Any}}()
    connector_types::Dict{String,Dict{String,Any}} = Dict{String,Dict{String,Any}}()
    behaviors::Dict{String,Dict{String,Any}} = Dict{String,Dict{String,Any}}()
    initial_values::Dict{String,Any} = Dict{String,Any}()
    initial_presence::Dict{String,Bool} = Dict{String,Bool}()
    connection_sets::Vector{Vector{String}} = Vector{String}[]
    goal::Any = Dict{String,Any}("kind" => "boolean", "value" => true)
    provenance::Dict{String,Any} = Dict{String,Any}()
end

@with_kw_noshow struct ElaborationResult
    model::Union{Nothing,ElaboratedModel} = nothing
    diagnostics::Vector{Diagnostic} = Diagnostic[]
end
Base.isempty(r::ElaborationResult) = isnothing(r.model)

@with_kw mutable struct RuntimeState
    time::Float64 = 0.0
    microstep::Int = 0
    values::Dict{String,Any} = Dict{String,Any}()
    interface::Dict{String,Float64} = Dict{String,Float64}()
    presence::Dict{String,Bool} = Dict{String,Bool}()
    boundary::Dict{String,Float64} = Dict{String,Float64}()
    history::Dict{String,Float64} = Dict{String,Float64}()
end

@with_kw struct SimulationOptions
    relative_tolerance::Float64 = 1e-9
    absolute_tolerance::Float64 = 1e-9
    event_tolerance::Float64 = 1e-10
    max_event_layers::Int = 1000
    max_internal_steps::Int = 1_000_000
    save_everystep::Bool = false
    trajectory_interval::Union{Nothing,Float64} = 0.1
end

@with_kw_noshow struct VariableTrajectory
    name::String = ""
    kind::Symbol = :stored
    times::Vector{Float64} = Float64[]
    values::Vector{Any} = Any[]
    phases::Vector{Symbol} = Symbol[]
end

@with_kw_noshow struct SimulationResult
    status::Symbol = :ERROR
    plan::Union{Nothing,PlanDocument} = nothing
    terminal_state::Union{Nothing,RuntimeState} = nothing
    steps::Vector{Dict{String,Any}} = Dict{String,Any}[]
    trajectories::Dict{String,VariableTrajectory} = Dict{String,VariableTrajectory}()
    diagnostics::Vector{Diagnostic} = Diagnostic[]
    metadata::Dict{String,Any} = Dict{String,Any}()
end
