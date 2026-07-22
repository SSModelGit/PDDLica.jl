# PDDLica.jl

PDDLica.jl parses the component-oriented PDDLica language into the versioned
PDDLica-JSON surface IR, elaborates component assemblies, and simulates supplied
plans with discrete actions, urgent events, continuous processes, and linear
acausal connector equations.

The current implementation is a deliberately useful linear-hybrid slice. It
does not search for plans and does not claim support for every inherited
PDDL2.1/PDDL+/PDDL3 construct represented by the interchange format.

```julia
using PDDLica

parsed = parse_model("domain.plca", "problem.plca")
checked = elaborate(parsed.document)
plan = read_plan_json("plan.json")
result = simulate(checked.model, plan)
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
