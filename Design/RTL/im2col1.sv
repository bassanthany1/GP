module im2col1 #(
    parameter IMG_W        = 28,
    parameter IMG_H        = 28,
    parameter KERNEL_SIZE  = 5,
    parameter STRIDE       = 1,
    parameter TILE_ROWS    = 8,
    parameter IN_CHANNELS  = 1,
    parameter DATA_WIDTH   = 8
)(
    input  logic clk,
    input  logic rst,
    input  logic start,
    output logic tile_ready,
    output logic done_all,
    output logic  [DATA_WIDTH-1:0] tile_data [TILE_ROWS][KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS],
    input  logic  [DATA_WIDTH-1:0] img_data_flat [IN_CHANNELS*IMG_H*IMG_W]
);

    localparam OUT_W = (IMG_W - KERNEL_SIZE) / STRIDE + 1;
    localparam OUT_H = (IMG_H - KERNEL_SIZE) / STRIDE + 1;
    localparam TOTAL_WINDOWS = OUT_W * OUT_H;
    localparam WINDOW_SIZE = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;
    localparam NUM_TILES = (TOTAL_WINDOWS + TILE_ROWS - 1) / TILE_ROWS;

    typedef enum logic [1:0] { IDLE, GENERATE_TILE, RESET_STATE } state_t;
    state_t state, next_state;

    logic [$clog2(NUM_TILES+1)-1:0] tile_counter;
    logic [$clog2(TILE_ROWS+1)-1:0] row_cnt;
    
    // Window position tracking - incremental update instead of division
    logic [$clog2(OUT_H+1)-1:0] wy;
    logic [$clog2(OUT_W+1)-1:0] wx;
    logic [$clog2(TOTAL_WINDOWS+1)-1:0] window_idx;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            tile_counter <= 0;
            row_cnt <= 0;
            tile_ready <= 0;
            done_all <= 0;
            window_idx <= 0;
            wy <= 0;
            wx <= 0;
            
            for (int r = 0; r < TILE_ROWS; r++)
                for (int e = 0; e < WINDOW_SIZE; e++)
                    tile_data[r][e] <= '0;
        end else begin
            tile_ready <= 0;
            done_all <= 0;
            state <= next_state;

            case (state)
                IDLE: begin
                    if (start) begin
                        row_cnt <= 0;
                        // Initialize window position for this tile
                        window_idx <= tile_counter * TILE_ROWS;
                        wy <= (tile_counter * TILE_ROWS) / OUT_W;
                        wx <= (tile_counter * TILE_ROWS) % OUT_W;
                    end
                end

                GENERATE_TILE: begin
                    // Generate one row of the tile
                    if (window_idx < TOTAL_WINDOWS) begin
                        for (int c = 0; c < IN_CHANNELS; c++) begin
                            for (int ky = 0; ky < KERNEL_SIZE; ky++) begin
                                for (int kx = 0; kx < KERNEL_SIZE; kx++) begin
                                    automatic int elem = c*KERNEL_SIZE*KERNEL_SIZE + ky*KERNEL_SIZE + kx;
                                    automatic int iy = wy*STRIDE + ky;
                                    automatic int ix = wx*STRIDE + kx;
                                    automatic int flat_idx = c*IMG_H*IMG_W + iy*IMG_W + ix;
                                    tile_data[row_cnt][elem] <= img_data_flat[flat_idx];
                                end
                            end
                        end
                    end else begin
                        // Padding for incomplete tiles
                        for (int e = 0; e < WINDOW_SIZE; e++) begin
                            tile_data[row_cnt][e] <= '0;
                        end
                    end

                    // Increment window position for next row
                    if (wx == OUT_W - 1) begin
                        wx <= 0;
                        wy <= wy + 1;
                    end else begin
                        wx <= wx + 1;
                    end
                    window_idx <= window_idx + 1;

                    // Check if tile complete
                    if (row_cnt == TILE_ROWS-1) begin
                        tile_ready <= 1;
                        if (tile_counter == NUM_TILES - 1) begin
                            done_all <= 1;
                        end
                        tile_counter <= tile_counter + 1;
                        row_cnt <= 0;
                    end else begin
                        row_cnt <= row_cnt + 1;
                    end
                end

                RESET_STATE: begin
                    tile_counter <= 0;
                    window_idx <= 0;
                    wy <= 0;
                    wx <= 0;
                end
            endcase
        end
    end

    // Next state logic
    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (start) begin
                    if (tile_counter >= NUM_TILES)
                        next_state = RESET_STATE;
                    else
                        next_state = GENERATE_TILE;
                end
            end

            GENERATE_TILE: begin
                if (row_cnt == TILE_ROWS-1)
                    next_state = IDLE;
            end

            RESET_STATE: begin
                next_state = GENERATE_TILE;
            end
        endcase
    end

endmodule
