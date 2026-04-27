
// conv_controller_top.sv - Top level file for conv_controller UVM verification
`timescale 1ns/1ps

module conv_controller_top;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // Include interface
    `include "conv_controller_if.sv"

    // Include all UVM components
    `include "conv_controller_seq_item.svh"
    `include "conv_controller_driver.svh"
    `include "conv_controller_monitor.svh"
    `include "conv_controller_sequences.svh"
    `include "conv_controller_agent.svh"
    `include "conv_controller_scoreboard_fixed.svh"
    `include "conv_controller_subscriber.svh"
    `include "conv_controller_env.svh"
    `include "conv_controller_tests.svh"

    // Clock and reset signals
    logic clk;
    logic rst;

    // Instantiate interface
    conv_controller_if vif(
        .clk(clk),
        .rst(rst)
    );

    // Instantiate DUT
    conv_controller_v3 dut(
        .clk(vif.clk),
        .rst(vif.rst),
        .start_conv(vif.start_conv),
        .fc_mode(vif.fc_mode),
        .conv_done(vif.conv_done),
        .kernel_size(vif.kernel_size),
        .out_channels(vif.out_channels),
        .input_height(vif.input_height),
        .input_width(vif.input_width),
        .start_im2col(vif.start_im2col),
        .im2col_tile_ready(vif.im2col_tile_ready),
        .start_weight(vif.start_weight),
        .weight_tile_ready(vif.weight_tile_ready),
        .systolic_load(vif.systolic_load),
        .systolic_valid(vif.systolic_valid),
        .systolic_out(vif.systolic_out),
        .output_valid(vif.output_valid),
        .output_data(vif.output_data),
        .output_channel_start(vif.output_channel_start),
        .output_window_idx_start(vif.output_window_idx_start)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Reset generation
    initial begin
        rst = 1;
        #100;
        rst = 0;
    end

    // Mock im2col_tile_ready and weight_tile_ready signals
    always @(posedge clk) begin
        if(vif.start_im2col) begin
            vif.im2col_tile_ready <= 1;
        end else if (vif.im2col_tile_ready) begin
            vif.im2col_tile_ready <= 0;
        end

        if(vif.start_weight) begin
            vif.weight_tile_ready <= 1;
        end else if (vif.weight_tile_ready) begin
            vif.weight_tile_ready <= 0;
        end

        if(vif.systolic_load) begin
            vif.systolic_valid <= 1;
            // Generate random systolic_out values
            for(int i = 0; i < 4; i++) begin
                for(int j = 0; j < 4; j++) begin
                    vif.systolic_out[i][j] <= $random;
                end
            end
        end else if (vif.systolic_valid) begin
            vif.systolic_valid <= 0;
        end
    end

    // Set virtual interface in config database
    initial begin
        uvm_config_db#(virtual conv_controller_if)::set(null, "*", "vif", vif);
    end

    // Run test
    initial begin
        run_test("conv_controller_high_stress_test");
    end

endmodule
