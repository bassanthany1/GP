// ============================================================
// Bias Addition Module with ReLU Activation (Optional)
// Adds bias and optionally applies ReLU activation
// ============================================================

module bias_add_relu #(
    parameter OUT_CHANNELS  = 6,
    parameter TILE_ROWS     = 8,
    parameter ARRAY_COLS    = 3,
    parameter DATA_WIDTH    = 32,
    parameter BIAS_WIDTH    = 32
)(
    input  logic clk,
    input  logic rst,
    input  logic enable_relu,  // Control signal to enable/disable ReLU
    
    // Input from convolution
    input  logic conv_valid,
    input  logic signed [DATA_WIDTH-1:0] conv_data [TILE_ROWS][ARRAY_COLS],
    input  logic [$clog2(OUT_CHANNELS)-1:0] conv_channel_start,
    input  logic [$clog2(1024)-1:0] conv_window_idx_start,
    
    // Bias values
    input  logic signed [BIAS_WIDTH-1:0] bias_data [OUT_CHANNELS],
    
    // Output with bias (and optionally ReLU)
    output logic output_valid,
    output logic signed [DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(OUT_CHANNELS)-1:0] output_channel_start,
    output logic [$clog2(1024)-1:0] output_window_idx_start
);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            output_valid <= 1'b0;
            output_channel_start <= '0;
            output_window_idx_start <= '0;
            
            for (int r = 0; r < TILE_ROWS; r++) begin
                for (int c = 0; c < ARRAY_COLS; c++) begin
                    output_data[r][c] <= '0;
                end
            end
        end else begin
            output_valid <= conv_valid;
            output_channel_start <= conv_channel_start;
            output_window_idx_start <= conv_window_idx_start;
            
            if (conv_valid) begin
                for (int r = 0; r < TILE_ROWS; r++) begin
                    for (int c = 0; c < ARRAY_COLS; c++) begin
                        automatic int channel_idx;
                        automatic logic signed [DATA_WIDTH-1:0] biased_value;
                        
                        channel_idx = conv_channel_start + c;
                        
                        if (channel_idx < OUT_CHANNELS) begin
                            // Add bias
                            biased_value = conv_data[r][c] + bias_data[channel_idx];
                            
                            // Apply ReLU if enabled: max(0, x)
                            if (enable_relu && biased_value < 0) begin
                                output_data[r][c] <= '0;
                            end else begin
                                output_data[r][c] <= biased_value;
                            end
                        end else begin
                            output_data[r][c] <= conv_data[r][c];
                        end
             end
                end
            end
        end
    end

endmodule
