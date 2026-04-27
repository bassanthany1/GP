// =============================================================================
// TESTBENCH TOP
// =============================================================================
`include "uvm_macros.svh"
import uvm_pkg::*;

module bias_relu_tb_top;
    import uvm_pkg::*;
    import br_pkg::*;

    // ---- Parameters (kept inside module to avoid file-scope order issues) ----
    localparam int TB_MAX_OUT_CHANNELS = 120;
    localparam int TB_TILE_ROWS        = 4;
    localparam int TB_ARRAY_COLS       = 4;
    localparam int TB_DATA_WIDTH       = 32;
    localparam int TB_BIAS_WIDTH       = 32;
    localparam int TB_MAX_BURST_LEN    = 32;

    // ---- Clock generation ----
    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;  // 100 MHz

    // ---- Interface instantiation ----
    br_if #(
        TB_MAX_OUT_CHANNELS,
        TB_TILE_ROWS,
        TB_ARRAY_COLS,
        TB_DATA_WIDTH,
        TB_BIAS_WIDTH,
        TB_MAX_BURST_LEN
    ) dut_if (.clk(clk));

    // ---- DUT instantiation ----
    bias_add_relu_streaming #(
        .MAX_OUT_CHANNELS (TB_MAX_OUT_CHANNELS),
        .TILE_ROWS        (TB_TILE_ROWS),
        .ARRAY_COLS       (TB_ARRAY_COLS),
        .DATA_WIDTH       (TB_DATA_WIDTH),
        .BIAS_WIDTH       (TB_BIAS_WIDTH),
        .MAX_BURST_LEN    (TB_MAX_BURST_LEN)
    ) dut (
        .clk                    (clk),
        .rst                    (dut_if.rst),
        .enable_relu            (dut_if.enable_relu),
        .out_channels           (dut_if.out_channels),
        .conv_valid             (dut_if.conv_valid),
        .conv_data              (dut_if.conv_data),
        .conv_channel_start     (dut_if.conv_channel_start),
        .conv_window_idx_start  (dut_if.conv_window_idx_start),
        .bias_sram_addr         (dut_if.bias_sram_addr),
        .bias_sram_burst_len    (dut_if.bias_sram_burst_len),
        .bias_sram_read_req     (dut_if.bias_sram_read_req),
        .bias_sram_data         (dut_if.bias_sram_data),
        .bias_sram_valid        (dut_if.bias_sram_valid),
        .bias_sram_burst_done   (dut_if.bias_sram_burst_done),
        .output_valid           (dut_if.output_valid),
        .output_data            (dut_if.output_data),
        .output_channel_start   (dut_if.output_channel_start),
        .output_window_idx_start(dut_if.output_window_idx_start)
    );

    // ---- Register virtual interface and kick off UVM ----
    initial begin
        uvm_config_db #(virtual br_if)::set(
            null, "uvm_test_top.*", "vif", dut_if);
        run_test("br_full_test");
    end

    // ---- Hard timeout ----
    initial begin
        #5_000_000;
        `uvm_fatal("BR_TB", "Hard timeout 5ms — simulation hung")
    end

endmodule