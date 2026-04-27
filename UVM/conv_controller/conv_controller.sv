module conv_controller_v3 #(
    parameter MAX_KERNEL_SIZE  = 5,
    parameter MAX_WIN_SIZE     = 256,
    parameter MAX_IN_CHANNELS  = 256,
    parameter MAX_OUT_CHANNELS = 120,
    parameter MAX_INPUT_HEIGHT = 28,
    parameter MAX_INPUT_WIDTH  = 28,
    parameter TILE_ROWS        = 4,
    parameter ARRAY_COLS       = 4,
    parameter DATA_WIDTH       = 8
)(
    input  logic clk,
    input  logic rst,
    input  logic start_conv,
    input  logic fc_mode,
    output logic conv_done,

    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,
    input logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height,
    input logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width,

    output logic start_im2col,
    input  logic im2col_tile_ready,

    output logic start_weight,
    input  logic weight_tile_ready,

    output logic systolic_load,
    input  logic systolic_valid,
    input  logic signed [4*DATA_WIDTH-1:0] systolic_out [TILE_ROWS][ARRAY_COLS],

    output logic output_valid,
    output logic signed [4*DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(MAX_OUT_CHANNELS)-1:0]                 output_channel_start,
    output logic [$clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH)-1:0] output_window_idx_start
);

    localparam MAX_OUT_H         = MAX_INPUT_HEIGHT - MAX_KERNEL_SIZE + 1;
    localparam MAX_OUT_W         = MAX_INPUT_WIDTH  - MAX_KERNEL_SIZE + 1;
    localparam MAX_TOTAL_WINDOWS = MAX_OUT_H * MAX_OUT_W;
    localparam MAX_IM2COL_TILES  = (MAX_TOTAL_WINDOWS + TILE_ROWS  - 1) / TILE_ROWS;
    localparam MAX_WEIGHT_TILES  = (MAX_OUT_CHANNELS  + ARRAY_COLS - 1) / ARRAY_COLS;

    // ---------- Runtime geometry (combinational) ----------
    logic [$clog2(MAX_OUT_H+1)-1:0]         output_h;
    logic [$clog2(MAX_OUT_W+1)-1:0]         output_w;
    logic [$clog2(MAX_TOTAL_WINDOWS+1)-1:0] total_windows;
    logic [$clog2(MAX_IM2COL_TILES+1)-1:0]  num_im2col_tiles;
    logic [$clog2(MAX_WEIGHT_TILES+1)-1:0]  num_weight_tiles;

    always_comb begin
        output_h         = input_height - kernel_size + 1;
        output_w         = input_width  - kernel_size + 1;
        total_windows    = output_h * output_w;
        num_im2col_tiles = (total_windows + TILE_ROWS  - 1) / TILE_ROWS;
        num_weight_tiles = (out_channels  + ARRAY_COLS - 1) / ARRAY_COLS;
    end

    // ---------- Latched at start_conv ----------
    // FIX: total_windows_r REMOVED - was latched but never read anywhere
    //      in the FSM. All tile-count logic uses num_im2col_tiles_r and
    //      num_weight_tiles_r, which already encode the window count.
    logic [$clog2(MAX_IM2COL_TILES+1)-1:0]  num_im2col_tiles_r;
    logic [$clog2(MAX_WEIGHT_TILES+1)-1:0]  num_weight_tiles_r;

    typedef enum logic [2:0] {
        IDLE, START_TILES, WAIT_BOTH, COMPUTE, NEXT_TILE, WAIT_IM2COL
    } state_t;

    state_t state;

    logic [$clog2(MAX_WEIGHT_TILES+1)-1:0]  weight_tile_idx;
    logic [$clog2(MAX_IM2COL_TILES+1)-1:0]  im2col_tile_idx;
    logic [$clog2(MAX_OUT_CHANNELS)-1:0]     current_output_channel;
    logic [$clog2(MAX_TOTAL_WINDOWS+1)-1:0]  current_window_idx_start;
    logic weight_has_data, im2col_has_data, fc_mode_latched;

    logic [$clog2(MAX_IM2COL_TILES+1)-1:0] effective_im2col_tiles;
    always_comb
        effective_im2col_tiles = fc_mode_latched ? 1 : num_im2col_tiles_r;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state                    <= IDLE;
            fc_mode_latched          <= 1'b0;
            start_im2col             <= 1'b0;
            start_weight             <= 1'b0;
            systolic_load            <= 1'b0;
            output_valid             <= 1'b0;
            conv_done                <= 1'b0;
            weight_tile_idx          <= '0;
            im2col_tile_idx          <= '0;
            current_output_channel   <= '0;
            current_window_idx_start <= '0;
            output_channel_start     <= '0;
            output_window_idx_start  <= '0;
            weight_has_data          <= 1'b0;
            im2col_has_data          <= 1'b0;
            // FIX: total_windows_r removed from reset list
            num_im2col_tiles_r       <= '0;
            num_weight_tiles_r       <= '0;
            for (int r = 0; r < TILE_ROWS; r++)
                for (int c = 0; c < ARRAY_COLS; c++)
                    output_data[r][c] <= '0;
        end else begin
            start_im2col  <= 1'b0;
            start_weight  <= 1'b0;
            systolic_load <= 1'b0;
            output_valid  <= 1'b0;
            conv_done     <= 1'b0;

            case (state)

                IDLE: begin
                    if (start_conv) begin
                        fc_mode_latched    <= fc_mode;
                        // FIX: total_windows_r assignment removed
                        num_im2col_tiles_r <= num_im2col_tiles;
                        num_weight_tiles_r <= num_weight_tiles;
                        weight_tile_idx    <= '0;
                        im2col_tile_idx    <= '0;
                        weight_has_data    <= 1'b0;
                        im2col_has_data    <= 1'b0;
                        state              <= START_TILES;
                    end
                end

                START_TILES: begin
                    start_weight <= 1'b1;
                    start_im2col <= 1'b1;
                    state        <= WAIT_BOTH;
                end

                WAIT_BOTH: begin
                    if (weight_tile_ready) begin
                        weight_has_data        <= 1'b1;
                        current_output_channel <= weight_tile_idx * ARRAY_COLS;
                    end
                    if (im2col_tile_ready) begin
                        im2col_has_data          <= 1'b1;
                        current_window_idx_start <= im2col_tile_idx * TILE_ROWS;
                    end
                    if ((weight_has_data || weight_tile_ready) &&
                        (im2col_has_data || im2col_tile_ready)) begin
                        systolic_load   <= 1'b1;
                        weight_has_data <= 1'b0;
                        im2col_has_data <= 1'b0;
                        state           <= COMPUTE;
                    end
                end

                COMPUTE: begin
                    if (systolic_valid) begin
                        output_valid            <= 1'b1;
                        output_channel_start    <= current_output_channel;
                        output_window_idx_start <= current_window_idx_start;
                        for (int r = 0; r < TILE_ROWS; r++)
                            for (int c = 0; c < ARRAY_COLS; c++)
                                output_data[r][c] <= systolic_out[r][c];
                        state <= NEXT_TILE;
                    end
                end

                NEXT_TILE: begin
                    if (im2col_tile_idx < effective_im2col_tiles - 1) begin
                        im2col_tile_idx <= im2col_tile_idx + 1;
                        start_im2col    <= 1'b1;
                        state           <= WAIT_IM2COL;
                    end else if (weight_tile_idx < num_weight_tiles_r - 1) begin
                        weight_tile_idx <= weight_tile_idx + 1;
                        im2col_tile_idx <= '0;
                        state           <= START_TILES;
                    end else begin
                        conv_done <= 1'b1;
                        state     <= IDLE;
                    end
                end

                WAIT_IM2COL: begin
                    if (im2col_tile_ready) begin
                        current_window_idx_start <= im2col_tile_idx * TILE_ROWS;
                        systolic_load            <= 1'b1;
                        state                    <= COMPUTE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
