// cxl_types_pkg.sv
// Project-owned, vendor-neutral parameter/type definitions for the CXL Type-3
// memory-expansion VALIDATION PLATFORM that sits AFTER the licensed CXL IP
// boundary. These are internal abstraction types only — they are NOT the CXL
// external wire protocol and make no CXL-compliance claim.
//
// Synthesizable, Verilator- and Icarus(-g2012)-clean. No unpacked-array ports
// are used across module boundaries (packed 2-D vectors instead) so both the
// free simulators and Vivado/XSim accept the same source.
`ifndef CXL_TYPES_PKG_SV
`define CXL_TYPES_PKG_SV

package cxl_types_pkg;

  // ---- Global datapath geometry -------------------------------------------
  localparam int unsigned LINE_BYTES   = 64;            // 64-byte cache line
  localparam int unsigned LINE_OFF_W   = 6;             // log2(LINE_BYTES)
  localparam int unsigned DATA_W       = 512;           // 64B * 8
  localparam int unsigned BE_W         = DATA_W/8;      // 64-bit byte-enable

  // ---- Operation encoding (project-owned) ---------------------------------
  typedef enum logic [1:0] {
    OP_READ  = 2'b00,
    OP_WRITE = 2'b01,
    OP_MAINT = 2'b10   // maintenance / error-test transaction
  } cxl_op_e;

  // ---- Completion / error status (project-owned) --------------------------
  typedef enum logic [2:0] {
    CPL_OK          = 3'b000,
    CPL_DECODE_MISS = 3'b001,   // no enabled HDM window matched
    CPL_UNALIGNED   = 3'b010,   // request not 64B-aligned
    CPL_DPA_OOB     = 3'b011,   // translated DPA outside device range
    CPL_XLATE_OVF   = 3'b100,   // translation arithmetic overflow
    CPL_POISON      = 3'b101,   // poison propagated
    CPL_TIMEOUT     = 3'b110,   // outstanding-tracker timeout
    CPL_ERROR       = 3'b111    // generic/uncorrectable
  } cxl_cpl_e;

  // Helper: is an HPA 64-byte aligned? Takes a generic 64-bit address; only the
  // low LINE_OFF_W bits matter, so the upper bits are intentionally unread.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic is_line_aligned(input logic [63:0] addr);
    return (addr[LINE_OFF_W-1:0] == '0);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

endpackage : cxl_types_pkg

`endif
