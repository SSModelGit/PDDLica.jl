module PDDLica

using Reexport
@reexport using Parameters
@reexport using Match

using Dates
using JSON3
using LinearAlgebra
using ModelingToolkit
using OrdinaryDiffEq
using SHA
using StructTypes
using UnicodePlots

include("Types.jl")
include("Interchange.jl")
include("Parsing.jl")
include("Elaboration.jl")
include("Simulation.jl")
include("Trajectories.jl")
include("CLI.jl")

export Diagnostic, SourceSpan, ParseResult, ElaborationResult,
       PDDLicaDocument, PlanDocument, PlanOccurrence, SimulationOptions,
       SimulationResult, VariableTrajectory, ElaboratedModel, RuntimeState,
       parse_model, elaborate, simulate,
       read_pddlica_json, write_pddlica_json,
       read_plan_json, write_plan_json, write_execution_json,
       canonical_json, semantic_digest,
       available_variables, trajectory, plot_trajectory, plot_trajectories,
       run_cli

end
