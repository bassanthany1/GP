module conv_bias_top #(
    parameter KERNEL_SIZE   = 5,
    parameter IN_CHANNELS   = 1,
    parameter OUT_CHANNELS  = 6,
    parameter INPUT_HEIGHT  = 28,
    parameter INPUT_WIDTH   = 28,
    parameter TILE_ROWS     = 8,
    parameter ARRAY_COLS    = 3,
    parameter DATA_WIDTH    = 8,
    parameter BIAS_WIDTH    = 32
)(
    input  logic clk,
    input  logic rst,
    input  logic start_conv,
    input  logic enable_relu,        // Enable ReLU activation
    output logic conv_done,
    
    // Input data
    input  logic signed [DATA_WIDTH-1:0] input_data_flat [IN_CHANNELS*INPUT_HEIGHT*INPUT_WIDTH],
    
    // Weight and bias data
    input  logic signed [DATA_WIDTH-1:0] weight_data [OUT_CHANNELS*KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS],
    input  logic weight_data_valid,
    input  logic signed [BIAS_WIDTH-1:0] bias_data [OUT_CHANNELS],
    
    // Output interface (after bias + optional ReLU)
    output logic output_valid,
    output logic signed [4*DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(OUT_CHANNELS)-1:0] output_channel_start,
    output logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] output_window_idx_start
);

    // Intermediate signals between conv and bias
    logic conv_output_valid;
    logic signed [4*DATA_WIDTH-1:0] conv_output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(OUT_CHANNELS)-1:0] conv_output_channel_start;
    logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] conv_output_window_idx_start;
    
    // Convolution module
    conv_top_v2 #(
        .KERNEL_SIZE(KERNEL_SIZE),
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .INPUT_HEIGHT(INPUT_HEIGHT),
        .INPUT_WIDTH(INPUT_WIDTH),
        .TILE_ROWS(TILE_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .DATA_WIDTH(DATA_WIDTH)
    ) conv_inst (
        .clk(clk),
        .rst(rst),
        .start_conv(start_conv),
        .conv_done(conv_done),
        .input_data_flat(input_data_flat),
        .weight_data(weight_data),
        .weight_data_valid(weight_data_valid),
        .output_valid(conv_output_valid),
        .output_data(conv_output_data),
        .output_channel_start(conv_output_channel_start),
        .output_window_idx_start(conv_output_window_idx_start)
    );
    
    // Bias + ReLU module
    bias_add_relu #(
        .OUT_CHANNELS(OUT_CHANNELS),
        .TILE_ROWS(TILE_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .DATA_WIDTH(4*DATA_WIDTH),
        .BIAS_WIDTH(BIAS_WIDTH)
    ) bias_inst (
        .clk(clk),
        .rst(rst),
        .enable_relu(enable_relu),
        .conv_valid(conv_output_valid),
        .conv_data(conv_output_data),
        .conv_channel_start(conv_output_channel_start),
        .conv_window_idx_start(conv_output_window_idx_start),
        .bias_data(bias_data),
        .output_valid(output_valid),
        .output_data(output_data),
        .output_channel_start(output_channel_start),
        .output_window_idx_start(output_window_idx_start)
    );

endmodule
