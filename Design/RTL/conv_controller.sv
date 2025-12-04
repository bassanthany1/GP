// ============================================================
// Convolution Controller v2 (CORRECTED)
// Batch processing: TILE_ROWS windows at once through systolic
// Nested loops: Weight tiles (outer) -> Im2col tiles (inner)
// Systolic: M=TILE_ROWS, K=WINDOW_SIZE, N=ARRAY_COLS
// ============================================================

module conv_controller_v2 #(
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
    
    // Interface to im2col module
    output logic start_im2col,
    input  logic im2col_tile_ready,
    input  logic im2col_done_all,
    input  logic signed [DATA_WIDTH-1:0] im2col_tile_data [TILE_ROWS][KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS],
    
    // Interface to weight module
    output logic start_weight,
    input  logic weight_tile_ready,
    input  logic weight_done_all,
    input  logic signed [DATA_WIDTH-1:0] weight_tile [KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS][ARRAY_COLS],
    
    // Interface to systolic array (batch processing)
    output logic systolic_load,
    input  logic systolic_valid,
    input  logic signed [4*DATA_WIDTH-1:0] systolic_out [TILE_ROWS][ARRAY_COLS],
    
    // Output interface
    output logic output_valid,
    output logic signed [4*DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(OUT_CHANNELS)-1:0] output_channel_start,
    output logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] output_window_idx_start
);

    localparam WINDOW_SIZE = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;
    localparam OUTPUT_HEIGHT = INPUT_HEIGHT - KERNEL_SIZE + 1;
    localparam OUTPUT_WIDTH  = INPUT_WIDTH - KERNEL_SIZE + 1;
    localparam TOTAL_WINDOWS = OUTPUT_HEIGHT * OUTPUT_WIDTH;
    localparam NUM_IM2COL_TILES = (TOTAL_WINDOWS + TILE_ROWS - 1) / TILE_ROWS;
    localparam NUM_WEIGHT_TILES = (OUT_CHANNELS + ARRAY_COLS - 1) / ARRAY_COLS;
    
    // ========== State Machine ==========
    typedef enum logic [3:0] {
        IDLE,
        START_WEIGHT,
        WAIT_WEIGHT,
        START_IM2COL,
        WAIT_IM2COL,
        LOAD_SYSTOLIC,
        WAIT_SYSTOLIC,
        COLLECT_OUTPUT,
        CHECK_NEXT_IM2COL,
        CHECK_NEXT_WEIGHT,
        DONE
    } state_t;
    
    state_t state, next_state;
    
    // ========== Loop Counters ==========
    logic [$clog2(NUM_WEIGHT_TILES+1)-1:0] weight_tile_idx;
    logic [$clog2(NUM_IM2COL_TILES+1)-1:0] im2col_tile_idx;
    
    // Track which weight tile and im2col tile we're on
    logic [$clog2(OUT_CHANNELS)-1:0] current_output_channel;
    logic [$clog2(TOTAL_WINDOWS+1)-1:0] current_window_idx_start;
    
    // ========== State Register ==========
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            state <= IDLE;
        else
            state <= next_state;
    end
    
    // ========== Next State Logic ==========
    always_comb begin
        next_state = state;
        
        case (state)
            IDLE: begin
                if (start_conv)
                    next_state = START_WEIGHT;
            end
            
            START_WEIGHT: begin
                next_state = WAIT_WEIGHT;
            end
            
            WAIT_WEIGHT: begin
                if (weight_tile_ready)
                    next_state = START_IM2COL;
            end
            
            START_IM2COL: begin
                next_state = WAIT_IM2COL;
            end
            
            WAIT_IM2COL: begin
                if (im2col_tile_ready)
                    next_state = LOAD_SYSTOLIC;
            end
            
            LOAD_SYSTOLIC: begin
                next_state = WAIT_SYSTOLIC;
            end
            
            WAIT_SYSTOLIC: begin
                if (systolic_valid)
                    next_state = COLLECT_OUTPUT;
            end
            
            COLLECT_OUTPUT: begin
                next_state = CHECK_NEXT_IM2COL;
            end
            
            CHECK_NEXT_IM2COL: begin
                // After processing one im2col tile with current weight tile
                if (im2col_tile_idx < NUM_IM2COL_TILES - 1)
                    next_state = START_IM2COL;
                else
                    next_state = CHECK_NEXT_WEIGHT;
            end
            
            CHECK_NEXT_WEIGHT: begin
                // After processing all im2col tiles with current weight tile
                if (weight_tile_idx < NUM_WEIGHT_TILES - 1)
                    next_state = START_WEIGHT;
                else
                    next_state = DONE;
            end
            
            DONE: begin
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // ========== Datapath ==========
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            start_im2col        <= 0;
            start_weight        <= 0;
            systolic_load       <= 0;
            output_valid        <= 0;
            conv_done           <= 0;
            
            weight_tile_idx     <= 0;
            im2col_tile_idx     <= 0;
            current_output_channel <= 0;
            current_window_idx_start <= 0;
            output_channel_start <= 0;
            output_window_idx_start <= 0;
            
            for (int r = 0; r < TILE_ROWS; r++)
                for (int c = 0; c < ARRAY_COLS; c++)
                    output_data[r][c] <= 0;
                    
        end else begin
            // Default values
            start_im2col  <= 0;
            start_weight  <= 0;
            systolic_load <= 0;
            output_valid  <= 0;
            conv_done     <= 0;
            
            case (state)
                IDLE: begin
                    if (start_conv) begin
                        weight_tile_idx     <= 0;
                        im2col_tile_idx     <= 0;
                        current_output_channel <= 0;
                        current_window_idx_start <= 0;
                    end
                end
                
                START_WEIGHT: begin
                    start_weight <= 1;
                end
                
                WAIT_WEIGHT: begin
                    if (weight_tile_ready) begin
                        current_output_channel <= weight_tile_idx * ARRAY_COLS;
                    end
                end
                
                START_IM2COL: begin
                    start_im2col <= 1;
                end
                
                WAIT_IM2COL: begin
                    if (im2col_tile_ready) begin
                        // Calculate starting window index for this im2col tile
                        current_window_idx_start <= im2col_tile_idx * TILE_ROWS;
                    end
                end
                
                LOAD_SYSTOLIC: begin
                    systolic_load <= 1;
                end
                
                COLLECT_OUTPUT: begin
                    output_valid <= 1;
                    output_channel_start <= current_output_channel;
                    output_window_idx_start <= current_window_idx_start;
                    
                    // Pass through entire systolic output tile
                    for (int r = 0; r < TILE_ROWS; r++) begin
                        for (int c = 0; c < ARRAY_COLS; c++) begin
                            output_data[r][c] <= systolic_out[r][c];
                        end
                    end
                end
                
                CHECK_NEXT_IM2COL: begin
                    if (im2col_tile_idx < NUM_IM2COL_TILES - 1) begin
                        im2col_tile_idx <= im2col_tile_idx + 1;
                    end
                end
                
                CHECK_NEXT_WEIGHT: begin
                    if (weight_tile_idx < NUM_WEIGHT_TILES - 1) begin
                        weight_tile_idx <= weight_tile_idx + 1;
                        im2col_tile_idx <= 0;  // Reset im2col counter for next weight tile
                    end
                end
                
                DONE: begin
                    conv_done <= 1;
                end
            endcase
        end
    end
    
    // ========== Systolic Array Input Formatter ==========
    // Matrix A: TILE_ROWS x WINDOW_SIZE (from im2col tile)
    // Matrix B: WINDOW_SIZE x ARRAY_COLS (weight tile)
    logic signed [DATA_WIDTH-1:0] systolic_a [TILE_ROWS][WINDOW_SIZE];
    logic signed [DATA_WIDTH-1:0] systolic_b [WINDOW_SIZE][ARRAY_COLS];
    
    always_comb begin
        // Matrix A: Direct im2col tile data
        systolic_a = im2col_tile_data;
        
        // Matrix B: Weight tile directly
        systolic_b = weight_tile;
    end

endmodule
