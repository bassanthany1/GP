module weight_flatten2_streaming_burst #(
    parameter MAX_KERNEL_SIZE  = 5,
    parameter MAX_IN_CHANNELS  = 256,
    parameter MAX_OUT_CHANNELS = 120,
    parameter ARRAY_COLS       = 8,
    parameter DATA_WIDTH       = 8,
    parameter MAX_BURST_LEN    = 256
)(
    input  logic clk,
    input  logic rst,
    input  logic start,

    // Runtime geometry — NEW
    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    input logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels,
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,

    output logic tile_ready,
    output logic done_all,

    output logic [$clog2(MAX_OUT_CHANNELS*MAX_KERNEL_SIZE*
                          MAX_KERNEL_SIZE*MAX_IN_CHANNELS)-1:0] sram_addr,
    output logic [$clog2(MAX_BURST_LEN+1)-1:0] sram_burst_len,
    output logic sram_read_req,
    input  logic signed [DATA_WIDTH-1:0] sram_data,
    input  logic sram_valid,
    input  logic sram_burst_done,

    output logic signed [DATA_WIDTH-1:0] weight_tile
        [MAX_KERNEL_SIZE*MAX_KERNEL_SIZE*MAX_IN_CHANNELS][ARRAY_COLS]
);
    localparam MAX_WIN_SIZE  = MAX_KERNEL_SIZE * MAX_KERNEL_SIZE * MAX_IN_CHANNELS;
    localparam MAX_NUM_TILES = (MAX_OUT_CHANNELS + ARRAY_COLS - 1) / ARRAY_COLS;

    // Runtime geometry
    logic [$clog2(MAX_WIN_SIZE+1)-1:0]   weights_per_filter;
    logic [$clog2(MAX_NUM_TILES+1)-1:0]  num_tiles;

    always_comb begin
        weights_per_filter = ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                             ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                             ($clog2(MAX_WIN_SIZE+1))'(in_channels);
        num_tiles          = (out_channels + ARRAY_COLS - 1) / ARRAY_COLS;
    end

    typedef enum logic [2:0] {
        IDLE, REQUEST_BURST, RECEIVING_BURST, TILE_DONE
    } state_t;

    state_t state;

    logic [$clog2(MAX_NUM_TILES+1)-1:0]  tile_counter;
    logic [$clog2(ARRAY_COLS+1)-1:0]     current_col;
    logic [$clog2(MAX_WIN_SIZE+1)-1:0]   burst_count;

    // Latched geometry
    logic [$clog2(MAX_WIN_SIZE+1)-1:0]   weights_per_filter_lat;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels_lat;
    logic [$clog2(MAX_NUM_TILES+1)-1:0]  num_tiles_lat;

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
                        // Latch runtime geometry
                        weights_per_filter_lat <= weights_per_filter;
                        out_channels_lat       <= out_channels;
                        num_tiles_lat          <= num_tiles;
                        current_col            <= 0;
                        state                  <= REQUEST_BURST;
                    end
                end

                REQUEST_BURST: begin
                    automatic int oc, base_addr;
                    oc = int'(tile_counter) * ARRAY_COLS + int'(current_col);
                    if (oc < int'(out_channels_lat)) begin
                        base_addr      = oc * int'(weights_per_filter_lat);
                        sram_addr      <= base_addr;
                        sram_burst_len <= weights_per_filter_lat;
                        sram_read_req  <= 1;
                        burst_count    <= 0;
                        state          <= RECEIVING_BURST;
                    end else begin
                        // Padding column — zero fill
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
