module avg_pool_2x2 #(
    parameter IN_CHANNELS    = 6,
    parameter INPUT_HEIGHT   = 24,
    parameter INPUT_WIDTH    = 24,
    parameter TILE_ROWS      = 8,
    parameter ARRAY_COLS     = 3,
    parameter DATA_WIDTH     = 16,
    parameter POOL_SIZE      = 2
)(
    input  logic clk,
    input  logic rst,
    
    // Input from bias_add_relu
    input  logic input_valid,
    input  logic signed [DATA_WIDTH-1:0] input_data [TILE_ROWS][ARRAY_COLS],
    input  logic [$clog2(IN_CHANNELS)-1:0] input_channel_start,
    input  logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] input_window_idx_start,
    
    // Output interface
    output logic output_valid,
    output logic signed [DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(IN_CHANNELS)-1:0] output_channel_start,
    output logic [$clog2((INPUT_HEIGHT/POOL_SIZE)*(INPUT_WIDTH/POOL_SIZE))-1:0] output_pooled_idx_start
);

    localparam OUT_HEIGHT = INPUT_HEIGHT / POOL_SIZE;
    localparam OUT_WIDTH  = INPUT_WIDTH / POOL_SIZE;
    
    // Buffer to store conv outputs
    logic signed [DATA_WIDTH-1:0] conv_buffer [IN_CHANNELS][INPUT_HEIGHT][INPUT_WIDTH];
    logic conv_ready [IN_CHANNELS][INPUT_HEIGHT][INPUT_WIDTH];
    
    // Track which pool windows are complete
    logic pool_window_ready [IN_CHANNELS][OUT_HEIGHT][OUT_WIDTH];
    logic pool_window_output [IN_CHANNELS][OUT_HEIGHT][OUT_WIDTH];
    
    // Declare all loop variables at module level
    integer c, h, w;
    integer tile_r, tile_c, win_idx, ch_idx;
    integer row_pos, col_pos;
    integer ch, cw;
    integer start_ch, start_h, start_w, found;
    integer out_r, out_c, pool_idx, pool_ch;
    integer dh, dw, conv_h, conv_w;
    logic all_ready;
    logic signed [DATA_WIDTH+2:0] sum;
    
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            output_valid <= 1'b0;
            output_channel_start <= '0;
            output_pooled_idx_start <= '0;
            
            for (c = 0; c < IN_CHANNELS; c = c + 1) begin
                for (h = 0; h < INPUT_HEIGHT; h = h + 1) begin
                    for (w = 0; w < INPUT_WIDTH; w = w + 1) begin
                        conv_buffer[c][h][w] <= '0;
                        conv_ready[c][h][w] <= 1'b0;
                    end
                end
                for (h = 0; h < OUT_HEIGHT; h = h + 1) begin
                    for (w = 0; w < OUT_WIDTH; w = w + 1) begin
                        pool_window_ready[c][h][w] <= 1'b0;
                        pool_window_output[c][h][w] <= 1'b0;
                    end
                end
            end
            
            for (h = 0; h < TILE_ROWS; h = h + 1) begin
                for (w = 0; w < ARRAY_COLS; w = w + 1) begin
                    output_data[h][w] <= '0;
                end
            end
            
        end else begin
            output_valid <= 1'b0;  // Default
            
            // Step 1: Store incoming conv outputs
            if (input_valid) begin
                for (tile_r = 0; tile_r < TILE_ROWS; tile_r = tile_r + 1) begin
                    win_idx = input_window_idx_start + tile_r;
                    
                    if (win_idx < INPUT_HEIGHT * INPUT_WIDTH) begin
                        row_pos = win_idx / INPUT_WIDTH;
                        col_pos = win_idx % INPUT_WIDTH;
                        
                        for (tile_c = 0; tile_c < ARRAY_COLS; tile_c = tile_c + 1) begin
                            ch_idx = input_channel_start + tile_c;
                            
                            if (ch_idx < IN_CHANNELS) begin
                                conv_buffer[ch_idx][row_pos][col_pos] <= input_data[tile_r][tile_c];
                                conv_ready[ch_idx][row_pos][col_pos] <= 1'b1;
                            end
                        end
                    end
                end
            end
            
            // Step 2: Check which pool windows are now complete
            for (c = 0; c < IN_CHANNELS; c = c + 1) begin
                for (h = 0; h < OUT_HEIGHT; h = h + 1) begin
                    for (w = 0; w < OUT_WIDTH; w = w + 1) begin
                        if (!pool_window_ready[c][h][w]) begin
                            all_ready = 1'b1;
                            for (ch = 0; ch < POOL_SIZE; ch = ch + 1) begin
                                for (cw = 0; cw < POOL_SIZE; cw = cw + 1) begin
                                    if (!conv_ready[c][h*POOL_SIZE + ch][w*POOL_SIZE + cw]) begin
                                        all_ready = 1'b0;
                                    end
                                end
                            end
                            
                            if (all_ready) begin
                                pool_window_ready[c][h][w] <= 1'b1;
                            end
                        end
                    end
                end
            end
            
            // Step 3: Generate one output tile from ready pool windows
            // Find first unoutput pool window and generate tile starting there
            found = 0;
            start_ch = 0;
            start_h = 0;
            start_w = 0;
            
            // Find first ready but not yet output window
            for (c = 0; c < IN_CHANNELS && found == 0; c = c + 1) begin
                for (h = 0; h < OUT_HEIGHT && found == 0; h = h + 1) begin
                    for (w = 0; w < OUT_WIDTH && found == 0; w = w + 1) begin
                        if (pool_window_ready[c][h][w] && !pool_window_output[c][h][w]) begin
                            found = 1;
                            start_ch = c;
                            start_h = h;
                            start_w = w;
                        end
                    end
                end
            end
            
            if (found) begin
                // Generate output tile starting from (start_ch, start_h, start_w)
                output_valid <= 1'b1;
                output_channel_start <= start_ch;
                output_pooled_idx_start <= start_h * OUT_WIDTH + start_w;
                
                for (out_r = 0; out_r < TILE_ROWS; out_r = out_r + 1) begin
                    pool_idx = start_h * OUT_WIDTH + start_w + out_r;
                    
                    if (pool_idx < OUT_HEIGHT * OUT_WIDTH) begin
                        h = pool_idx / OUT_WIDTH;
                        w = pool_idx % OUT_WIDTH;
                        
                        for (out_c = 0; out_c < ARRAY_COLS; out_c = out_c + 1) begin
                            pool_ch = start_ch + out_c;
                            
                            if (pool_ch < IN_CHANNELS && 
                                pool_window_ready[pool_ch][h][w] && 
                                !pool_window_output[pool_ch][h][w]) begin
                                
                                // Compute average of 2x2 window
                                sum = 0;
                                
                                for (dh = 0; dh < POOL_SIZE; dh = dh + 1) begin
                                    for (dw = 0; dw < POOL_SIZE; dw = dw + 1) begin
                                        conv_h = h * POOL_SIZE + dh;
                                        conv_w = w * POOL_SIZE + dw;
                                        sum = sum + conv_buffer[pool_ch][conv_h][conv_w];
                                    end
                                end
                                
                                output_data[out_r][out_c] <= sum >>> 2;
                                pool_window_output[pool_ch][h][w] <= 1'b1;
                            end else begin
                                output_data[out_r][out_c] <= '0;
                            end
                        end
                    end else begin
                        for (out_c = 0; out_c < ARRAY_COLS; out_c = out_c + 1) begin
                            output_data[out_r][out_c] <= '0;
                        end
                    end
                end
            end
        end
    end

endmodule
