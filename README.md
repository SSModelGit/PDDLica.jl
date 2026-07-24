# PDDLica.jl

PDDLica.jl parses the component-oriented PDDLica language into the versioned
PDDLica-JSON surface IR, elaborates component assemblies, and simulates supplied
plans with discrete and durative actions, timed initial literals, urgent events,
continuous processes, PDDL3 validation constraints, and linear acausal
connector equations.

The simulator validates supplied plans independently of optimization. The
executable profile includes typed finite quantification, conditional
and quantified effects, derived predicates, concurrent happenings, durative
conditions/effects, trajectory constraints, preferences, and metric reporting.
Preferences and metrics are evaluated by the simulator and may be used by an
optimizer when its transcription supports them. Acausal interfaces remain
restricted to affine systems with a unique active solution.

The default optimizer unrolls a bounded horizon into a time-indexed hybrid MILP
using JuMP and solves it with HiGHS. Binary variables select grounded actions
and component methods; state variables and constraints encode discrete frame
conditions, affine process dynamics, component requirements, and linear
acausal connector equations. The recovered plan is always replayed through the
independent simulator:

```julia
result = optimize(checked.model;
    max_steps=10,
    max_makespan=10.0,
    max_simultaneous_actions=2)

result.status       # :FEASIBLE, :NOT_FOUND, :TIME_LIMIT, ...
result.plan         # ordinary PlanDocument when feasible
result.validation   # mandatory simulator replay
result.objective    # incumbent, bound, and MILP termination information
```

An `OPTIMAL` solver termination means optimal for the configured finite grid,
bounds, and supported transcription—not for every horizon or the unrestricted
PDDLica problem. `NOT_FOUND` likewise means the configured unrolling is
infeasible, not that the unrestricted problem is.

The initial MILP profile has static component presence and connection topology,
instantaneous actions/methods, affine expressions, and fixed-step process
transitions. Timed initial literals, autonomous events, durative actions,
conditional/quantified effects, and PDDL3 trajectory constraints are reported
as `UNSUPPORTED` rather than omitted. The capability report returned with every
result is the authoritative boundary.

The earlier simulator-driven enumerator remains available as a semantic
fallback for constructs not yet transcribed to MILP, including autonomous
events and durative actions:

```julia
result = optimize(checked.model;
    backend=NativeSearchBackend(),
    options=OptimizationOptions(max_macrosteps=4, max_makespan=10.0))
```

```julia
using PDDLica

parsed = parse_model("domain.plca", "problem.plca")
checked = elaborate(parsed.document)
plan = read_plan_json("plan.json")
result = simulate(checked.model, plan)

write_execution_json("execution.json", result)
restored = read_execution_json("execution.json")
```

Inspect and plot recorded time series directly in the Julia REPL:

```julia
available_variables(result)
series = trajectory(result, "destination.volume")
series = trajectory(result, "destination", "volume")

plot_trajectory(result, "destination.volume")
plot_trajectory(result, "destination", "volume")
plot_trajectories(result, ["source.volume", "destination.volume"])
```

Plots use UnicodePlots and therefore render in the terminal. Continuous values
are sampled every `0.1` model-time units by default, while action and event
boundaries retain duplicate pre/post timestamps. Configure the cadence with
`SimulationOptions(trajectory_interval=0.01)`, use `nothing` to retain only
semantic boundaries, or set `save_everystep=true` to retain solver steps.

Run the reference example:

```sh
julia --project=. bin/pddlica simulate \
  examples/pumped_fluid/domain.plca \
  examples/pumped_fluid/problem.plca \
  examples/pumped_fluid/plan.json
```

Optimize a plan from source with the default JuMP/HiGHS backend:

```sh
julia --project=. bin/pddlica optimize \
  examples/pumped_fluid/domain.plca \
  examples/pumped_fluid/problem.plca \
  --backend milp --max-steps 5 --makespan 5 --output optimization.json
```

Inspect a parsed model or report backend restrictions without starting a solve:

```sh
julia --project=. bin/pddlica check model.pddlica.json
julia --project=. bin/pddlica inspect model.pddlica.json
julia --project=. bin/pddlica capabilities domain.plca problem.plca \
  --backend milp --max-steps 5 --makespan 5
```
