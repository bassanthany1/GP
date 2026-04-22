// im2col1_streaming_multiport - FIXED
// Warnings fixed:
//   [Synth 8-6014] Unused sequential element addr_row_reg was removed  -> line 157
//   [Synth 8-6014] Unused sequential element addr_elem_reg was removed -> line 158
// Root cause: addr_row and addr_elem were registered but never read back;
//   all address generation uses local 'temp_row'/'temp_elem' variables.
// Fix: Remove addr_row and addr_elem registers entirely.
//   The local automatic variables (temp_row, temp_elem) already do the job.
//   fc_mode path never used addr_row (it always wrote row 0).
//   conv path used temp_row/temp_elem exclusively.
// Tile-data write path: use the registered wr_en/wr_row/wr_col/wr_dat
//   scheme from doc-24 so the distributed-RAM write port is driven by FFs
//   (eliminates Vivado [Synth 8-5788] set/reset on distributed RAM).

module im2col1_streaming_multiport #(
    parameter MAX_IMG_W       = 28,
    parameter MAX_IMG_H       = 28,
    parameter MAX_KERNEL_SIZE = 5,
    parameter MAX_WIN_SIZE    = 256,
    parameter STRIDE          = 1,
    parameter TILE_ROWS       = 4,
    parameter MAX_IN_CHANNELS = 256,
    parameter DATA_WIDTH      = 8,
    parameter NUM_PORTS       = 3
)(
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic fc_mode,

    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0] kernel_size,
    input logic [$clog2(MAX_IN_CHANNELS+1)-1:0] in_channels,
    input logic [$clog2(MAX_IMG_H+1)-1:0]       input_height,
    input logic [$clog2(MAX_IMG_W+1)-1:0]       input_width,

    output logic tile_ready,
    output logic done_all,

    output logic [9:0] sram_addr    [NUM_PORTS],
    output logic       sram_read_req[NUM_PORTS],
    input  logic signed [DATA_WIDTH-1:0] sram_data [NUM_PORTS],
    input  logic        sram_valid   [NUM_PORTS],

    output logic signed [DATA_WIDTH-1:0] tile_data [TILE_ROWS][MAX_WIN_SIZE]
);
    localparam MAX_OUT_W        = (MAX_IMG_W - MAX_KERNEL_SIZE) / STRIDE + 1;
    localparam MAX_OUT_H        = (MAX_IMG_H - MAX_KERNEL_SIZE) / STRIDE + 1;
    localparam MAX_TOTAL_WIN    = MAX_OUT_W * MAX_OUT_H;
    localparam MAX_NUM_TILES    = (MAX_TOTAL_WIN + TILE_ROWS - 1) / TILE_ROWS;
    localparam MAX_PIX_PER_TILE = TILE_ROWS * MAX_WIN_SIZE;

    // -------------------------------------------------------------------------
    // Runtime geometry - combinational, sampled only at start pulse
    // -------------------------------------------------------------------------
    logic [$clog2(MAX_OUT_W+1)-1:0]     out_w;
    logic [$clog2(MAX_OUT_H+1)-1:0]     out_h;
    logic [$clog2(MAX_TOTAL_WIN+1)-1:0] total_windows;
    logic [$clog2(MAX_NUM_TILES+1)-1:0] num_tiles;

    always_comb begin
        if (fc_mode) begin
            out_w         = 1;
            out_h         = 1;
            total_windows = TILE_ROWS;
            num_tiles     = 1;
        end else begin
            out_w         = ($clog2(MAX_OUT_W+1))'(input_width  - kernel_size + 1);
            out_h         = ($clog2(MAX_OUT_H+1))'(input_height - kernel_size + 1);
            total_windows = out_h * out_w;
            num_tiles     = (total_windows + TILE_ROWS - 1) / TILE_ROWS;
        end
    end

    typedef enum logic [1:0] { IDLE, PROCESSING } state_t;
    state_t state;

    logic [$clog2(MAX_NUM_TILES+1)-1:0]   tile_counter;
    logic                                  fc_mode_latched;

    // Address-generation counters
    // FIX: addr_row and addr_elem REMOVED - they were never read back;
    //      all address loops use local automatic temp variables instead.
    logic [$clog2(MAX_PIX_PER_TILE+1)-1:0] addr_pixel_count;
    logic [$clog2(MAX_OUT_H+1)-1:0]         addr_wy;
    logic [$clog2(MAX_OUT_W+1)-1:0]         addr_wx;
    logic [$clog2(MAX_TOTAL_WIN+1)-1:0]     addr_window_idx;
    logic [$clog2(MAX_IN_CHANNELS+1)-1:0]   addr_c;
    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]   addr_ky, addr_kx;

    // Data-reception counters
    logic [$clog2(MAX_PIX_PER_TILE+1)-1:0] data_pixel_count;
    logic [$clog2(TILE_ROWS+1)-1:0]         data_row;
    logic [$clog2(MAX_WIN_SIZE+1)-1:0]      data_elem;

    // Latched geometry
    logic [$clog2(MAX_WIN_SIZE+1)-1:0]      window_size_lat;
    logic [$clog2(MAX_OUT_W+1)-1:0]         out_w_lat;
    logic [$clog2(MAX_TOTAL_WIN+1)-1:0]     total_windows_lat;
    logic [$clog2(MAX_NUM_TILES+1)-1:0]     num_tiles_lat;

    logic [$clog2(MAX_PIX_PER_TILE+1)-1:0]  expected_pixels_reg;

    logic addr_done, data_done;
    always_comb begin
        addr_done = (addr_pixel_count >= expected_pixels_reg);
        data_done = (data_pixel_count >= expected_pixels_reg);
    end

    // -------------------------------------------------------------------------
    // FIX: tile_data backed by distributed RAM with NO async reset.
    // Write port driven by registered wr_en/wr_row/wr_col/wr_dat signals
    // to avoid [Synth 8-5788] "has both Set and reset with same priority".
    // -------------------------------------------------------------------------
    (* ram_style = "distributed" *)
    logic signed [DATA_WIDTH-1:0] tile_data_r [TILE_ROWS][MAX_WIN_SIZE];

    assign tile_data = tile_data_r;

    // Registered write-port signals (driven by FSM, consumed by RAM process)
    logic                              wr_en  [NUM_PORTS];
    logic [$clog2(TILE_ROWS+1)-1:0]    wr_row [NUM_PORTS];
    logic [$clog2(MAX_WIN_SIZE+1)-1:0] wr_col [NUM_PORTS];
    logic signed [DATA_WIDTH-1:0]      wr_dat [NUM_PORTS];

    // Distributed-RAM write process - clock only, no reset
    always_ff @(posedge clk) begin
        for (int p = 0; p < NUM_PORTS; p++) begin
            if (wr_en[p])
                tile_data_r[wr_row[p]][wr_col[p]] <= wr_dat[p];
        end
    end

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state               <= IDLE;
            tile_counter        <= 0;
            fc_mode_latched     <= 0;
            tile_ready          <= 0;
            done_all            <= 0;
            addr_pixel_count    <= 0;
            addr_wy             <= 0;
            addr_wx             <= 0;
            addr_window_idx     <= 0;
            addr_c              <= 0;
            addr_ky             <= 0;
            addr_kx             <= 0;
            data_pixel_count    <= 0;
            data_row            <= 0;
            data_elem           <= 0;
            window_size_lat     <= 0;
            out_w_lat           <= 0;
            total_windows_lat   <= 0;
            num_tiles_lat       <= 0;
            expected_pixels_reg <= 0;
            for (int p = 0; p < NUM_PORTS; p++) begin
                sram_read_req[p] <= 0;
                sram_addr[p]     <= 0;
                wr_en[p]         <= 0;
                wr_row[p]        <= 0;
                wr_col[p]        <= 0;
                wr_dat[p]        <= '0;
            end
        end else begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                sram_read_req[p] <= 0;
                wr_en[p]         <= 0;
            end
            tile_ready <= 0;

            case (state)

                // --------------------------------------------------------------
                IDLE: begin
                    if (start && tile_counter < num_tiles) begin
                        fc_mode_latched <= fc_mode;

                        window_size_lat   <= ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                                             ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                                             ($clog2(MAX_WIN_SIZE+1))'(in_channels);
                        out_w_lat         <= out_w;
                        total_windows_lat <= total_windows;
                        num_tiles_lat     <= num_tiles;

                        if (fc_mode) begin
                            expected_pixels_reg <= ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                                                   ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                                                   ($clog2(MAX_WIN_SIZE+1))'(in_channels);
                        end else begin
                            automatic int wins_this_tile;
                            wins_this_tile = (tile_counter == num_tiles - 1)
                                ? int'(total_windows - tile_counter * TILE_ROWS)
                                : TILE_ROWS;
                            expected_pixels_reg <=
                                ($clog2(MAX_PIX_PER_TILE+1))'(wins_this_tile) *
                                (($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                                 ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                                 ($clog2(MAX_WIN_SIZE+1))'(in_channels));
                        end

                        addr_pixel_count <= 0;
                        addr_c           <= 0;
                        addr_ky          <= 0;
                        addr_kx          <= 0;

                        if (!fc_mode) begin
                            addr_window_idx <= tile_counter * TILE_ROWS;
                            addr_wy         <= (tile_counter * TILE_ROWS) / out_w;
                            addr_wx         <= (tile_counter * TILE_ROWS) % out_w;
                        end

                        data_pixel_count <= 0;
                        data_row         <= 0;
                        data_elem        <= 0;
                        done_all         <= 0;
                        state            <= PROCESSING;
                    end
                end

                // --------------------------------------------------------------
                PROCESSING: begin

                    // -- Address generation ------------------------------------
                    if (!addr_done) begin
                        if (fc_mode_latched) begin
                            automatic int can_issue;
                            can_issue = int'(window_size_lat) - int'(addr_pixel_count);
                            if (can_issue > NUM_PORTS) can_issue = NUM_PORTS;
                            for (int p = 0; p < NUM_PORTS; p++) begin
                                if (p < can_issue) begin
                                    sram_addr[p]     <= 10'(addr_pixel_count + p);
                                    sram_read_req[p] <= 1;
                                end
                            end
                            addr_pixel_count <= addr_pixel_count + can_issue;
                        end else begin
                            // FIX: use purely local automatic variables;
                            //      addr_row and addr_elem registers are gone.
                            automatic logic [$clog2(TILE_ROWS+1)-1:0]       temp_row;
                            automatic logic [$clog2(MAX_WIN_SIZE+1)-1:0]    temp_elem;
                            automatic logic [$clog2(MAX_OUT_H+1)-1:0]       temp_wy;
                            automatic logic [$clog2(MAX_OUT_W+1)-1:0]       temp_wx;
                            automatic logic [$clog2(MAX_TOTAL_WIN+1)-1:0]   temp_window_idx;
                            automatic logic [$clog2(MAX_IN_CHANNELS+1)-1:0] temp_c;
                            automatic logic [$clog2(MAX_KERNEL_SIZE+1)-1:0] temp_ky, temp_kx;
                            automatic int pixels_to_request;

                            // Seed from registered state
                            temp_wy           = addr_wy;
                            temp_wx           = addr_wx;
                            temp_window_idx   = addr_window_idx;
                            temp_c            = addr_c;
                            temp_ky           = addr_ky;
                            temp_kx           = addr_kx;
                            // temp_row/temp_elem start at 0 each call because
                            // they are re-derived from the window traversal;
                            // data_row/data_elem track the receive side.
                            // For address generation the row/elem within the
                            // current burst window are implicit in temp_*.
                            temp_row          = '0;   // unused except for inner tracking
                            temp_elem         = '0;
                            pixels_to_request = 0;

                            for (int p = 0; p < NUM_PORTS; p++) begin
                                if (addr_pixel_count + pixels_to_request < expected_pixels_reg) begin
                                    if (temp_window_idx < total_windows_lat) begin
                                        automatic int iy, ix, flat_idx;
                                        iy       = int'(temp_wy) * STRIDE + int'(temp_ky);
                                        ix       = int'(temp_wx) * STRIDE + int'(temp_kx);
                                        flat_idx = int'(temp_c) * int'(input_height) *
                                                   int'(input_width) +
                                                   iy * int'(input_width) + ix;
                                        sram_addr[p]     <= flat_idx;
                                        sram_read_req[p] <= 1;
                                    end
                                    pixels_to_request++;

                                    if (temp_kx == kernel_size - 1) begin
                                        temp_kx = 0;
                                        if (temp_ky == kernel_size - 1) begin
                                            temp_ky = 0;
                                            if (temp_c == in_channels - 1) begin
                                                temp_c    = 0;
                                                temp_elem = 0;
                                                if (temp_wx == out_w_lat - 1) begin
                                                    temp_wx = 0;
                                                    temp_wy = temp_wy + 1;
                                                end else begin
                                                    temp_wx = temp_wx + 1;
                                                end
                                                temp_window_idx = temp_window_idx + 1;
                                                temp_row        = temp_row + 1;
                                            end else begin
                                                temp_c    = temp_c + 1;
                                                temp_elem = temp_elem + 1;
                                            end
                                        end else begin
                                            temp_ky   = temp_ky + 1;
                                            temp_elem = temp_elem + 1;
                                        end
                                    end else begin
                                        temp_kx   = temp_kx + 1;
                                        temp_elem = temp_elem + 1;
                                    end
                                end
                            end

                            addr_pixel_count <= addr_pixel_count + pixels_to_request;
                            addr_wy          <= temp_wy;
                            addr_wx          <= temp_wx;
                            addr_window_idx  <= temp_window_idx;
                            addr_c           <= temp_c;
                            addr_ky          <= temp_ky;
                            addr_kx          <= temp_kx;
                        end
                    end

                    // -- Data reception ----------------------------------------
                    if (!data_done) begin
                        if (fc_mode_latched) begin
                            automatic logic [$clog2(MAX_WIN_SIZE+1)-1:0] temp_elem;
                            automatic int valid_count;
                            temp_elem   = data_elem;
                            valid_count = 0;
                            for (int p = 0; p < NUM_PORTS; p++) begin
                                if (sram_valid[p] && temp_elem < window_size_lat) begin
                                    wr_en[p]  <= 1;
                                    wr_row[p] <= '0;
                                    wr_col[p] <= temp_elem;
                                    wr_dat[p] <= sram_data[p];
                                    valid_count++;
                                    temp_elem++;
                                end
                            end
                            data_pixel_count <= data_pixel_count + valid_count;
                            data_elem        <= temp_elem;
                            if (temp_elem >= window_size_lat && data_row == 0)
                                data_row <= 1;
                        end else begin
                            automatic int valid_count;
                            automatic logic [$clog2(TILE_ROWS+1)-1:0]    temp_row;
                            automatic logic [$clog2(MAX_WIN_SIZE+1)-1:0] temp_elem;
                            valid_count = 0;
                            temp_row    = data_row;
                            temp_elem   = data_elem;
                            for (int p = 0; p < NUM_PORTS; p++) begin
                                if (sram_valid[p] &&
                                    data_pixel_count + valid_count < expected_pixels_reg) begin
                                    wr_en[p]  <= 1;
                                    wr_row[p] <= temp_row;
                                    wr_col[p] <= temp_elem;
                                    wr_dat[p] <= sram_data[p];
                                    valid_count++;
                                    if (temp_elem == window_size_lat - 1) begin
                                        temp_elem = 0;
                                        temp_row  = temp_row + 1;
                                    end else begin
                                        temp_elem = temp_elem + 1;
                                    end
                                end
                            end
                            data_pixel_count <= data_pixel_count + valid_count;
                            data_row         <= temp_row;
                            data_elem        <= temp_elem;
                        end
                    end

                    // -- Completion --------------------------------------------
                    if (addr_done && data_done) begin
                        tile_ready <= 1;
                        if (tile_counter == num_tiles_lat - 1) begin
                            done_all     <= 1;
                            tile_counter <= 0;
                        end else begin
                            done_all     <= 0;
                            tile_counter <= tile_counter + 1;
                        end
                        state <= IDLE;
                    end
                end

            endcase
        end
    end

endmodule