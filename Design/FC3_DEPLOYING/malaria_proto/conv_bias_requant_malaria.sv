// =============================================================================
// conv_bias_requant_malaria.sv
//
// DERIVED FROM: conv_bias_requant_top.sv (conv_bias_requant_integrated)
//
// PURPOSE:
//   The malaria FC3 classification decision only needs to know which of the
//   two output channels (healthy / infected) has the larger score. That
//   comparison must NOT run on the final requantized INT8 output, because
//   requant_scale/shift/ZP are not calibrated for this task and saturation
//   could distort the ordering. Instead we compare the bias-added INT32
//   accumulator values, i.e. the pipeline stage immediately BEFORE
//   requantization.
//
// CHANGE VS ORIGINAL (conv_bias_requant_integrated):
//   Two new output ports added:
//     - pre_requant_valid : pulses once per output tile, same cycle as the
//                            internal bias_output_valid signal
//     - pre_requant_data  : the internal bias_output_data (bias+ReLU sum,
//                            INT32, PRE-requantization)
//   These are plain wires tied to signals that already exist inside the
//   module. NOTHING about the convolution / bias / requantization
//   computation itself was modified. The requantization_block is still
//   instantiated and still drives output_data/output_valid exactly as
//   before, for compatibility with any code that still wants the
//   requantized path.
//
// Module renamed to conv_bias_requant_integrated_malaria to avoid clashing
// with the original module of the same name if both files are ever added
// to the same Quartus project.
// =============================================================================

