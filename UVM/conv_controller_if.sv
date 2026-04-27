
// conv_controller_if.sv - Interface for conv_controller UVM verification
interface conv_controller_if #(
    parameter MAX_KERNEL_SIZE  = 5,
    parameter MAX_WIN_SIZE     = 256,
    parameter MAX_IN_CHANNELS  = 256,
    parameter MAX_OUT_CHANNELS = 120,
    parameter MAX_INPUT_HEIGHT = 28,
    parameter MAX_INPUT_WIDTH  = 28,
    parameter TILE_ROWS        = 4,
    parameter ARRAY_COLS       = 4,
    parameter DATA_WIDTH       = 8
)(
    input logic clk,
    input logic rst
);

    // Control signals
    logic  start_conv;
    logic  fc_mode;
    logic  conv_done;

    // Configuration parameters
    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels;
    logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height;
    logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width;

    // Im2col interface
    logic  start_im2col;
    logic  im2col_tile_ready;

    // Weight interface
    logic  start_weight;
    logic  weight_tile_ready;

    // Systolic array interface
    logic  systolic_load;
    logic  systolic_valid;
    logic signed [4*DATA_WIDTH-1:0] systolic_out [TILE_ROWS][ARRAY_COLS];

    // Output interface
    logic  output_valid;
    logic signed [4*DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(MAX_OUT_CHANNELS)-1:0]                 output_channel_start;
    logic [$clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH)-1:0] output_window_idx_start;

    // Clocking block for driver
    clocking driver_cb @(posedge clk);
        default input #1ns output #1ns;
        output start_conv, fc_mode;
        output kernel_size, out_channels, input_height, input_width;
        input im2col_tile_ready, weight_tile_ready, systolic_valid;
        input systolic_out;
    endclocking

    // Clocking block for monitor
    clocking monitor_cb @(posedge clk);
        default input #1ns output #1ns;
        input start_conv, fc_mode;
        input kernel_size, out_channels, input_height, input_width;
        input start_im2col, im2col_tile_ready;
        input start_weight, weight_tile_ready;
        input systolic_load, systolic_valid, systolic_out;
        input output_valid, output_data, output_channel_start, output_window_idx_start;
        input conv_done;
    endclocking

    // Modports
    modport DRIVER (clocking driver_cb, input clk, rst);
    modport MONITOR (clocking monitor_cb, input clk, rst);

endinterface
