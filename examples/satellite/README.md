# Hierarchical IPC Satellite adaptation

The classical IPC Satellite domain requires an instrument to be calibrated,
turned toward an observation task, and used before data can be delivered. This
hybrid adaptation packages a battery, camera, and radio into one spacecraft.

The components share an acausal electrical power bus. While the camera is
imaging it draws power from the battery, the camera's image-progress process
advances continuously, and battery energy decreases through its own
component-local process. The optimizer must synthesize the nested method
sequence:

```text
calibrate camera -> begin image -> transmit completed image
```

The final method stops imaging atomically, preserving the required terminal
battery reserve.

With four one-second stages, HiGHS reports `OPTIMAL` with objective value `3`.
Independent replay finishes the image, records the global transmitted fact,
and retains eight units of battery energy.