module conv_bias_requant_integrated_malaria #(
    parameter MAX_KERNEL_SIZE   = 5,
    parameter MAX_WIN_SIZE      = 256,
    parameter MAX_IN_CHANNELS   = 256,
    parameter MAX_OUT_CHANNELS  = 120,
    parameter MAX_INPUT_HEIGHT  = 28,
    parameter MAX_INPUT_WIDTH   = 28,
    parameter TILE_ROWS         = 4,
    parameter ARRAY_COLS        = 4,
    parameter DATA_WIDTH        = 8,
    parameter NUM_IMG_PORTS     = 3,
    parameter MAX_BURST_LEN     = 256,
    parameter TOTAL_ELEMENTS    = 32768
)(
    input  logic clk,
    input  logic rst,

    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    input logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels,
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,
    input logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height,
    input logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width,

    input logic [31:0]          requant_scale,
    input logic [5:0]           requant_shift,
    input logic signed [7:0]    ZP_next,

    input  logic start_pipeline,
    input  logic fc_mode,
    input  logic enable_relu,
    output logic pipeline_done,

    output logic [9:0]
                                               img_sram_addr [NUM_IMG_PORTS],
    output logic                               img_sram_read_req [NUM_IMG_PORTS],
    input  logic signed [DATA_WIDTH-1:0]       img_sram_data [NUM_IMG_PORTS],
    input  logic                               img_sram_valid [NUM_IMG_PORTS],

    output logic [$clog2(MAX_OUT_CHANNELS*MAX_WIN_SIZE)-1:0]
                                               weight_sram_addr,
    output logic [$clog2(MAX_BURST_LEN+1)-1:0] weight_sram_burst_len,
    output logic                                weight_sram_read_req,
    input  logic signed [DATA_WIDTH-1:0]        weight_sram_data,
    input  logic                                weight_sram_valid,
    input  logic                                weight_sram_burst_done,

    output logic [$clog2(MAX_OUT_CHANNELS)-1:0] bias_sram_addr,
    output logic [$clog2(MAX_BURST_LEN+1)-1:0]  bias_sram_burst_len,
    output logic                                  bias_sram_read_req,
    input  logic signed [31:0]                   bias_sram_data,
    input  logic                                  bias_sram_valid,
    input  logic                                  bias_sram_burst_done,

    output logic output_valid,
    output logic signed [7:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(MAX_OUT_CHANNELS)-1:0]                 output_channel_start,
    output logic [$clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH)-1:0] output_window_idx_start,

    // ---- NEW: pre-requantization tap (bias-added INT32 accumulator) -------
    output logic pre_requant_valid,
    output logic signed [31:0] pre_requant_data [TILE_ROWS][ARRAY_COLS]
);

    localparam WIN_IDX_W = (MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH > 1)
                           ? $clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH) : 1;

    // =========================================================================
    // Inter-module signals (unchanged from original)
    // =========================================================================
    logic conv_done;
    logic conv_output_valid;
    logic signed [4*DATA_WIDTH-1:0] conv_output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(MAX_OUT_CHANNELS)-1:0] conv_channel_start;
    logic [WIN_IDX_W-1:0]               conv_window_idx_start;

    logic bias_output_valid;
    logic signed [31:0] bias_output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(MAX_OUT_CHANNELS)-1:0] bias_channel_start;
    logic [$clog2(1024)-1:0]             bias_window_idx_start;

    logic requant_start;
    assign requant_start = bias_output_valid;

    logic signed [7:0] requant_output [TILE_ROWS][ARRAY_COLS];

    // ---- NEW: direct tap, zero added logic ---------------------------------
    assign pre_requant_valid = bias_output_valid;
    assign pre_requant_data  = bias_output_data;

    // =========================================================================
    // PIPELINE CONTROL FSM (unchanged from original)
    // =========================================================================
    typedef enum logic [2:0] {
        IDLE, CONV_RUNNING, WAITING_FINAL_OUTPUT, DONE
    } pipeline_state_t;

    pipeline_state_t state;

    logic [7:0] conv_tiles_sent;
    logic [7:0] output_tiles_received;
    logic [7:0] drain_counter;

    logic [$clog2(MAX_OUT_CHANNELS)-1:0] meta_ch  [1:4];
    logic [WIN_IDX_W-1:0]               meta_win [1:4];
    logic                                meta_valid [1:4];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state                   <= IDLE;
            pipeline_done           <= 1'b0;
            output_valid            <= 1'b0;
            conv_tiles_sent         <= '0;
            output_tiles_received   <= '0;
            drain_counter           <= '0;
            output_channel_start    <= '0;
            output_window_idx_start <= '0;
            for (int i = 1; i <= 4; i++) begin
                meta_ch[i]    <= '0;
                meta_win[i]   <= '0;
                meta_valid[i] <= 1'b0;
            end
        end else begin
            output_valid <= 1'b0;

            if (conv_output_valid)
                conv_tiles_sent <= conv_tiles_sent + 1;

            if (output_valid)
                output_tiles_received <= output_tiles_received + 1;

            meta_valid[1] <= bias_output_valid;
            meta_ch[1]    <= bias_channel_start;
            meta_win[1]   <= WIN_IDX_W'(bias_window_idx_start);

            for (int i = 2; i <= 4; i++) begin
                meta_valid[i] <= meta_valid[i-1];
                meta_ch[i]    <= meta_ch[i-1];
                meta_win[i]   <= meta_win[i-1];
            end

            if (meta_valid[4]) begin
                output_valid            <= 1'b1;
                output_channel_start    <= meta_ch[4];
                output_window_idx_start <= meta_win[4];
            end

            case (state)
                IDLE: begin
                    pipeline_done         <= 1'b0;
                    drain_counter         <= '0;
                    conv_tiles_sent       <= '0;
                    output_tiles_received <= '0;
                    if (start_pipeline)
                        state <= CONV_RUNNING;
                end

                CONV_RUNNING: begin
                    if (conv_done && !conv_output_valid) begin
                        state         <= WAITING_FINAL_OUTPUT;
                        drain_counter <= '0;
                    end
                end

                WAITING_FINAL_OUTPUT: begin
                    drain_counter <= drain_counter + 1;
                    if (output_tiles_received >= conv_tiles_sent && conv_tiles_sent > 0)
                        state <= DONE;
                    if (drain_counter > 50)
                        state <= DONE;
                end

                DONE: begin
                    pipeline_done <= 1'b1;
                    if (!start_pipeline)
                        state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // =========================================================================
    // MODULE 1: CONVOLUTION (unchanged)
    // =========================================================================
    conv_top_v2_hybrid #(
        .MAX_KERNEL_SIZE  (MAX_KERNEL_SIZE),
        .MAX_IN_CHANNELS  (MAX_IN_CHANNELS),
        .MAX_OUT_CHANNELS (MAX_OUT_CHANNELS),
        .MAX_INPUT_HEIGHT (MAX_INPUT_HEIGHT),
        .MAX_INPUT_WIDTH  (MAX_INPUT_WIDTH),
        .TILE_ROWS        (TILE_ROWS),
        .ARRAY_COLS       (ARRAY_COLS),
        .DATA_WIDTH       (DATA_WIDTH),
        .NUM_IMG_PORTS    (NUM_IMG_PORTS),
        .MAX_BURST_LEN    (MAX_BURST_LEN),
        .TOTAL_ELEMENTS   (TOTAL_ELEMENTS)
    ) conv_module (
        .clk                    (clk),
        .rst                    (rst),
        .start_conv             (start_pipeline),
        .conv_done              (conv_done),
        .fc_mode                (fc_mode),
        .kernel_size            (kernel_size),
        .in_channels            (in_channels),
        .out_channels           (out_channels),
        .input_height           (input_height),
        .input_width            (input_width),
        .img_sram_addr          (img_sram_addr),
        .img_sram_read_req      (img_sram_read_req),
        .img_sram_data          (img_sram_data),
        .img_sram_valid         (img_sram_valid),
        .weight_sram_addr       (weight_sram_addr),
        .weight_sram_burst_len  (weight_sram_burst_len),
        .weight_sram_read_req   (weight_sram_read_req),
        .weight_sram_data       (weight_sram_data),
        .weight_sram_valid      (weight_sram_valid),
        .weight_sram_burst_done (weight_sram_burst_done),
        .output_valid           (conv_output_valid),
        .output_data            (conv_output_data),
        .output_channel_start   (conv_channel_start),
        .output_window_idx_start(conv_window_idx_start)
    );

    // =========================================================================
    // MODULE 2: BIAS + RELU (unchanged) -- source of pre_requant_data
    // =========================================================================
    bias_add_relu_streaming #(
        .MAX_OUT_CHANNELS (MAX_OUT_CHANNELS),
        .TILE_ROWS        (TILE_ROWS),
        .ARRAY_COLS       (ARRAY_COLS),
        .DATA_WIDTH       (32),
        .BIAS_WIDTH       (32),
        .MAX_BURST_LEN    (MAX_BURST_LEN)
    ) bias_relu_module (
        .clk                    (clk),
        .rst                    (rst),
        .enable_relu            (enable_relu),
        .out_channels           (out_channels),
        .conv_valid             (conv_output_valid),
        .conv_data              (conv_output_data),
        .conv_channel_start     (conv_channel_start),
        .conv_window_idx_start  (10'(conv_window_idx_start)),
        .bias_sram_addr         (bias_sram_addr),
        .bias_sram_burst_len    (bias_sram_burst_len),
        .bias_sram_read_req     (bias_sram_read_req),
        .bias_sram_data         (bias_sram_data),
        .bias_sram_valid        (bias_sram_valid),
        .bias_sram_burst_done   (bias_sram_burst_done),
        .output_valid           (bias_output_valid),
        .output_data            (bias_output_data),
        .output_channel_start   (bias_channel_start),
        .output_window_idx_start(bias_window_idx_start)
    );

    // =========================================================================
    // MODULE 3: REQUANTIZATION (unchanged, still instantiated for
    // compatibility -- its output is not used for the infected/healthy
    // decision, only pre_requant_data is)
    // =========================================================================
    requantization_block #(
        .sys_row (TILE_ROWS),
        .sys_col (ARRAY_COLS)
    ) requant_module (
        .clk          (clk),
        .rst          (rst),
        .start        (requant_start),
        .requant_scale(requant_scale),
        .requant_shift(requant_shift),
        .ZP_next      (ZP_next),
        .sys_out      (bias_output_data),
        .requant_out  (requant_output)
    );

    always_comb begin
        for (int r = 0; r < TILE_ROWS; r++)
            for (int c = 0; c < ARRAY_COLS; c++)
                output_data[r][c] = requant_output[r][c];
    end

endmodule
