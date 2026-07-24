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

The native feasibility backend can synthesize a valid plan for every example.
The JuMP/HiGHS MILP backend handles `pumped_fluid`, `cushing`, `match_ac`, and
`oversub`; `match_ms` deliberately exercises an autonomous event and therefore
uses the native backend until event layers are included in the MILP
transcription. `cushing` requires two methods in one simultaneous happening;
`match_ac` correctly produces an empty controller plan because its continuous
acausal model reaches the goal without an action.