interface conv_controller_intf #(
    parameter MAX_KERNEL_SIZE  = 5,
    parameter MAX_WIN_SIZE     = 256,
    parameter MAX_IN_CHANNELS  = 256,
    parameter MAX_OUT_CHANNELS = 120,
    parameter MAX_INPUT_HEIGHT = 28,
    parameter MAX_INPUT_WIDTH  = 28,
    parameter TILE_ROWS        = 4,
    parameter ARRAY_COLS       = 4,
    parameter DATA_WIDTH       = 8
)(
    input logic clk,
    input logic rst
);

    // Control signals
    logic  start_conv;
    logic  fc_mode;
    logic  conv_done;

    // Configuration parameters
    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels;
    logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height;
    logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width;

    // Im2col interface
    logic  start_im2col;
    logic  im2col_tile_ready;

    // Weight interface
    logic  start_weight;
    logic  weight_tile_ready;

    // Systolic array interface
    logic  systolic_load;
    logic  systolic_valid;
    logic signed [4*DATA_WIDTH-1:0] systolic_out [TILE_ROWS][ARRAY_COLS];

    // Output interface
    logic  output_valid;
    logic signed [4*DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(MAX_OUT_CHANNELS)-1:0]                 output_channel_start;
    logic [$clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH)-1:0] output_window_idx_start;

    // Clocking block for driver
    clocking driver_cb @(posedge clk);
        default input #1ns output #1ns;
        output start_conv, fc_mode;
        output kernel_size, out_channels, input_height, input_width;
        input im2col_tile_ready, weight_tile_ready, systolic_valid;
        input systolic_out;
    endclocking

    // Clocking block for monitor
    clocking monitor_cb @(posedge clk);
        default input #1ns output #1ns;
        input start_conv, fc_mode;
        input kernel_size, out_channels, input_height, input_width;
        input start_im2col, im2col_tile_ready;
        input start_weight, weight_tile_ready;
        input systolic_load, systolic_valid, systolic_out;
        input output_valid, output_data, output_channel_start, output_window_idx_start;
        input conv_done;
    endclocking

    // Modports
    modport DRIVER (clocking driver_cb, input clk, rst);
    modport MONITOR (clocking monitor_cb, input clk, rst);

