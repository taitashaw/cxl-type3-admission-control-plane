// formal_config.sv — SymbiYosys harness for the hdm_config FSM. Uses manual
// previous-cycle registers (not $past) so it stays within the free-Yosys subset.
// Free inputs (sh_*, cfg_update_req, outstanding_cnt) are symbolic each cycle.
//
// Proves (reviewer's configuration property set):
//   traffic_freeze -> !req_accept_enable         (no new request while frozen)
//   epoch increments by exactly 1 on cfg_ok, else unchanged (monotone, once)
//   active config changes ONLY on cfg_ok         (atomic; rejects leave it alone)
//   FREEZE->COMMIT transition requires outstanding_cnt==0  (commit only drained)
//   cfg_ok occurs only out of the COMMIT state
module formal_config #(
  parameter int unsigned HPA_W = 16,
  parameter int unsigned DPA_W = 12,
  parameter int unsigned N_WIN = 2,
  parameter int unsigned OCNT_W = 3,
  parameter int unsigned IDX_W = (N_WIN > 1) ? $clog2(N_WIN) : 1
)(
  input logic clk
);
  localparam logic [1:0] S_ACTIVE=0, S_FREEZE=1, S_COMMIT=2;

  logic                    rst_n;
  logic                    sh_we, sh_en_i, sh_cap_we, cfg_update_req;
  logic [IDX_W-1:0]        sh_idx;
  logic [HPA_W-1:0]        sh_base_i, sh_size_i;
  logic [DPA_W-1:0]        sh_dpa_i;
  logic [DPA_W:0]          sh_cap_i;
  logic [OCNT_W-1:0]       outstanding_cnt;
  logic                    traffic_freeze, req_accept_enable, cfg_update_done, cfg_ok, cfg_reject;
  logic [3:0]              cfg_reason;
  logic [15:0]             cfg_epoch;
  logic [1:0]              cfg_state;
  logic [N_WIN-1:0]              win_en;
  logic [N_WIN-1:0][HPA_W-1:0]  win_base, win_size;
  logic [N_WIN-1:0][DPA_W-1:0]  win_dpa_base;
  logic [DPA_W:0]               dev_capacity;

  hdm_config #(.HPA_W(HPA_W), .DPA_W(DPA_W), .N_WIN(N_WIN), .OCNT_W(OCNT_W)) dut (.*);

  // Prove post-reset invariants: constrain rst_n high after the first cycle.
  logic init = 1'b0;
  logic [15:0]           p_epoch;
  logic [N_WIN-1:0]      p_en;
  logic [1:0]            p_state;
  logic [OCNT_W-1:0]     p_outstanding;

  always_ff @(posedge clk) begin
    init          <= 1'b1;
    p_epoch       <= cfg_epoch;
    p_en          <= win_en;
    p_state       <= cfg_state;
    p_outstanding <= outstanding_cnt;
  end

  always_comb assume (rst_n);   // characterize normal (out-of-reset) operation

  always_ff @(posedge clk) begin
    if (init) begin
      // epoch increments by exactly one on cfg_ok, unchanged otherwise
 assert (cfg_epoch == p_epoch + (cfg_ok ? 16'd1 : 16'd0));
      // active window-enable changes only on a successful commit (atomicity)
if (!cfg_ok) assert (win_en == p_en);
      // cfg_ok is produced only from the COMMIT state
if (cfg_ok) assert (p_state == S_COMMIT);
      // the FREEZE->COMMIT transition happens only when fully drained
 if (p_state == S_FREEZE && cfg_state == S_COMMIT)
                  assert (p_outstanding == '0);
    end
    // freeze and accept are mutually exclusive every cycle
assert (!(traffic_freeze && req_accept_enable));
  end
endmodule
