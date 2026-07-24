using PDDLica
using JSON3
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


@testset "PDDL3 validation features" begin
    domain = """
    (define (domain pddl3-check)
      (:requirements :typing :fluents :conditional-effects :derived-predicates
                     :durative-actions :continuous-effects :constraints :preferences)
      (:types item)
      (:predicates (marked ?x - item) (finished))
      (:functions (level) - number)
      (:derived (all-marked) (forall (?x - item) (marked ?x)))
      (:action mark-all :parameters () :precondition true
        :effect (forall (?x - item) (when (not (marked ?x)) (marked ?x))))
      (:durative-action raise
        :parameters ()
        :duration (= ?duration 2)
        :condition (and (at start (= (level) 0)) (over all (<= (level) 2)))
        :effect (and (increase (level) (* #t 1)) (at end (finished)))))
    """
    problem = """
    (define (problem pddl3-problem)
      (:domain pddl3-check)
      (:objects a b - item)
      (:init (= (level) 0))
      (:goal (and (all-marked) (finished)
                  (preference low-level (<= (level) 1))))
      (:constraints (and (sometime (all-marked))
                         (preference once (at-most-once (finished)))))
      (:metric minimize (+ (is-violated low-level) (is-violated once))))
    """
    parsed=parse_model(domain,problem)
    @test isempty(parsed.diagnostics)
    checked=elaborate(parsed.document)
    @test isempty(checked.diagnostics)
    plan=PlanDocument(horizon=2.0,occurrences=[
        PlanOccurrence(id="mark",time=0.0,schema_id="domain/action/mark-all",name="mark-all"),
        PlanOccurrence(id="raise",time=0.0,schema_id="domain/durative_action/raise",name="raise",duration=2.0)])
    result=simulate(checked.model,plan)
    @test result.status == :VALID
    @test result.terminal_state.values["level"] ≈ 2 atol=1e-6
    @test result.terminal_state.values["marked(a)"]
    @test result.terminal_state.values["marked(b)"]
    @test result.metadata["preference_violations"]["low-level"]
    @test result.metadata["metric_value"] ≈ 1

    synthesized=optimize(checked.model;backend=NativeSearchBackend(),
        max_steps=1,max_makespan=2.0,
        max_simultaneous_actions=2,max_candidates=20)
    @test synthesized.status==:FEASIBLE
    @test synthesized.validation.status==:VALID
    @test any(!isnothing(x.duration) for x in synthesized.plan.occurrences)
    @test synthesized.objective["value"]≈1
end

@testset "Concurrent numeric updates and timed initial effects" begin
    domain="""(define (domain updates)
      (:requirements :numeric-fluents :timed-initial-literals)
      (:functions (score) - number)
      (:action add :parameters () :precondition true :effect (increase (score) 1)))"""
    problem="""(define (problem updates-p) (:domain updates)
      (:init (= (score) 0) (at 1 (increase (score) 1)))
      (:goal (= (score) 3)))"""
    checked=elaborate(parse_model(domain,problem).document)
    plan=PlanDocument(horizon=1.0,occurrences=[
        PlanOccurrence(id="a",time=0.0,schema_id="domain/action/add",name="add"),
        PlanOccurrence(id="b",time=0.0,schema_id="domain/action/add",name="add")])
    result=simulate(checked.model,plan)
    @test result.status==:VALID
    @test result.terminal_state.values["score"]≈3
end

@testset "Grounded component-local fluents" begin
    domain="""(define (domain local-grounding)
      (:requirements :typing :numeric-fluents :components)
      (:types item - object)
      (:component sensor
        (:variables (reading ?x - item) - number)
        (:methods (:method set :parameters (?x - item) :precondition true
          :effect (assign (reading ?x) 1)))))"""
    problem="""(define (problem local-grounding-p) (:domain local-grounding)
      (:objects a b - item) (:components (s - sensor :present true))
      (:init (= (reading s a) 0) (= (reading s b) 0))
      (:goal (= (reading s a) 1)))"""
    checked=elaborate(parse_model(domain,problem).document)
    @test isempty(checked.diagnostics)
    plan=PlanDocument(horizon=0.0,occurrences=[PlanOccurrence(id="set-a",time=0.0,kind=:method,
        schema_id="domain/component/sensor/method/set",name="set",owner=["s"],
        arguments=[Dict{String,Any}("kind"=>"symbol","name"=>"a")])])
    result=simulate(checked.model,plan)
    @test result.status==:VALID
    @test result.terminal_state.values["s.reading(b)"]==0
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

    malformed=PDDLica.document_dict(doc)
    delete!(malformed["metadata"],"semantic_digest")
    malformed["domain"]["actions"]=Any[42]
    rejected=read_pddlica_json(IOBuffer(JSON3.write(malformed)))
    @test isnothing(rejected.document)
    @test any(d->occursin("actions[1]",d.message),rejected.diagnostics)

    diagnostics=[Diagnostic(code="PDDLICA-TEST",message="round trip",
        location=SourceSpan(document="domain",start_byte=1,end_byte=2))]
    io=IOBuffer()
    write_diagnostics_json(io,diagnostics;canonical=true)
    seekstart(io)
    restored=read_diagnostics_json(io)
    @test only(restored).code=="PDDLICA-TEST"
    @test only(restored).location.start_byte==1
