using PDDLica
using Test

const ROOT = normpath(joinpath(@__DIR__, ".."))

function load_example(name)
    dir = joinpath(ROOT, "examples", name)
    parsed = parse_model(joinpath(dir, "domain.plca"), joinpath(dir, "problem.plca"))
    @test isempty(parsed.diagnostics)
    elaborated = elaborate(parsed.document)
    @test isempty(elaborated.diagnostics)
    plan = read_plan_json(joinpath(dir, "plan.json"))
    parsed.document, elaborated.model, plan
end

@testset "PDDLica-JSON boundary" begin
    doc, _, _ = load_example("pumped_fluid")
    @test startswith(semantic_digest(doc), "sha256:")
    io = IOBuffer()
    write_pddlica_json(io, doc)
    seekstart(io)
    loaded = read_pddlica_json(io)
    @test isempty(loaded.diagnostics)
    @test loaded.document.domain["name"] == "pumped-fluid"
    @test semantic_digest(loaded.document) == semantic_digest(doc)
end

@testset "Parser diagnostics" begin
    bad = parse_model("(define (domain broken)", "(define (problem p) (:domain broken))")
    @test isnothing(bad.document)
    @test !isempty(bad.diagnostics)
end

@testset "Linear hybrid examples" begin
    for name in ("pumped_fluid", "cushing", "match_ms", "match_ac", "oversub")
        _, model, plan = load_example(name)
        result = simulate(model, plan)
        @test result.status == :VALID
        @test isempty(result.diagnostics)
        @test result.terminal_state.time ≈ plan.horizon
        @test !isempty(result.steps) || isempty(plan.occurrences)
    end
end

@testset "Useful behavior, not internal representation" begin
    _, model, plan = load_example("pumped_fluid")
    result = simulate(model, plan)
    @test result.terminal_state.values["destination.volume"] ≈ 5 atol=1e-6
    @test result.terminal_state.interface["destination.inlet.mass-flow"] ≈ 1 atol=1e-6

    @test "destination.volume" in available_variables(result)
    @test "destination.inlet.mass-flow" in available_variables(result; kind=:interface)
    volume = trajectory(result, "destination.volume")
    @test first(volume.values) ≈ 0
    @test last(volume.values) ≈ 5 atol=1e-6
    @test length(volume.times) > 10
    @test occursin("destination.volume", sprint(show,
        plot_trajectory(result, "destination.volume"; width=40, height=8)))

    # Repeating switch-on is rejected by semantics, independently of struct layout.
    repeated = PlanDocument(horizon=2.0, occurrences=[plan.occurrences[1],
        PlanOccurrence(id="occ/bad", time=1.0, kind=:method,
            schema_id=plan.occurrences[1].schema_id, name="switch-on", owner=["transfer"])])
    invalid = simulate(model, repeated)
    @test invalid.status == :INVALID
end
