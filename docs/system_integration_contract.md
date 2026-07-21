# M8 Design Contract — System Integration & CXL Type-3 Emulation

Wire the verified blocks into a two-clock-domain `system_top`, and add the
**QEMU CXL Type-3 SOFTWARE_EMULATED** capture-and-replay lane. This milestone's
deliverable is as much *result-class discipline* as it is RTL: it states exactly
what is proven, what is simulated, what is software-emulated, and what stays
BLOCKED.

## 1. System datapath

```
 link/front-end clock domain                 memory/back-end clock domain
 ---------------------------                  ----------------------------
 hdm_decode_top  (address window decode, fail-closed)
      |
 control_plane_top  (admission + credit + atomic config, epoch capture)
      |  admitted {tag,write,addr,wdata}
      v
 async_fifo (M7 CDC bridge, WIDTH = admitted-request width)  ===>  mem_subsys_top
                                                                     (rw_scheduler + mem_backend)
                                                                            |  {tag,rdata} response
 response egress  <===  async_fifo (M7 CDC recross)  <=======================
```
The CDC bridge sits at the **admission -> scheduler seam** (approved Best-Route
choice): the FIFO is exercised in-system under real backpressure and flow
control, not just as a standalone library block.

## 2. `system_top` interface (sketch)

```
system_top #(...params...)
( input  logic link_clk, link_rst_n,
  input  logic mem_clk,  mem_rst_n,
  // front-end request / config in (link domain) ... reuses control_plane_top ports
  // response out (link domain) ... {valid,ready,tag,rdata}
  // flat dbg_* pass-throughs for integration assertions
);
```
Both CDC bridges use `async_fifo`; `mem_subsys_top` runs on `mem_clk`; the
control plane runs on `link_clk`.

## 3. What is proven vs demonstrated (result-class table)

| Property | Result class | Mechanism |
|----------|--------------|-----------|
| Each seam handshake: no valid dropped, no double-accept | FORMAL (induction) | boundary assertions in `system.sby` |
| CDC bridge: no overflow/underflow, data integrity across the crossing | FORMAL (induction) | composed from M7 `async_fifo` proof |
| Per-block safety (decode fail-closed, admission conservation, scheduler per-address order, mem_subsys read-after-write) | FORMAL (induction) | **composed** from M1-M6 proofs, not re-proven monolithically |
| Full-system end-to-end read-after-write across two clock domains + reorder | RTL_SIMULATED | differential sweep + QEMU replay; **NOT** claimed by induction (intractable monolithically; claiming it would be over-reach) |
| CXL Type-3 HDM/config programming-model semantics match a real software stack | SOFTWARE_EMULATED | QEMU capture-and-replay (below) |
| Liveness / eventual response | NOT CLAIMED | stalled domain clock or non-responding txn blocks drain |
| Silicon / PHY / link / bandwidth / latency / enumeration on real HW | BLOCKED | host has no CXL device; `/sys/bus/cxl` absent; no Quartus |

No BMC fallback for the FORMAL rows. The system-level formal claim is
deliberately modest (seam conformance + composed block proofs); end-to-end
functional correctness is honestly labeled RTL_SIMULATED + SOFTWARE_EMULATED.

## 4. QEMU CXL Type-3 lane (SOFTWARE_EMULATED) — capture and replay

Host QEMU 8.2.2 advertises `cxl-type3`. The lane (approved full-depth):
1. **Boot** a QEMU machine with a CXL Type-3 memory expander + CXL host bridge /
   root port / window, and a Linux guest (or QEMU monitor introspection).
2. **Capture** the HDM decoder / config register programming sequence that the
   CXL enumeration performs (HDM decoder base/size/ctrl writes, capacity, commit
   ordering) via QEMU tracing / guest `/sys/bus/cxl` + register dumps.
3. **Translate** the captured sequence into a differential vector file in the
   existing `hdm_config` / `hdm_decoder` stimulus format.
4. **Replay** those vectors against our `hdm_config` + `hdm_decoder` RTL and
   compare against the independent Python reference model, on both toolchains.

**Claim:** our RTL's HDM-decode/config *programming-model semantics* agree with
an independent CXL Type-3 software reference (SOFTWARE_EMULATED). This is a real
HW/SW co-verification of the programming model.

**Explicit non-claims:** the RTL is **not** executed inside QEMU; QEMU is an
independent reference, not a co-simulation. No silicon, PHY, link, DLL,
bandwidth, or latency claim. No real-hardware enumeration (BLOCKED). If QEMU on
this host cannot instantiate a `cxl-type3` topology, the lane is reported
BLOCKED with the exact error — never faked.

## 5. Mutation / validation targets
- System: drop a CDC-bridge handshake term -> request/response loss caught by
  the integration differential; misroute a domain-crossing pointer -> data
  integrity fails.
- QEMU lane: perturb a captured HDM window base/size in the replayed vector ->
  RTL decode diverges from the software-reference expectation (confirms the lane
  actually constrains the RTL, i.e. the replay is non-vacuous).

## 6. Verification lanes
Two-toolchain differential system sweep; SymbiYosys seam/composed proofs +
covers; sim + formal mutation; XSim third engine; QEMU SOFTWARE_EMULATED
capture-replay (or BLOCKED with log); exact-commit clean-clone under `env -i`.

## 7. Résumé-safe wording (to be finalized after runs)
"Integrated the decode / admission / scheduling / memory datapath across two
clock domains via a formally verified async-FIFO CDC bridge, and cross-checked
the CXL Type-3 HDM programming model against QEMU 8.2.2 by capturing and
replaying its enumeration register sequence against the RTL." No protocol / PHY /
silicon / bandwidth / tapeout claim.
