# PDDLica.jl: Project and Status Overview

This document is a short refresher on what PDDLica is, what this repository can
currently do, and what remains to reach the intended system. It is also meant
to provide enough context to begin a new development conversation without
reconstructing the project's history.

> **Status snapshot (September 2026):** The parser, JSON interchange,
> elaborator, simulator, plotting helpers, and bounded optimization backends
> form a working development vertical slice. The shared finite-domain/PCTA
> compilation layer is the next major architectural addition and does not yet
> exist in this repository.

## What PDDLica is trying to do

PDDLica extends PDDL with ideas from Modelica and hybrid-system modeling. The
goal is to describe a planning problem and the physical system in which that
problem occurs in one model.

In addition to ordinary PDDL objects, predicates, actions, and goals, PDDLica
introduces:

- components with local variables, methods, processes, and events;
- hierarchical assemblies made from subcomponents;
- typed ports and acausal connections between ports;
- potential and flow variables with connection equations;
- continuous change alongside discrete actions;
- component creation, removal, and retained state; and
- simulation traces that expose how variables change over time.

The two main end-user capabilities are:

1. **Simulation:** Given a model, initial conditions, and a supplied sequence of
   actions, calculate the resulting hybrid trajectory and decide whether the
   plan is valid.
2. **Planning/optimization:** Find a feasible, preferably good or optimal,
   sequence and timing of actions that reaches the goal.

The emphasis is practical model execution and plan discovery. An optimizer's
solution is always replayed through the independent simulator; the project is
not trying to provide a global mathematical proof about every unrestricted
horizon and every possible execution.

## Current architecture

The implemented path is:

```text
.plca domain and problem
        |
        v
PDDLica parser and PDDLica-JSON 0.1
        |
        v
semantic elaboration and hierarchy flattening
        |
        +-----------------------+
        |                       |
        v                       v
plan-driven simulator     bounded optimizer
                                |
                                v
                         simulator replay
```

PDDLica-JSON is the source-oriented interchange representation. Elaboration
then resolves names and types, instantiates component hierarchies, constructs
connection sets, grounds stored state, and produces an `ElaboratedModel` used
by execution code.

## What is implemented now

### Parsing and interchange

- Native Julia parsing of `.plca` domain and problem files.
- A versioned PDDLica-JSON representation with readers, writers,
  canonicalization, and semantic digests.
- JSON formats for plans, diagnostics, executions, and optimization results.
- Source support for the main PDDL/PDDL+ features used by the project,
  including typed objects, Boolean/numeric/object fluents, actions, durative
  actions, quantified and conditional constructs, events, processes, timed
  initial literals, derived predicates, and PDDL3 constraints/preferences.
- PDDLica component, hierarchy, port, connection, and lifecycle syntax.

The parser accepts a broader language than every backend can execute. Backend
capability restrictions are therefore part of the current design.

### Elaboration

- Name and type checking over a finite object universe.
- Flattening of root components and nested subcomponents into stable paths.
- Resolution of component-local variables, methods, ports, and connections.
- Construction of merged connection sets.
- Initialization and presence tracking for components and stored values.
- Diagnostics for malformed hierarchies, types, interfaces, and initialization.

### Simulation

- Execution of supplied instantaneous and durative plans.
- Concurrent happenings with conflict checking and atomic discrete effects.
- Urgent event closure, timed initial literals, and continuous processes.
- Affine continuous dynamics and linear acausal connector systems.
- Potential equality, flow conservation, optional-port boundary behavior, and
  component removal/reactivation with retained state.
- Goal, durative-condition, requirement, and PDDL3 trajectory validation.
- Execution traces containing semantic boundaries and sampled time series.
- REPL helpers such as `available_variables`, `trajectory`,
  `plot_trajectory`, and `plot_trajectories`.

The simulator's main restriction is that active connector/interface systems
must be affine and have a unique solution. Nonlinear interfaces and some
connector-dependent equation branching are not yet executable.

### Planning and optimization

Two backends currently exist:

- The default JuMP/HiGHS backend constructs a bounded, fixed-grid hybrid MILP.
  It supports finite grounded controls, affine numeric dynamics, discrete
  state, component lifecycle, linear connector equations, bounded event
  closure, and several PDDL3 constructs.
- The native-search fallback enumerates bounded action happenings and validates
  candidates with the simulator. It is useful when direct MILP transcription
  is unsuitable, but scales poorly.

The MILP backend can return an optimal solution for the configured grid,
horizon, bounds, and transcription. That is not a claim of global optimality
for the unrestricted PDDLica problem. Every returned candidate is replayed by
the simulator, and a mismatch is rejected as an invalid witness.

### Examples and user interfaces

The repository includes small reference models as well as hierarchical hybrid
examples, including pumped fluid transfer, coupled tanks, thermal zones, and a
satellite model. CLI commands cover parsing, checking, inspection, simulation,
capability reporting, and optimization.

