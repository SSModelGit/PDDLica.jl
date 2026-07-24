# Executable examples

`pumped_fluid` is based directly on the PDDLica fluid-transfer specification.
The `cushing`, `match_ms`, `match_ac`, and `oversub` directories are original,
component-oriented examples inspired by the benchmark families published in
the [PATTY collection](https://github.com/matteocarde/patty). No upstream model
text is copied here.

Every directory contains PDDLica domain and problem sources, a timestamped
plan, the generated PDDLica-JSON model, an execution trace, and a short note
describing the intended behavior.

`lifecycle` is the dedicated removal/reactivation witness. It checks optional
singleton interfaces and retained component-local state across absence.

The three larger optimizer examples exercise hierarchy, internal connections,
continuous component processes, and MILP plan synthesis in every model:

| Example | Community lineage | Optimized behavior |
| --- | --- | --- |
| `coupled_tanks` | Modelica fluid/control tutorials | open a nested transfer valve |
| `two_zone_thermal` | Modelica building/thermal networks | start two nested heaters concurrently |
| `satellite` | IPC Satellite planning domain | calibrate, image, then transmit |

These are independently written PDDLica adaptations rather than copied
benchmark sources. Each of the three directories also contains
`optimization.json`, recording the HiGHS model size, objective, solver
termination, recovered source plan, and independent simulator replay.

Both optimizer backends can synthesize a valid plan for every example.
`match_ms` exercises fixed-grid autonomous event closure in the JuMP/HiGHS
backend. `cushing` requires two methods in one simultaneous happening;
`match_ac` correctly produces an empty controller plan because its continuous
acausal model reaches the goal without an action.