end

@testset "Parser diagnostics" begin
    bad = parse_model("(define (domain broken)", "(define (problem p) (:domain broken))")
    @test isnothing(bad.document)
    @test !isempty(bad.diagnostics)

    legacy=parse_model("""(define (domain legacy)
      (:requirements :components)
      (:component-type old))""",
      "(define (problem p) (:domain legacy) (:goal true))")
    @test isnothing(legacy.document)
    @test occursin(":component-type",only(legacy.diagnostics).message)

    current=parse_model("""(define (domain current)
      (:requirements :components)
      (:component machine (:variables (level) - number)))""",
      """(define (problem p) (:domain current)
        (:components (m - machine)) (:init (= (level m) 0)) (:goal true))""")
    @test !isnothing(current.document)
    @test isempty(current.document.domain["types"])
    @test !isnothing(elaborate(current.document).model)
end

@testset "Linear hybrid examples" begin
    for name in ("pumped_fluid", "cushing", "match_ms", "match_ac", "oversub",
                 "lifecycle")
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

@testset "Feasible-plan synthesis and replay" begin
    for name in ("pumped_fluid","cushing","match_ms","match_ac","oversub")
        _,model,reference=load_example(name)
        result=optimize(model;backend=NativeSearchBackend(),
            options=OptimizationOptions(max_macrosteps=1,
            max_makespan=reference.horizon,max_simultaneous_actions=2,max_candidates=100))
        @test result.status==:FEASIBLE
        @test !isnothing(result.plan)
        @test result.validation.status==:VALID
        @test result.plan.horizon≈reference.horizon
    end

    _,model,_=load_example("pumped_fluid")
    bounded=optimize(model;backend=NativeSearchBackend(),
        options=OptimizationOptions(max_macrosteps=0,max_makespan=5.0))
    @test bounded.status==:NOT_FOUND
    @test isnothing(bounded.plan)
    @test occursin("not a proof",lowercase(only(bounded.diagnostics).notes[1]))

    limited=optimize(model;backend=NativeSearchBackend(),
        options=OptimizationOptions(max_macrosteps=1,
        max_makespan=5.0,max_candidates=1))
    @test limited.status==:RESOURCE_LIMIT
    bad_options=optimize(model;backend=NativeSearchBackend(),
        options=OptimizationOptions(max_macrosteps=-1))
    @test bad_options.status==:BACKEND_ERROR

    io=IOBuffer()
    write_optimization_result_json(io,bounded;canonical=true)
    @test occursin("\"status\":\"not_found\"",String(take!(io)))
end

@testset "Increasing-horizon action synthesis" begin
    domain="""(define (domain two-step)
      (:requirements :strips)
      (:predicates (ready) (done))
      (:action prepare :parameters () :precondition true :effect (ready))
      (:action finish :parameters () :precondition (ready) :effect (done)))"""
    problem="""(define (problem two-step-p) (:domain two-step)
      (:init) (:goal (done)))"""
    result=optimize(domain,problem;backend=NativeSearchBackend(),
        options=OptimizationOptions(max_macrosteps=2,
        max_makespan=2.0,max_simultaneous_actions=2,max_candidates=100))
    @test result.status==:FEASIBLE
    @test result.validation.status==:VALID
    @test [(x.time,x.name) for x in result.plan.occurrences]==[(0.0,"prepare"),(1.0,"finish")]
end

