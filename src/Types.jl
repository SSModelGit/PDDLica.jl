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
    open_duratives::Dict{String,Any} = Dict{String,Any}()
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

abstract type AbstractOptimizerBackend end

@with_kw_noshow struct NativeSearchBackend <: AbstractOptimizerBackend
    name::String = "native-search"
end

@with_kw_noshow struct HybridMILPBackend <: AbstractOptimizerBackend
    name::String = "hybrid-milp-highs"
end

@with_kw struct OptimizationOptions
    max_macrosteps::Int = 6
    max_makespan::Float64 = 10.0
    time_step::Union{Nothing,Float64} = nothing
    max_simultaneous_actions::Int = 2
    max_candidates::Int = 100_000
    time_limit_seconds::Union{Nothing,Float64} = nothing
    iterative_deepening::Bool = true
    candidate_preference::Symbol = :first_feasible
    validate_candidates::Bool = true
    random_seed::Int = 0
    simulation_options::SimulationOptions = SimulationOptions()
end

@with_kw struct HybridMILPOptions
    steps::Int = 10
    makespan::Float64 = 10.0
    max_simultaneous_actions::Int = 2
    numeric_bound::Float64 = 10_000.0
    numeric_bounds::Dict{String,Tuple{Float64,Float64}} =
        Dict{String,Tuple{Float64,Float64}}()
    strict_epsilon::Float64 = 1e-7
    objective::Symbol = :source_metric_or_actions
    time_limit_seconds::Union{Nothing,Float64} = nothing
    mip_relative_gap::Union{Nothing,Float64} = nothing
    silent::Bool = true
    simulation_options::SimulationOptions = SimulationOptions()
end

@with_kw_noshow struct CapabilityReport
    supported::Bool = true
    backend::String = ""
    profile::String = "finite-grounded-hybrid-search-0.1"
    restrictions::Vector{String} = String[]
    diagnostics::Vector{Diagnostic} = Diagnostic[]
    details::Dict{String,Any} = Dict{String,Any}()
end

@with_kw_noshow struct OptimizationResult
    status::Symbol = :BACKEND_ERROR
    backend::String = ""
    capability::CapabilityReport = CapabilityReport()
    plan::Union{Nothing,PlanDocument} = nothing
    validation::Union{Nothing,SimulationResult} = nothing
    objective::Union{Nothing,Dict{String,Any}} = nothing
    diagnostics::Vector{Diagnostic} = Diagnostic[]
    statistics::Dict{String,Any} = Dict{String,Any}()
    metadata::Dict{String,Any} = Dict{String,Any}()
end
