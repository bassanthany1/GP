module weight_flatten2_streaming_burst #(
    parameter MAX_KERNEL_SIZE  = 5,
    parameter MAX_WIN_SIZE     = 256,
    parameter MAX_IN_CHANNELS  = 256,
    parameter MAX_OUT_CHANNELS = 120,
    parameter ARRAY_COLS       = 4,
    parameter DATA_WIDTH       = 8,
    parameter MAX_BURST_LEN    = 256,
    parameter MAX_WEIGHTS      = 30720
)(
    input  logic clk,
    input  logic rst,
    input  logic start,

    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    input logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels,
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,

    output logic tile_ready,
    output logic done_all,

    output logic [$clog2(MAX_OUT_CHANNELS*MAX_WIN_SIZE)-1:0] sram_addr,
    output logic [$clog2(MAX_BURST_LEN+1)-1:0] sram_burst_len,
    output logic sram_read_req,
    input  logic signed [DATA_WIDTH-1:0] sram_data,
    input  logic sram_valid,
    input  logic sram_burst_done,

    output logic signed [DATA_WIDTH-1:0] weight_tile
        [MAX_WIN_SIZE][ARRAY_COLS]
);
    localparam MAX_NUM_TILES = (MAX_OUT_CHANNELS + ARRAY_COLS - 1) / ARRAY_COLS;

    logic [$clog2(MAX_WIN_SIZE+1)-1:0]  weights_per_filter;
    logic [$clog2(MAX_NUM_TILES+1)-1:0] num_tiles;

    always_comb begin
        weights_per_filter = ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                             ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                             ($clog2(MAX_WIN_SIZE+1))'(in_channels);
        num_tiles          = (out_channels + ARRAY_COLS - 1) / ARRAY_COLS;
    end

    typedef enum logic [1:0] {
        IDLE            = 2'd0,
        REQUEST_BURST   = 2'd1,
        RECEIVING_BURST = 2'd2,
        TILE_DONE       = 2'd3
    } state_t;

    state_t state;

    logic [$clog2(MAX_NUM_TILES+1)-1:0]  tile_counter;
    logic [$clog2(ARRAY_COLS+1)-1:0]     current_col;
    logic [$clog2(MAX_WIN_SIZE+1)-1:0]   burst_count;

    logic [$clog2(MAX_WIN_SIZE+1)-1:0]     weights_per_filter_lat;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels_lat;
    logic [$clog2(MAX_NUM_TILES+1)-1:0]    num_tiles_lat;

    // FIX: oc_vec and base_addr_vec declared as module-level wires
    // driven combinationally - avoids 'automatic' inside always_ff
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0]              oc_vec;
    logic [$clog2(MAX_OUT_CHANNELS*MAX_WIN_SIZE)-1:0]   base_addr_vec;

    always_comb begin
        // FIX: explicit-width cast keeps all bits of out_channels_lat live
        // preventing bit[0] from being pruned (Warning #40 fix from Doc 4)
        oc_vec = ($clog2(MAX_OUT_CHANNELS+1))'(tile_counter) *
                 ($clog2(MAX_OUT_CHANNELS+1))'(ARRAY_COLS)   +
                 ($clog2(MAX_OUT_CHANNELS+1))'(current_col);

        base_addr_vec = oc_vec *
                        ($clog2(MAX_OUT_CHANNELS*MAX_WIN_SIZE))'(weights_per_filter_lat);
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state                  <= IDLE;
            tile_counter           <= 0;
            current_col            <= 0;
            burst_count            <= 0;
            tile_ready             <= 0;
            sram_addr              <= 0;
            sram_burst_len         <= 0;
            sram_read_req          <= 0;
            weights_per_filter_lat <= 0;
            out_channels_lat       <= 0;
            num_tiles_lat          <= 0;
            for (int r = 0; r < MAX_WIN_SIZE; r++)
                for (int c = 0; c < ARRAY_COLS; c++)
                    weight_tile[r][c] <= 0;
        end else begin
            tile_ready    <= 0;
            sram_read_req <= 0;

            case (state)
                IDLE: begin
                    if (start) begin
                        weights_per_filter_lat <= weights_per_filter;
                        out_channels_lat       <= out_channels;
                        num_tiles_lat          <= num_tiles;
                        current_col            <= 0;
                        state                  <= REQUEST_BURST;
                    end
                end

                REQUEST_BURST: begin
                    // FIX: oc_vec and base_addr_vec now computed combinationally
                    // above - just use them directly here, no 'automatic' needed
                    if (oc_vec < out_channels_lat) begin
                        sram_addr      <= base_addr_vec;
                        sram_burst_len <= weights_per_filter_lat;
                        sram_read_req  <= 1;
                        burst_count    <= 0;
                        state          <= RECEIVING_BURST;
                    end else begin
                        for (int r = 0; r < MAX_WIN_SIZE; r++)
                            weight_tile[r][current_col] <= 0;
                        if (current_col == ARRAY_COLS - 1)
                            state <= TILE_DONE;
                        else begin
                            current_col <= current_col + 1;
                            state       <= REQUEST_BURST;
                        end
                    end
                end

                RECEIVING_BURST: begin
                    if (sram_valid) begin
                        weight_tile[burst_count][current_col] <= sram_data;
                        burst_count <= burst_count + 1;
                    end
                    if (sram_burst_done ||
                        (sram_valid && burst_count == weights_per_filter_lat - 1)) begin
                        if (current_col == ARRAY_COLS - 1)
                            state <= TILE_DONE;
                        else begin
                            current_col <= current_col + 1;
                            state       <= REQUEST_BURST;
                        end
                    end
                end

                TILE_DONE: begin
                    tile_ready <= 1;
                    if (tile_counter == num_tiles_lat - 1)
                        tile_counter <= 0;
                    else
                        tile_counter <= tile_counter + 1;
                    state <= IDLE;
                end
            endcase
        end
    end

    assign done_all = tile_ready && (tile_counter == num_tiles_lat - 1);

endmodule