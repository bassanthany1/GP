// ============================================================
// Complete Convolution System Top Module
// Connects: Input -> Convolution -> Bias/ReLU -> Requantization -> Output
// ============================================================

module conv_system_top #(
    parameter KERNEL_SIZE   = 5,
    parameter IN_CHANNELS   = 1,
    parameter OUT_CHANNELS  = 6,
    parameter INPUT_HEIGHT  = 28,
    parameter INPUT_WIDTH   = 28,
    parameter TILE_ROWS     = 8,
    parameter ARRAY_COLS    = 3,
    parameter DATA_WIDTH    = 8,
    parameter BIAS_WIDTH    = 32,
    // Quantization parameters
    parameter IN_SCALE      = 32'd2147484,   // 0.001
    parameter WE_SCALE      = 32'd2147484,   // 0.001
    parameter OUT_SCALE     = 32'd21474836,  // 0.01
    parameter QUANT_SHIFT   = 24
)(
    input  logic clk,
    input  logic rst,
    input  logic start_conv,
    input  logic enable_relu,
    output logic conv_done,
    
    // Input data
    input  logic signed [DATA_WIDTH-1:0] input_data_flat [IN_CHANNELS*INPUT_HEIGHT*INPUT_WIDTH],
    
    // Weight and bias data
    input  logic signed [DATA_WIDTH-1:0] weight_data [OUT_CHANNELS*KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS],
    input  logic weight_data_valid,
    input  logic signed [BIAS_WIDTH-1:0] bias_data [OUT_CHANNELS],
    
    // Output interface (after requantization)
    output logic output_valid,
    output logic [7:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(OUT_CHANNELS)-1:0] output_channel_start,
    output logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] output_window_idx_start
);

    // ========== Internal Signals ==========
    
    // Signals from conv_bias_top to requantization
    logic conv_bias_valid;
    logic signed [4*DATA_WIDTH-1:0] conv_bias_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(OUT_CHANNELS)-1:0] conv_bias_channel_start;
    logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] conv_bias_window_idx_start;
    
    // Convert conv_bias output to unsigned 32-bit for requantization block
    logic [31:0] requant_input [TILE_ROWS][ARRAY_COLS];
    
    // Requantization output
    logic [7:0] requant_output [TILE_ROWS][ARRAY_COLS];
    
    // Requantization start signal (generated from conv_bias_valid)
    logic requant_start;
    
    // Pipeline registers for metadata (to align with requantization delay)
    // Requantization has 1-cycle latency with the start signal
    logic valid_stage1;
    logic [$clog2(OUT_CHANNELS)-1:0] channel_start_stage1;
    logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] window_idx_stage1;
    
    // ========== Module Instantiations ==========
    
    // Convolution with Bias and ReLU
    conv_bias_top #(
        .KERNEL_SIZE(KERNEL_SIZE),
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .INPUT_HEIGHT(INPUT_HEIGHT),
        .INPUT_WIDTH(INPUT_WIDTH),
        .TILE_ROWS(TILE_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .DATA_WIDTH(DATA_WIDTH),
        .BIAS_WIDTH(BIAS_WIDTH)
    ) conv_bias_inst (
        .clk(clk),
        .rst(rst),
        .start_conv(start_conv),
        .enable_relu(enable_relu),
        .conv_done(conv_done),
        .input_data_flat(input_data_flat),
        .weight_data(weight_data),
        .weight_data_valid(weight_data_valid),
        .bias_data(bias_data),
        .output_valid(conv_bias_valid),
        .output_data(conv_bias_data),
        .output_channel_start(conv_bias_channel_start),
        .output_window_idx_start(conv_bias_window_idx_start)
    );
    
    // Convert signed 32-bit conv output to unsigned 32-bit for requantization
    always_comb begin
        for (int r = 0; r < TILE_ROWS; r++) begin
            for (int c = 0; c < ARRAY_COLS; c++) begin
                requant_input[r][c] = conv_bias_data[r][c];
            end
        end
    end
    
    // Generate start signal for requantization (delayed by 1 cycle to align with data)
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            requant_start <= 1'b0;
        end else begin
            requant_start <= conv_bias_valid;
        end
    end
    
    // Requantization Block
    requantization_block #(
        .in_scale(IN_SCALE),
        .we_scale(WE_SCALE),
        .out_scale(OUT_SCALE),
        .sys_row(TILE_ROWS),
        .sys_col(ARRAY_COLS),
        .shift(QUANT_SHIFT)
    ) requant_inst (
        .clk(clk),
        .rst(rst),
        .start(requant_start),
        .sys_out(requant_input),
        .requant_out(requant_output)
    );
    
    // ========== Pipeline Metadata ==========
    // The requantization block has a 1-cycle latency with start signal
    // Pipeline the metadata signals to align with the output
    
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            valid_stage1 <= 1'b0;
            channel_start_stage1 <= '0;
            window_idx_stage1 <= '0;
        end else begin
            // Stage 1: Delay to match requantization latency
            valid_stage1 <= requant_start;
            channel_start_stage1 <= conv_bias_channel_start;
            window_idx_stage1 <= conv_bias_window_idx_start;
        end
    end
    
    // ========== Output Assignment ==========
    assign output_valid = valid_stage1;
    assign output_data = requant_output;
    assign output_channel_start = channel_start_stage1;
    assign output_window_idx_start = window_idx_stage1;

endmodule