@testset "Hybrid MILP optimization and simulator replay" begin
    _,pumped,_=load_example("pumped_fluid")
    result=optimize(pumped;options=HybridMILPOptions(steps=5,makespan=5.0))
    @test result.status==:FEASIBLE
    @test result.backend=="hybrid-milp-highs"
    @test result.statistics["termination_status"]=="OPTIMAL"
    @test result.objective["optimal_within_unrolling"]
    @test result.validation.status==:VALID
    @test [(x.time,x.name) for x in result.plan.occurrences]==[(0.0,"switch-on")]

    _,acausal,_=load_example("match_ac")
    passive=optimize(acausal;options=HybridMILPOptions(steps=2,makespan=2.0))
    @test passive.status==:FEASIBLE
    @test isempty(passive.plan.occurrences)
    @test passive.validation.status==:VALID

    _,event_model,_=load_example("match_ms")
    unsupported=optimize(event_model;
        options=HybridMILPOptions(steps=2,makespan=2.0))
    @test unsupported.status==:UNSUPPORTED
    @test any(d->occursin("events",d.message),unsupported.diagnostics)

    affine_domain="""(define (domain affine-effect)
      (:requirements :strips :numeric-fluents)
      (:functions (level) - number)
      (:action double :parameters () :precondition true
        :effect (assign (level) (* 2 (level)))))"""
    affine_problem="""(define (problem affine-effect-p) (:domain affine-effect)
      (:init (= (level) 1)) (:goal (= (level) 2)))"""
    affine=optimize(affine_domain,affine_problem;
        options=HybridMILPOptions(steps=1,makespan=1.0))
    @test affine.status==:FEASIBLE
    @test only(affine.plan.occurrences).name=="double"
    @test affine.validation.terminal_state.values["level"]≈2

    til_domain="""(define (domain til-opt)
      (:requirements :numeric-fluents :timed-initial-literals)
      (:functions (x) - number))"""
    til_problem="""(define (problem til-p) (:domain til-opt)
      (:init (= (x) 0) (at 1 (assign (x) 1))) (:goal (= (x) 1)))"""
    til_model=elaborate(parse_model(til_domain,til_problem).document).model
    @test simulate(til_model,PlanDocument(horizon=1.0)).status==:VALID
    til_result=optimize(til_model;options=HybridMILPOptions(steps=1,makespan=1.0))
    @test til_result.status==:UNSUPPORTED
    @test any(d->occursin("timed initial",lowercase(d.message)),til_result.diagnostics)

    io=IOBuffer()
    write_optimization_result_json(io,result)
    seekstart(io)
    restored=read_optimization_result_json(io)
    @test restored.status==result.status
    @test restored.validation.status==:VALID
end

@testset "Hierarchy presence and interface rejection boundaries" begin
    _,lifecycle,lifecycle_plan=load_example("lifecycle")
    lifecycle_result=simulate(lifecycle,lifecycle_plan)
    @test lifecycle_result.status==:VALID
    @test lifecycle_result.terminal_state.values["memory-unit.stored"]==7
    @test lifecycle_result.terminal_state.presence["memory-unit"]
    removed=only(step for step in lifecycle_result.steps
        if get(step,"kind","")=="planned_happening" &&
           "remove" in get(step,"occurrence_ids",String[]))
    @test !removed["post_state"]["presence"]["memory-unit"]
    @test removed["post_state"]["interface"]["reference.terminal.flow"]≈0

    domain="""(define (domain hierarchy)
      (:requirements :components :component-presence :numeric-fluents)
      (:component leaf
        (:variables (value) - number)
        (:methods (:method touch :parameters () :precondition true
          :effect (assign (value) 1))))
      (:component assembly (:components (child - leaf)))
      (:action remove-root :parameters () :precondition true :effect (remove root)))"""
    problem="""(define (problem hierarchy-p) (:domain hierarchy)
      (:components (root - assembly))
      (:init (= (value root.child) 0))
      (:goal true))"""
    model=elaborate(parse_model(domain,problem).document).model
    plan=PlanDocument(horizon=1.0,occurrences=[
        PlanOccurrence(id="remove",time=0.0,schema_id="domain/action/remove-root",
            name="remove-root"),
        PlanOccurrence(id="touch",time=1.0,kind=:method,
            schema_id="domain/component/leaf/method/touch",name="touch",
            owner=["root","child"])])
    result=simulate(model,plan)
    @test result.status==:INVALID
    @test occursin("absent",only(result.diagnostics).message)

    connector_domain="""(define (domain branch-interface)
      (:requirements :components :acausal-connectors :numeric-fluents)
      (:connector-type pin (:potential v - number) (:flow f - number))
      (:component device
        (:ports (p) - pin :presence optional)
        (:requirement (= (v (p)) 0))
        (:requirement (imply (> (f (p)) 0) (= (v (p)) 1)))))"""
    connector_problem="""(define (problem branch-p) (:domain branch-interface)
      (:components (d - device)) (:init) (:goal true))"""
    branch=elaborate(parse_model(connector_domain,connector_problem).document).model
    unsupported=simulate(branch,PlanDocument(horizon=0.0))
    @test unsupported.status==:UNSUPPORTED
    @test any(d->d.code=="PDDLICA-SIM-IFACE-005",unsupported.diagnostics)

    nonlinear_domain=replace(connector_domain,
        "(:requirement (imply (> (f (p)) 0) (= (v (p)) 1)))"=>
        "(:requirement (= (* (f (p)) (v (p))) 0))")
    nonlinear=elaborate(parse_model(nonlinear_domain,connector_problem).document).model
    nonlinear_result=simulate(nonlinear,PlanDocument(horizon=0.0))
    @test nonlinear_result.status==:UNSUPPORTED
    @test any(d->d.code=="PDDLICA-SIM-IFACE-004",nonlinear_result.diagnostics)
end
