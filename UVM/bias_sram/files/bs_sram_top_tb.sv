// =============================================================================
// TESTBENCH TOP
// =============================================================================
`include "uvm_macros.svh"
import uvm_pkg::*;

localparam int PKG_DATA_WIDTH    = 32;
localparam int PKG_MAX_BURST_LEN = 16;
localparam int PKG_MAX_BIASES    = 120;
localparam int PKG_TOTAL_BIASES  = 236;
localparam int PKG_PIPE_LATENCY  = 3;

module bs_sram_tb_top;
    import uvm_pkg::*;
    import bs_sram_pkg::*;

    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    bs_sram_if #(
        PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
        PKG_MAX_BIASES, PKG_TOTAL_BIASES
    ) dut_if (.clk(clk));

    bias_sram_lenet5_dut #(
        .DATA_WIDTH    (PKG_DATA_WIDTH),
        .MAX_BURST_LEN (PKG_MAX_BURST_LEN),
        .MAX_BIASES    (PKG_MAX_BIASES),
        .TOTAL_BIASES  (PKG_TOTAL_BIASES)
    ) dut (
        .clk            (clk),
        .rst            (dut_if.rst),
        .layer_offset   (dut_if.layer_offset),
        .write_addr     (dut_if.write_addr),
        .write_data     (dut_if.write_data),
        .write_enable   (dut_if.write_enable),
        .read_addr      (dut_if.read_addr),
        .burst_length   (dut_if.burst_length),
        .read_request   (dut_if.read_request),
        .read_data      (dut_if.read_data),
        .read_valid     (dut_if.read_valid),
        .burst_complete (dut_if.burst_complete)
    );

    initial begin
        uvm_config_db #(virtual bs_sram_if #(
            PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
            PKG_MAX_BIASES, PKG_TOTAL_BIASES))
        ::set(null, "uvm_test_top.*", "vif", dut_if);
        run_test("bs_sram_full_test");
    end

    initial begin
        #5_000_000;
        `uvm_fatal("BS_TB", "Hard timeout 5ms")
    end

endmodule