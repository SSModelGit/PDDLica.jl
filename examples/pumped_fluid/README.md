# Pumped fluid transfer

This example is the first executable PDDLica vertical slice. Two tank
components are connected through a pump using acausal pressure/flow ports. The
supplied plan starts the pump and lets the component processes transfer five
units of volume over five seconds.

Run with:

```sh
julia --project=. bin/pddlica simulate examples/pumped_fluid/domain.plca \
  examples/pumped_fluid/problem.plca examples/pumped_fluid/plan.json
```
