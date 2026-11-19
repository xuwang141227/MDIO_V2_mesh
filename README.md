# MDIO_V2_mesh

MDIO Clause 22/Clause 45 passthrough for 9 host ports and 10 PHY ports.

## RTL and configuration

`mdio_passthrough.v` routes the host selected by `host_sel[3:0]` (valid values
0–8) to enabled PHY ports. Each PHY uses a 16-bit compile-time configuration:
bit 15 enables the port, and bits 8:0 select its host. The default mapping
assigns PHY ports 0–3 to host 0, ports 4–7 to host 8, and disables ports 8–9.
Invalid host maps (zero or more than one selected host) are not routed.
Override `SLAVE0_CFG` through `SLAVE9_CFG` when instantiating the module to use a
different fixed mapping.

## ModelSim simulation

Run `do run.do` in ModelSim. The testbench writes and reads one Clause 45
register on PHY ports 0–7, using host 0 for ports 0–3 and host 8 for ports 4–7.
