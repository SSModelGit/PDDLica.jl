# Lifecycle and retained state

The `memory` component is assigned a stored value, removed from the active
assembly, and later reactivated. While it is absent, the remaining optional
port is a valid singleton with zero flow and a uniquely defined potential.
Reactivation restores the immutable connection and the memory component keeps
its stored value.

This example is executable by the simulator and native-search backend. The
fixed-grid MILP backend reports lifecycle effects as unsupported until presence
and optional-boundary memory are included in its transcription.