## What remains for PDDLica's main goals

The repository has a functional vertical slice, but it is still marked
`1.0.0-DEV`. Important remaining work includes:

- introduce the finite-domain constraint/PCTA layer described below;
- make the simulator and optimizer consume one shared compiled semantic model
  instead of independently rediscovering state structure;
- improve optimizer scalability through state compression, reachability
  pruning, and better grounding;
- add event-indexed or variable-time optimization so important event times do
  not have to lie on a fixed grid;
- broaden nonlinear continuous and acausal equation support;
- improve structural analysis for equation systems whose active branch depends
  on connector values;
- tighten capability reporting so documentation, analysis, and actual backend
  behavior cannot drift apart;
- extend diagnostics, performance testing, and larger realistic examples; and
- eventually add graphical component assembly and richer plotting if those
  remain project goals.

The present implementation is therefore best described as an executable
linear-hybrid PDDLica profile, not yet the final unrestricted language runtime.

## PCTAs and why they are relevant

Here **PCTA** means *Parameterized Concurrent Timed Automata*, following the
ctBurton work. A PCTA represents a system as concurrent finite-state component
automata. Each automaton has a finite-valued location variable, while guards,
clocks, parameters, and transitions describe how its value changes over time.

This is useful because traditional PDDL often spreads one conceptual state
across several mutually exclusive Boolean atoms. For example:

```text
(unlit match-1), (burning match-1), (spent match-1)
```

can instead be represented as one variable:

```text
match-1.combustion-mode in {unlit, burning, spent}
```

This is easier to trace, visualize, and encode in a constraint optimizer.

The separate `asktim` project demonstrates the intended transformation for
temporal PDDL:

```text
PDDL -> invariant synthesis -> finite-domain variables -> PCTA artifacts
```

Its most useful idea for PDDLica is the intermediate finite-domain constraint
model, not the final ctBurton-specific artifact. Proven mutex families become
finite-domain variables, while an atom index preserves the mapping between
original PDDL propositions and compact variable assignments.

## How PDDLica interfaces with PCTAs today

There is currently **no native PCTA compiler, PCTA JSON reader/writer, invariant
synthesizer, or PCTA execution backend in PDDLica.jl**.

The present interface is indirect and mostly contractual:

- The design identifies PDDLica-JSON as the intended external model boundary,
  but this repository does not yet ship a PDDLica-JSON-to-`asktim`/PCTA adapter.
- An external system can return an ordinary PDDLica plan JSON document.
- PDDLica.jl can replay that plan through its simulator and validate it.

The Julia implementation does not currently depend on `asktim` or ctBurton.
The existing simulator and MILP optimizer operate directly on
`ElaboratedModel`, so they do not yet benefit from mutex-based state
compression.

## Proposed PCTA/constraint integration

The intended revised pipeline is:

```text
.plca
  -> PDDLica-JSON
  -> semantic elaboration
  -> PDDLica hybrid constraint model
       - finite-domain mode variables
       - numeric continuous variables
       - algebraic connector variables/equations
       - grouped action/event/process transitions
       - original-atom <-> variable/value index
  -> simulator and optimizer
  -> optional PCTA export/visualization
```

The missing implementation work is:

1. Define the secondary hybrid constraint IR and its optional JSON/debug form.
2. Convert explicit object-valued component modes directly into finite-domain
   variables.
3. Synthesize safe mutex families from ordinary Boolean predicates, with a
   Boolean fallback whenever a candidate cannot be established.
4. Preserve a bidirectional atom index so existing PDDL formulas and readable
   diagnostics retain their original meaning.
5. Represent actions, methods, durative phases, events, and processes as
   grouped transitions over this common state model.
6. Retain PDDLica's continuous states and connector equations beside the
   discrete automata; these cannot be reduced to ordinary finite-state PCTAs.
7. Adapt the simulator and MILP compiler to consume the common model.
8. Optionally emit PCTA artifacts for inspection or external planners, without
   making ctBurton a required dependency.

This produces a **PCTA-inspired hybrid constraint IR** rather than forcing the
whole of PDDLica into a purely finite-state formalism. Component modes and
mutually exclusive predicates become automaton locations; continuous process
states and acausal connector equations remain hybrid numeric constraints.

## Quick starting points for future work

- `README.md` -- current commands and end-user examples.
- `literature/pddlica-julia-implementation-design.md` -- detailed architecture
  and language/runtime decisions.
- `src/Types.jl` -- public data structures.
- `src/Parsing.jl` and `src/Interchange.jl` -- `.plca` and JSON front ends.
- `src/Elaboration.jl` -- semantic model construction.
- `src/Simulation.jl` -- normative execution and validation.
- `src/OptimizationTranscription.jl` and `src/MILPOptimization.jl` -- current
  grounding and fixed-grid MILP formulation.
- `src/Trajectories.jl` -- REPL time-series access and plots.
- `examples/` -- executable models, plans, and expected results.
