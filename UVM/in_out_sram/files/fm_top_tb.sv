// =============================================================================
// TESTBENCH TOP
// =============================================================================
`include "uvm_macros.svh"
import uvm_pkg::*;

module fmap_sram_tb_top;
    import uvm_pkg::*;
    import fmap_sram_pkg::*;

    // ---- Parameters ----
    localparam int TB_DATA_WIDTH     = 8;
    localparam int TB_TOTAL_ELEMENTS = 864;
    localparam int TB_NUM_PORTS      = 3;

    // ---- Clock ----
    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ---- Interface ----
    fm_if #(TB_DATA_WIDTH, TB_TOTAL_ELEMENTS, TB_NUM_PORTS) dut_if (.clk(clk));

    // ---- DUT ----
    feature_map_sram_5port #(
        .DATA_WIDTH     (TB_DATA_WIDTH),
        .TOTAL_ELEMENTS (TB_TOTAL_ELEMENTS),
        .NUM_PORTS      (TB_NUM_PORTS)
    ) dut (
        .clk          (clk),
        .rst          (dut_if.rst),
        .wr_en        (dut_if.wr_en),
        .wr_addr      (dut_if.wr_addr),
        .wr_data      (dut_if.wr_data),
        .rd_req       (dut_if.rd_req),
        .rd_addr      (dut_if.rd_addr),
        .rd_data      (dut_if.rd_data),
        .rd_valid     (dut_if.rd_valid),
        .bank_conflict(dut_if.bank_conflict)
    );

    // ---- UVM kickoff ----
    initial begin
        uvm_config_db #(virtual fm_if #(
            TB_DATA_WIDTH, TB_TOTAL_ELEMENTS, TB_NUM_PORTS))
        ::set(null, "uvm_test_top.*", "vif", dut_if);
        run_test("fm_full_test");
    end

    // ---- Hard timeout ----
    initial begin
        #50_000_000;
        `uvm_fatal("FM_TB", "Hard timeout 50ms — simulation hung")
    end

endmodule 