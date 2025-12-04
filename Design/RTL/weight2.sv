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
    
    // FSM States
    typedef enum logic [1:0] {
        IDLE,
        GENERATE_TILE,
        TILE_DONE
    } state_t;
    
    state_t current_state, next_state;
    
    // Internal registers
    logic [$clog2(NUM_TILES+1)-1:0] tile_counter, tile_counter_next;
    logic all_tiles_done, all_tiles_done_next;
    logic signed [DATA_WIDTH-1:0] weight_tile_next [WEIGHTS_PER_FILTER][ARRAY_COLS];
    
    // State register
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            current_state <= IDLE;
            tile_counter <= 0;
            all_tiles_done <= 0;
            
            // Initialize weight_tile with zeros
            for (int r = 0; r < WEIGHTS_PER_FILTER; r++) begin
                for (int c = 0; c < ARRAY_COLS; c++) begin
                    weight_tile[r][c] <= 0;
                end
            end
        end else begin
            current_state <= next_state;
            tile_counter <= tile_counter_next;
            all_tiles_done <= all_tiles_done_next;
            weight_tile <= weight_tile_next;
        end
    end
    
    // Next state logic
    always_comb begin
        // Default assignments
        next_state = current_state;
        tile_counter_next = tile_counter;
        all_tiles_done_next = all_tiles_done;
        tile_ready = 0;
        done_all = 0;
        weight_tile_next = weight_tile;
        
        case (current_state)
            IDLE: begin
                if (start && sram_data_valid) begin
                    // If all tiles were done, reset counter
                    if (all_tiles_done) begin
                        tile_counter_next = 0;
                        all_tiles_done_next = 0;
                    end
                    
                    // Check if we have tiles to generate
                    if (tile_counter_next < NUM_TILES) begin
                        next_state = GENERATE_TILE;
                    end
                end
            end
            
            GENERATE_TILE: begin
                // Generate current tile
                for (int r = 0; r < WEIGHTS_PER_FILTER; r++) begin
                    for (int c = 0; c < ARRAY_COLS; c++) begin
                        automatic logic [$clog2(OUT_CHANNELS+1)-1:0] oc;
                        oc = tile_counter * ARRAY_COLS + c;
                        
                        if (oc < OUT_CHANNELS) begin
                            // Use weights from SRAM for valid output channels
                            weight_tile_next[r][c] = sram_weight_data[oc * WEIGHTS_PER_FILTER + r];
                        end else begin
                            // Fill with zeros for padding channels
                            weight_tile_next[r][c] = 0;
                        end
                    end
                end
                
                next_state = TILE_DONE;
            end
            
            TILE_DONE: begin
                tile_ready = 1;
                
                // Increment counter
                tile_counter_next = tile_counter + 1;
                
                // Check if this was the last tile
                if (tile_counter == NUM_TILES - 1) begin
                    done_all = 1;
                    all_tiles_done_next = 1;
                end
                
                next_state = IDLE;
            end
            
            default: begin
                next_state = IDLE;
            end
        endcase
    end
    
endmodule
