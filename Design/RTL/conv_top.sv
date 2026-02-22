module conv_top_v2_hybrid #(
    parameter MAX_KERNEL_SIZE  = 5,
    parameter MAX_IN_CHANNELS  = 256,
    parameter MAX_OUT_CHANNELS = 120,
    parameter MAX_INPUT_HEIGHT = 28,
    parameter MAX_INPUT_WIDTH  = 28,
    parameter TILE_ROWS        = 8,
    parameter ARRAY_COLS       = 8,
    parameter DATA_WIDTH       = 8,
    parameter NUM_IMG_PORTS    = 5,
    parameter MAX_BURST_LEN    = 256,
    parameter TOTAL_ELEMENTS   = 1024
)(
    input  logic clk,
    input  logic rst,
    input  logic start_conv,
    output logic conv_done,
    input  logic fc_mode,

    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    input logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels,
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,
    input logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height,
    input logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width,

    output logic [9:0]
                                               img_sram_addr    [NUM_IMG_PORTS],
    output logic                               img_sram_read_req[NUM_IMG_PORTS],
    input  logic signed [DATA_WIDTH-1:0]       img_sram_data    [NUM_IMG_PORTS],
    input  logic                               img_sram_valid   [NUM_IMG_PORTS],

    output logic [$clog2(MAX_OUT_CHANNELS*MAX_KERNEL_SIZE*
                          MAX_KERNEL_SIZE*MAX_IN_CHANNELS)-1:0] weight_sram_addr,
    output logic [$clog2(MAX_BURST_LEN+1)-1:0] weight_sram_burst_len,
    output logic                                weight_sram_read_req,
    input  logic signed [DATA_WIDTH-1:0]        weight_sram_data,
    input  logic                                weight_sram_valid,
    input  logic                                weight_sram_burst_done,

    // Top-level output ports unchanged — still 2D unpacked
    output logic                                output_valid,
    output logic signed [4*DATA_WIDTH-1:0]      output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(MAX_OUT_CHANNELS)-1:0] output_channel_start,
    output logic [$clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH)-1:0] output_window_idx_start
);

    localparam MAX_WINDOW_SIZE = MAX_KERNEL_SIZE * MAX_KERNEL_SIZE * MAX_IN_CHANNELS;
    localparam A_FLAT_W        = TILE_ROWS      * MAX_WINDOW_SIZE * DATA_WIDTH;
    localparam B_FLAT_W        = MAX_WINDOW_SIZE * ARRAY_COLS     * DATA_WIDTH;

    // Flat output from systolic — unpacked internally into systolic_out
    localparam C_FLAT_W        = TILE_ROWS * ARRAY_COLS * 4 * DATA_WIDTH;

    logic start_im2col, im2col_tile_ready, im2col_done_all;
    logic signed [DATA_WIDTH-1:0] im2col_tile_data [TILE_ROWS][MAX_WINDOW_SIZE];

    logic start_weight, weight_tile_ready, weight_done_all;
    logic signed [DATA_WIDTH-1:0] weight_tile [MAX_WINDOW_SIZE][ARRAY_COLS];

    logic systolic_load, systolic_valid;

    // 2D unpacked internal wire — used by controller and debug probes
    logic signed [4*DATA_WIDTH-1:0] systolic_out [TILE_ROWS][ARRAY_COLS];

    // 1D packed flat wire from systolic — avoids 2D unpacked port row-swap bug
    logic signed [C_FLAT_W-1:0] c_flat;

    // Unpack c_flat into systolic_out — purely combinational, no port crossing
    always_comb begin
        for (int r = 0; r < TILE_ROWS; r++)
            for (int n = 0; n < ARRAY_COLS; n++)
                systolic_out[r][n] = c_flat[(r*ARRAY_COLS+n)*4*DATA_WIDTH +: 4*DATA_WIDTH];
    end

    logic [$clog2(MAX_WINDOW_SIZE+1)-1:0] window_size;
    always_comb begin
        automatic int ws;
        ws          = int'(kernel_size) * int'(kernel_size) * int'(in_channels);
        window_size = ($clog2(MAX_WINDOW_SIZE+1))'(ws);
    end

    // =========================================================================
    // FLAT 1D packed wires for systolic inputs
    // =========================================================================
    logic [A_FLAT_W-1:0] a_flat;
    logic [B_FLAT_W-1:0] b_flat;

    always_comb begin
        for (int r = 0; r < TILE_ROWS; r++)
            for (int k = 0; k < MAX_WINDOW_SIZE; k++)
                a_flat[(r*MAX_WINDOW_SIZE+k)*DATA_WIDTH +: DATA_WIDTH]
                    = im2col_tile_data[r][k];
        for (int k = 0; k < MAX_WINDOW_SIZE; k++)
            for (int n = 0; n < ARRAY_COLS; n++)
                b_flat[(k*ARRAY_COLS+n)*DATA_WIDTH +: DATA_WIDTH]
                    = weight_tile[k][n];
    end

    // =========================================================================
    // IM2COL
    // =========================================================================
    im2col1_streaming_multiport #(
        .MAX_IMG_W       (MAX_INPUT_WIDTH),
        .MAX_IMG_H       (MAX_INPUT_HEIGHT),
        .MAX_KERNEL_SIZE (MAX_KERNEL_SIZE),
        .STRIDE          (1),
        .TILE_ROWS       (TILE_ROWS),
        .MAX_IN_CHANNELS (MAX_IN_CHANNELS),
        .DATA_WIDTH      (DATA_WIDTH),
        .NUM_PORTS       (NUM_IMG_PORTS)
    ) im2col (
        .clk          (clk),
        .rst          (rst),
        .start        (start_im2col),
        .fc_mode      (fc_mode),
        .kernel_size  (kernel_size),
        .in_channels  (in_channels),
        .input_height (input_height),
        .input_width  (input_width),
        .tile_ready   (im2col_tile_ready),
        .done_all     (im2col_done_all),
        .sram_addr    (img_sram_addr),
        .sram_read_req(img_sram_read_req),
        .sram_data    (img_sram_data),
        .sram_valid   (img_sram_valid),
        .tile_data    (im2col_tile_data)
    );

    // =========================================================================
    // WEIGHT MANAGER
    // =========================================================================
    weight_flatten2_streaming_burst #(
        .MAX_KERNEL_SIZE  (MAX_KERNEL_SIZE),
        .MAX_IN_CHANNELS  (MAX_IN_CHANNELS),
        .MAX_OUT_CHANNELS (MAX_OUT_CHANNELS),
        .ARRAY_COLS       (ARRAY_COLS),
        .DATA_WIDTH       (DATA_WIDTH),
        .MAX_BURST_LEN    (MAX_BURST_LEN)
    ) weight_mgr (
        .clk             (clk),
        .rst             (rst),
        .start           (start_weight),
        .kernel_size     (kernel_size),
        .in_channels     (in_channels),
        .out_channels    (out_channels),
        .tile_ready      (weight_tile_ready),
        .done_all        (weight_done_all),
        .sram_addr       (weight_sram_addr),
        .sram_burst_len  (weight_sram_burst_len),
        .sram_read_req   (weight_sram_read_req),
        .sram_data       (weight_sram_data),
        .sram_valid      (weight_sram_valid),
        .sram_burst_done (weight_sram_burst_done),
        .weight_tile     (weight_tile)
    );

    // =========================================================================
    // CONTROLLER
    // =========================================================================
    conv_controller_v3 #(
        .MAX_KERNEL_SIZE  (MAX_KERNEL_SIZE),
        .MAX_IN_CHANNELS  (MAX_IN_CHANNELS),
        .MAX_OUT_CHANNELS (MAX_OUT_CHANNELS),
        .MAX_INPUT_HEIGHT (MAX_INPUT_HEIGHT),
        .MAX_INPUT_WIDTH  (MAX_INPUT_WIDTH),
        .TILE_ROWS        (TILE_ROWS),
        .ARRAY_COLS       (ARRAY_COLS),
        .DATA_WIDTH       (DATA_WIDTH)
    ) controller (
        .clk                    (clk),
        .rst                    (rst),
        .start_conv             (start_conv),
        .conv_done              (conv_done),
        .fc_mode                (fc_mode),
        .kernel_size            (kernel_size),
        .in_channels            (in_channels),
        .out_channels           (out_channels),
        .input_height           (input_height),
        .input_width            (input_width),
        .start_im2col           (start_im2col),
        .im2col_tile_ready      (im2col_tile_ready),
        .im2col_tile_data       (im2col_tile_data),
        .start_weight           (start_weight),
        .weight_tile_ready      (weight_tile_ready),
        .weight_tile            (weight_tile),
        .systolic_load          (systolic_load),
        .systolic_valid         (systolic_valid),
        .systolic_out           (systolic_out),   // 2D unpacked — internal only
        .output_valid           (output_valid),
        .output_data            (output_data),
        .output_channel_start   (output_channel_start),
        .output_window_idx_start(output_window_idx_start)
    );

    // =========================================================================
    // SYSTOLIC ARRAY
    // a_flat / b_flat: 1D packed inputs (already fixed in previous version)
    // c_flat: 1D packed output (new fix — replaces 2D unpacked c_out port)
    // =========================================================================
    systolic_full #(
        .DATAWIDTH (DATA_WIDTH),
        .M         (TILE_ROWS),
        .K         (MAX_WINDOW_SIZE),
        .N         (ARRAY_COLS)
    ) systolic (
        .clk       (clk),
        .rst       (rst),
        .load_data (systolic_load),
        .k_size    (window_size),
        .a_flat    (a_flat),
        .b_flat    (b_flat),
        .valid_out (systolic_valid),
        .c_flat    (c_flat)        // was .c_out(systolic_out)
    );

endmodule
