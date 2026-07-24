# Hierarchical two-zone thermal system

This example follows the two-room thermal networks commonly modeled with
Modelica thermal capacitances, prescribed heat sources, and a conducting wall.

`building` contains two room capacitances, two controllable heaters, and a wall
conductor. Heat ports use temperature as a potential and heat flow as an
inward-positive flow. Room temperature evolves continuously from the sum of
heater and wall flows. The optimizer must turn on both nested heaters to bring
both zones from 18 to 20 degrees within two seconds.

The two heater methods form one simultaneous happening at `t=0`.

With two one-second stages, HiGHS reports `OPTIMAL` with objective value `2`.
Independent replay reaches exactly 20 degrees in each room.
