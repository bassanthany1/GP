// ============================================================
// systolic_if.sv
// Physical interface between UVM env and the DUT.
// Parameters MUST match DUT parameters.
// ============================================================

interface systolic_if #(
    parameter int DW = 8,    // DATAWIDTH
    parameter int M  = 4,
    parameter int K  = 256,
    parameter int N  = 4
) (
    input logic clk
);

  // ── Signals ──────────────────────────────────────────────
  logic                          rst;
  logic                          load_data;
  logic        [$clog2(K+1)-1:0] k_size;
  logic signed [     M*K*DW-1:0] a_flat;
  logic signed [     K*N*DW-1:0] b_flat;
  logic                          valid_out;
  logic signed [   M*N*4*DW-1:0] c_flat;

  // ── Driver clocking block ─────────────────────────────────
  // Driver WRITES on @(cb_drv) — outputs update at the clock edge.
  // Monitor samples inputs one time unit later, avoiding clocking races.
  clocking cb_drv @(posedge clk);
    default input #1 output #0;
    output rst;
    output load_data;
    output k_size;
    output a_flat;
    output b_flat;
    input valid_out;
  endclocking

  // ── Monitor clocking block ────────────────────────────────
  // Monitor READS on @(cb_mon) — all signals are inputs.
  clocking cb_mon @(posedge clk);
    default input #1;
    input rst;
    input load_data;
    input k_size;
    input a_flat;
    input b_flat;
    input valid_out;
    input c_flat;
  endclocking

  // ── Modports ─────────────────────────────────────────────
  modport drv_mp(clocking cb_drv, input clk);
  modport mon_mp(clocking cb_mon, input clk);

  // ── Assertions ────────────────────────────────────────────
  // Industry practice: put protocol assertions in the interface
  // so they fire regardless of which test is running.

  // k_size must never be zero when load_data is asserted
  AP_KSIZE_NONZERO :
  assert property (@(posedge clk) disable iff (rst) (load_data |-> k_size > 0))
  else $error("IF_ASSERT", "load_data asserted with k_size==0!");

  // valid_out should be exactly 1 cycle wide
  AP_VALID_PULSE :
  assert property (@(posedge clk) disable iff (rst) (valid_out |=> !valid_out))
  else $error("IF_ASSERT", "valid_out held for >1 cycle!");

endinterface