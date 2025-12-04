// ============================================================
// Convolution Top Module v2 - FIXED
// Matches controller's batch processing output format
// ============================================================

module conv_top_v2 #(
    parameter KERNEL_SIZE   = 5,
    parameter IN_CHANNELS   = 1,
    parameter OUT_CHANNELS  = 6,
    parameter INPUT_HEIGHT  = 28,
    parameter INPUT_WIDTH   = 28,
    parameter TILE_ROWS     = 8,
    parameter ARRAY_COLS    = 3,
    parameter DATA_WIDTH    = 8
)(
    input  logic clk,
    input  logic rst,
    input  logic start_conv,
    output logic conv_done,
    
    // Input data (flattened for im2col1)
    input  logic signed [DATA_WIDTH-1:0] input_data_flat [IN_CHANNELS*INPUT_HEIGHT*INPUT_WIDTH],
    
    // Weight data
    input  logic signed [DATA_WIDTH-1:0] weight_data [OUT_CHANNELS*KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS],
    input  logic weight_data_valid,
    
    // Output interface - UPDATED for batch processing
    output logic output_valid,
    output logic signed [4*DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(OUT_CHANNELS)-1:0] output_channel_start,
    output logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] output_window_idx_start
);

    localparam WINDOW_SIZE = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;
    
    // ========== Internal Signals ==========
    
    // Im2col signals
    logic start_im2col;
    logic im2col_tile_ready;
    logic im2col_done_all;
    logic signed [DATA_WIDTH-1:0] im2col_tile_data [TILE_ROWS][WINDOW_SIZE];
    
    // Weight signals
    logic start_weight;
    logic weight_tile_ready;
    logic weight_done_all;
    logic signed [DATA_WIDTH-1:0] weight_tile [WINDOW_SIZE][ARRAY_COLS];
    
    // Systolic signals - UPDATED dimensions
    logic systolic_load;
    logic systolic_valid;
    logic signed [4*DATA_WIDTH-1:0] systolic_out [TILE_ROWS][ARRAY_COLS];
    
    // ========== Module Instantiations ==========
    
    // Im2col module
    im2col1 #(
        .IMG_W(INPUT_WIDTH),
        .IMG_H(INPUT_HEIGHT),
        .KERNEL_SIZE(KERNEL_SIZE),
        .STRIDE(1),
        .TILE_ROWS(TILE_ROWS),
        .IN_CHANNELS(IN_CHANNELS),
        .DATA_WIDTH(DATA_WIDTH)
    ) im2col (
        .clk(clk),
        .rst(rst),
        .start(start_im2col),
        .tile_ready(im2col_tile_ready),
        .done_all(im2col_done_all),
        .tile_data(im2col_tile_data),
        .img_data_flat(input_data_flat)
    );
    
    // Weight module
    weight_flatten2 #(
        .KERNEL_SIZE(KERNEL_SIZE),
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .ARRAY_COLS(ARRAY_COLS),
        .DATA_WIDTH(DATA_WIDTH)
    ) weight_mgr (
        .clk(clk),
        .rst(rst),
        .start(start_weight),
        .tile_ready(weight_tile_ready),
        .done_all(weight_done_all),
        .sram_weight_data(weight_data),
        .sram_data_valid(weight_data_valid),
        .weight_tile(weight_tile)
    );
    
    // Controller - UPDATED for batch processing
    conv_controller_v2 #(
        .KERNEL_SIZE(KERNEL_SIZE),
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .INPUT_HEIGHT(INPUT_HEIGHT),
        .INPUT_WIDTH(INPUT_WIDTH),
        .TILE_ROWS(TILE_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .DATA_WIDTH(DATA_WIDTH)
    ) controller (
        .clk(clk),
        .rst(rst),
        .start_conv(start_conv),
        .conv_done(conv_done),
        
        .start_im2col(start_im2col),
        .im2col_tile_ready(im2col_tile_ready),
        .im2col_done_all(im2col_done_all),
        .im2col_tile_data(im2col_tile_data),
        
        .start_weight(start_weight),
        .weight_tile_ready(weight_tile_ready),
        .weight_done_all(weight_done_all),
        .weight_tile(weight_tile),
        
        .systolic_load(systolic_load),
        .systolic_valid(systolic_valid),
        .systolic_out(systolic_out),
        
        .output_valid(output_valid),
        .output_data(output_data),
        .output_channel_start(output_channel_start),
        .output_window_idx_start(output_window_idx_start)
    );
    
    // Systolic array - UPDATED dimensions for batch processing
    systolic_full #(
        .DATAWIDTH(DATA_WIDTH),
        .M(TILE_ROWS),      // Process TILE_ROWS windows at once
        .K(WINDOW_SIZE),    // WINDOW_SIZE kernel elements
        .N(ARRAY_COLS)      // ARRAY_COLS output channels
    ) systolic (
        .clk(clk),
        .rst(rst),
        .load_data(systolic_load),
        .a_full_in(controller.systolic_a),
        .b_full_in(controller.systolic_b),
        .valid_out(systolic_valid),
        .c_out(systolic_out)
    );

endmodule