endinterface
interface conv_controller_intf #(
    parameter MAX_KERNEL_SIZE  = 5,
    parameter MAX_WIN_SIZE     = 256,
    parameter MAX_IN_CHANNELS  = 256,
    parameter MAX_OUT_CHANNELS = 120,
    parameter MAX_INPUT_HEIGHT = 28,
    parameter MAX_INPUT_WIDTH  = 28,
    parameter TILE_ROWS        = 4,
    parameter ARRAY_COLS       = 4,
    parameter DATA_WIDTH       = 8
)(
    input logic clk,
    input logic rst
);

    // Control signals
    logic  start_conv;
    logic  fc_mode;
    logic  conv_done;

    // Configuration parameters
    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels;
    logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height;
    logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width;

    // Im2col interface
    logic  start_im2col;
    logic  im2col_tile_ready;

    // Weight interface
    logic  start_weight;
    logic  weight_tile_ready;

    // Systolic array interface
    logic  systolic_load;
    logic  systolic_valid;
    logic signed [4*DATA_WIDTH-1:0] systolic_out [TILE_ROWS][ARRAY_COLS];

    // Output interface
    logic  output_valid;
    logic signed [4*DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(MAX_OUT_CHANNELS)-1:0]                 output_channel_start;
    logic [$clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH)-1:0] output_window_idx_start;

    // Clocking block for driver
    clocking driver_cb @(posedge clk);
        default input #1ns output #1ns;
        output start_conv, fc_mode;
        output kernel_size, out_channels, input_height, input_width;
        input im2col_tile_ready, weight_tile_ready, systolic_valid;
        input systolic_out;
    endclocking

    // Clocking block for monitor
    clocking monitor_cb @(posedge clk);
        default input #1ns output #1ns;
        input start_conv, fc_mode;
        input kernel_size, out_channels, input_height, input_width;
        input start_im2col, im2col_tile_ready;
        input start_weight, weight_tile_ready;
        input systolic_load, systolic_valid, systolic_out;
        input output_valid, output_data, output_channel_start, output_window_idx_start;
        input conv_done;
    endclocking

    // Modports
    modport DRIVER (clocking driver_cb, input clk, rst);
    modport MONITOR (clocking monitor_cb, input clk, rst);

endinterface
