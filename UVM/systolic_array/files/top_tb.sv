// ============================================================
// systolic_tb_top.sv
// Non-UVM module. Glues interface ↔ DUT.
// Registers vif in config_db. Launches UVM via run_test().
// ============================================================
// `timescale 1ns/1ps
`include "uvm_macros.svh"
import uvm_pkg::*;

// Parameters (match DUT)
localparam int DW = 8;
localparam int M = 4;
localparam int K = 256;
localparam int N = 4;

module systolic_tb_top;

  import systolic_pkg::*;
  import uvm_pkg::*;


  // ── Clock generation ───────────────────────────────────────
  logic clk;
  initial clk = 0;
  always #5 clk = ~clk;  // 100 MHz

  // ── Interface instantiation ────────────────────────────────
  systolic_if #(DW, M, K, N) dut_if (.clk(clk));

  // ── DUT instantiation ──────────────────────────────────────
  // NOTE: Port names connect to the interface signals (not clocking blocks)
  systolic_full #(
      .DATAWIDTH(DW),
      .M(M),
      .K(K),
      .N(N)
  ) dut (
      .clk      (dut_if.clk),
      .rst      (dut_if.rst),
      .load_data(dut_if.load_data),
      .k_size   (dut_if.k_size),
      .a_flat   (dut_if.a_flat),
      .b_flat   (dut_if.b_flat),
      .valid_out(dut_if.valid_out),
      .c_flat   (dut_if.c_flat)
  );

  // ── Register virtual interface in config_db ────────────────
  // UVM_NULL_CONTEXT ("") means "available to entire hierarchy".
  // Driver and monitor call get(this, "", "vif", vif) to retrieve it.
  initial begin
      dut_if.rst       = 1'b1;
      dut_if.load_data = 1'b0;
      dut_if.k_size    = '0;
      dut_if.a_flat    = '0;
      dut_if.b_flat    = '0;
    uvm_config_db#(virtual systolic_if #(DW, M, K, N))::set(null, "uvm_test_top.*", "vif", dut_if);

    // run_test() launches the UVM phase machinery.
    // Test name comes from +UVM_TESTNAME= simulator argument:
    //   vsim ... +UVM_TESTNAME=systolic_rand_test
    //   vsim ... +UVM_TESTNAME=systolic_stress_test
    run_test("systolic_full_test");
  end

  // ── Global timeout watchdog ────────────────────────────────
  initial begin
    #(10_000_000);  // 10ms timeout
    `uvm_fatal("TIMEOUT", "Simulation exceeded 10ms — hung?");
  end

endmodule