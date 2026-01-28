// ============================================================
// weight_flatten2.sv (TRULY FIXED VERSION)
// Generates one tile per start pulse, properly handles done_all
// ============================================================

module weight_flatten2 #(
    parameter KERNEL_SIZE   = 5,
    parameter IN_CHANNELS   = 1,
    parameter OUT_CHANNELS  = 6,
    parameter ARRAY_COLS    = 3,
    parameter DATA_WIDTH    = 8
)(
    input  logic clk,
    input  logic rst,
    input  logic start,              
    output logic tile_ready,
    output logic done_all,
    input  logic signed [DATA_WIDTH-1:0] sram_weight_data [OUT_CHANNELS*KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS],
    input  logic sram_data_valid,
    output logic signed [DATA_WIDTH-1:0] weight_tile [KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS][ARRAY_COLS]
);
    localparam WEIGHTS_PER_FILTER = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;
    localparam TOTAL_WEIGHTS      = OUT_CHANNELS * WEIGHTS_PER_FILTER;
    localparam NUM_TILES          = (OUT_CHANNELS + ARRAY_COLS - 1) / ARRAY_COLS;
    
    logic [$clog2(NUM_TILES+1)-1:0] tile_counter;
    logic start_prev;
    logic all_tiles_done;
    
    // Single always_ff block
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            tile_counter <= 0;
            tile_ready   <= 0;
            done_all     <= 0;
            start_prev   <= 0;
            all_tiles_done <= 0;
            
            // Initialize weight_tile with zeros
            for (int r = 0; r < WEIGHTS_PER_FILTER; r++) begin
                for (int c = 0; c < ARRAY_COLS; c++) begin
                    weight_tile[r][c] <= 0;
                end
            end
        end 
        else begin
            start_prev <= start;
            
            // Default: clear one-cycle signals
            tile_ready <= 0;
            done_all   <= 0;
            
            // Detect rising edge of start signal
            if (start && !start_prev && sram_data_valid && !all_tiles_done) begin
                // Generate tile at current tile_counter position
                if (tile_counter < NUM_TILES) begin
                    // Generate current tile
                    for (int r = 0; r < WEIGHTS_PER_FILTER; r++) begin
                        for (int c = 0; c < ARRAY_COLS; c++) begin
                            automatic logic [$clog2(OUT_CHANNELS+1)-1:0] oc;
                            oc = tile_counter * ARRAY_COLS + c;
                            
                            if (oc < OUT_CHANNELS) begin
                                // Use weights from file for valid output channels
                                weight_tile[r][c] <= sram_weight_data[oc * WEIGHTS_PER_FILTER + r];
                            end else begin
                                // Fill with zeros for padding channels
                                weight_tile[r][c] <= 0;
                            end
                        end
                    end
                    
                    tile_ready <= 1;
                    
                    // Increment counter for next time
                    tile_counter <= tile_counter + 1;
                    
                    // Signal done_all ONLY on the LAST tile
                    if (tile_counter == NUM_TILES - 1) begin
                        done_all <= 1;
                        all_tiles_done <= 1; // Mark all tiles as done
                    end
                end
            end
            
            // If we're requesting tiles beyond available data, generate zeros
            else if (start && !start_prev && sram_data_valid && all_tiles_done) begin
                for (int r = 0; r < WEIGHTS_PER_FILTER; r++) begin
                    for (int c = 0; c < ARRAY_COLS; c++) begin
                        weight_tile[r][c] <= 0;
                    end
                end
                tile_ready <= 1;
                done_all <= 1;
            end
        end
    end
endmodule
