`include "uvm_macros.svh"
import uvm_pkg::* ;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int PKG_DATA_WIDTH    = 8;
    localparam int PKG_MAX_BURST_LEN = 512;
    localparam int PKG_MAX_WEIGHTS   = 30720;
    localparam int PKG_TOTAL_WEIGHTS = 44190;
    localparam int PKG_BRAM_DEPTH    = 65536;
    localparam int PKG_PIPE_LATENCY  = 3;

module wf_sram_tb_top;
    import uvm_pkg::* ;
    import wf_sram_pkg::* ;

    

    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    wf_sram_if #(
        PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
        PKG_MAX_WEIGHTS, PKG_TOTAL_WEIGHTS
    ) dut_if (.clk(clk));

    weight_sram_lenet5_actual #(
        .DATA_WIDTH    (PKG_DATA_WIDTH),
        .MAX_BURST_LEN (PKG_MAX_BURST_LEN),
        .MAX_WEIGHTS   (PKG_MAX_WEIGHTS),
        .TOTAL_WEIGHTS (PKG_TOTAL_WEIGHTS)
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
        uvm_config_db #(virtual wf_sram_if #(
            PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
            PKG_MAX_WEIGHTS, PKG_TOTAL_WEIGHTS))
        ::set(null, "uvm_test_top.*", "vif", dut_if);
        run_test("wf_sram_full_test");
    end

    initial begin
        #10_000_000;
        `uvm_fatal("WF_TB", "Hard timeout 10ms")
    end

endmodule