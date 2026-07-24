# Hierarchical coupled-tank plant

This example adapts the coupled-tank and fluid-transfer systems commonly used
in Modelica introductory and control examples.

`two-tank-plant` is a composite component containing two storage tanks and a
controllable valve. Internal fluid connectors impose pressure equality and
inward-positive flow conservation. Tank volume evolves through component-local
processes. The optimizer must select the nested valve's `open` method so that
four units of fluid reach the receiving tank within four seconds.

The expected optimal fixed-grid plan contains one method:

```text
t=0  plant.transfer.open
```

With four one-second stages, HiGHS reports `OPTIMAL` with objective value `1`.
The recovered plan is replayed through the adaptive simulator and transfers
four units while retaining six in the supply tank.
