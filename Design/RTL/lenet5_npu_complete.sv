module lenet5_npu_complete #(
    parameter MAX_KERNEL_SIZE   = 5,
    parameter MAX_IN_CHANNELS   = 256,
    parameter MAX_OUT_CHANNELS  = 120,
    parameter MAX_INPUT_HEIGHT  = 28,
    parameter MAX_INPUT_WIDTH   = 28,
    parameter TILE_ROWS         = 8,
    parameter ARRAY_COLS        = 8,
    parameter DATA_WIDTH        = 8,
    parameter NUM_IMG_PORTS     = 5,
    parameter MAX_BURST_LEN     = 256,
    parameter MAX_WEIGHTS       = 30720,
    parameter TOTAL_WEIGHTS     = 44190,
    parameter MAX_BIASES        = 120,
    parameter TOTAL_BIASES      = 236,
    parameter TOTAL_ELEMENTS    = 32768
)(
    input  logic clk,
    input  logic rst,
    input  logic start_layer,
    input  logic fc_mode,
    input  logic enable_relu,
    output logic layer_done,

    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    input logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels,
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,
    input logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height,
    input logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width,

    input logic [31:0]       requant_scale,
    input logic [4:0]        requant_shift,
    input logic signed [7:0] ZP_next,

    input logic [$clog2(TOTAL_WEIGHTS+1)-1:0] weight_layer_offset,
    input logic [$clog2(MAX_WEIGHTS+1)-1:0]   weight_layer_total,
    input logic [$clog2(TOTAL_BIASES+1)-1:0]  bias_layer_offset,
    input logic [$clog2(MAX_BIASES+1)-1:0]    bias_layer_total,

    input logic [$clog2(TOTAL_WEIGHTS)-1:0] weight_write_addr,
    input logic signed [DATA_WIDTH-1:0]     weight_write_data,
    input logic                             weight_write_enable,
    input logic [$clog2(TOTAL_BIASES)-1:0]  bias_write_addr,
    input logic signed [31:0]               bias_write_data,
    input logic                             bias_write_enable,

    // Image SRAM (multi-port) — width unified to $clog2(TOTAL_ELEMENTS)
    output logic [9:0] img_sram_addr [NUM_IMG_PORTS],
    output logic                               img_sram_read_req [NUM_IMG_PORTS],
    input  logic signed [DATA_WIDTH-1:0]       img_sram_data [NUM_IMG_PORTS],
    input  logic                               img_sram_valid [NUM_IMG_PORTS],

    output logic        output_valid,
    output logic [15:0] output_addr,
    output logic signed [7:0] output_data
);

    // =========================================================================
    // Compile-time MAX bounds for pooling module sizing
    // =========================================================================
    localparam MAX_CONV_OUT_H  = MAX_INPUT_HEIGHT - MAX_KERNEL_SIZE + 1;
    localparam MAX_CONV_OUT_W  = MAX_INPUT_WIDTH  - MAX_KERNEL_SIZE + 1;
    localparam MAX_CHANNEL_SZ  = MAX_CONV_OUT_H * MAX_CONV_OUT_W;
    localparam MAX_POOL_OUT_H  = MAX_CONV_OUT_H / 2;
    localparam MAX_POOL_OUT_W  = MAX_CONV_OUT_W / 2;

    // =========================================================================
    // Runtime geometry
    // =========================================================================
    logic [$clog2(MAX_CONV_OUT_H+1)-1:0] conv_out_h;
    logic [$clog2(MAX_CONV_OUT_W+1)-1:0] conv_out_w;
    logic [$clog2(MAX_CHANNEL_SZ+1)-1:0] channel_size;
    logic [$clog2(MAX_POOL_OUT_H+1)-1:0] pool_out_h;
    logic [$clog2(MAX_POOL_OUT_W+1)-1:0] pool_out_w;

    assign conv_out_h   = input_height - kernel_size + 1;
    assign conv_out_w   = input_width  - kernel_size + 1;
    assign channel_size = conv_out_h * conv_out_w;
    assign pool_out_h   = conv_out_h >> 1;
    assign pool_out_w   = conv_out_w >> 1;

    // =========================================================================
    // Processor signals
    // =========================================================================
    logic processor_done;
    logic processor_output_valid;
    logic signed [7:0] processor_output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(MAX_OUT_CHANNELS)-1:0]                 processor_channel_start;
    logic [$clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH)-1:0] processor_window_idx_start;

    logic internal_fm_wr_en;
    logic [15:0]       internal_fm_wr_addr;
    logic signed [7:0] internal_fm_wr_data;

    logic processor_done_latched;
    logic fm_write_done;

    logic start_pool, pool_started, pool_done, pool_valid;
    // FIX 2: rd_data is DATA_WIDTH+1:0 from the pool module
    logic signed [DATA_WIDTH-1:0] pool_data;
    logic [7:0] pool_channel, pool_row, pool_col;
    logic [15:0] pool_out_addr;

    logic [MAX_OUT_CHANNELS-1:0] fc_written_mask;

    // =========================================================================
    // LAYER PROCESSOR
    // =========================================================================
    lenet5_layer_processor #(
        .MAX_KERNEL_SIZE  (MAX_KERNEL_SIZE),
        .MAX_IN_CHANNELS  (MAX_IN_CHANNELS),
        .MAX_OUT_CHANNELS (MAX_OUT_CHANNELS),
        .MAX_INPUT_HEIGHT (MAX_INPUT_HEIGHT),
        .MAX_INPUT_WIDTH  (MAX_INPUT_WIDTH),
        .TOTAL_ELEMENTS   (TOTAL_ELEMENTS),
        .TILE_ROWS        (TILE_ROWS),
        .ARRAY_COLS       (ARRAY_COLS),
        .DATA_WIDTH       (DATA_WIDTH),
        .NUM_IMG_PORTS    (NUM_IMG_PORTS),
        .MAX_BURST_LEN    (MAX_BURST_LEN),
        .MAX_WEIGHTS      (MAX_WEIGHTS),
        .TOTAL_WEIGHTS    (TOTAL_WEIGHTS),
        .MAX_BIASES       (MAX_BIASES),
        .TOTAL_BIASES     (TOTAL_BIASES)
    ) layer_processor_inst (
        .clk                    (clk),
        .rst                    (rst),
        .start_layer            (start_layer),
        .fc_mode                (fc_mode),
        .enable_relu            (enable_relu),
        .layer_done             (processor_done),
        .kernel_size            (kernel_size),
        .in_channels            (in_channels),
        .out_channels           (out_channels),
        .input_height           (input_height),
        .input_width            (input_width),
        .requant_scale          (requant_scale),
        .requant_shift          (requant_shift),
        .ZP_next                (ZP_next),
        .weight_layer_offset    (weight_layer_offset),
        .weight_layer_total     (weight_layer_total),
        .bias_layer_offset      (bias_layer_offset),
        .bias_layer_total       (bias_layer_total),
        .weight_write_addr      (weight_write_addr),
        .weight_write_data      (weight_write_data),
        .weight_write_enable    (weight_write_enable),
        .bias_write_addr        (bias_write_addr),
        .bias_write_data        (bias_write_data),
        .bias_write_enable      (bias_write_enable),
        .img_sram_addr          (img_sram_addr),
        .img_sram_read_req      (img_sram_read_req),
        .img_sram_data          (img_sram_data),
        .img_sram_valid         (img_sram_valid),
        .output_valid           (processor_output_valid),
        .output_data            (processor_output_data),
        .output_channel_start   (processor_channel_start),
        .output_window_idx_start(processor_window_idx_start)
    );

    // =========================================================================
    // TILE WRITER FSM
    // =========================================================================
    typedef enum logic [1:0] { WR_IDLE, WR_WRITING } wr_state_t;
    wr_state_t wr_state;

    logic signed [7:0] tile_buffer [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(MAX_OUT_CHANNELS)-1:0]  tile_ch_start;
    logic [$clog2(MAX_CHANNEL_SZ)-1:0]    tile_win_start;
    logic [$clog2(TILE_ROWS)-1:0]         wr_row;
    logic [$clog2(ARRAY_COLS)-1:0]        wr_col;
    logic tile_is_fc_mode;

    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels_wr;
    logic [$clog2(MAX_CHANNEL_SZ+1)-1:0]   channel_size_wr;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_state            <= WR_IDLE;
            wr_row              <= '0;
            wr_col              <= '0;
            internal_fm_wr_en   <= 1'b0;
            internal_fm_wr_addr <= '0;
            internal_fm_wr_data <= '0;
            tile_ch_start       <= '0;
            tile_win_start      <= '0;
            tile_is_fc_mode     <= 1'b0;
            fc_written_mask     <= '0;
            out_channels_wr     <= '0;
            channel_size_wr     <= '0;
            for (int r = 0; r < TILE_ROWS; r++)
                for (int c = 0; c < ARRAY_COLS; c++)
                    tile_buffer[r][c] <= '0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    internal_fm_wr_en <= 1'b0;
                    if (start_layer)
                        fc_written_mask <= '0;
                    if (processor_output_valid) begin
                        tile_buffer     <= processor_output_data;
                        tile_ch_start   <= processor_channel_start;
                        tile_win_start  <= processor_window_idx_start[$clog2(MAX_CHANNEL_SZ)-1:0];
                        tile_is_fc_mode <= fc_mode;
                        out_channels_wr <= out_channels;
                        channel_size_wr <= channel_size;
                        wr_row          <= '0;
                        wr_col          <= '0;
                        wr_state        <= WR_WRITING;
                    end
                end

                WR_WRITING: begin
                    automatic logic [$clog2(MAX_OUT_CHANNELS)-1:0] ch_idx;
                    automatic logic [$clog2(MAX_CHANNEL_SZ)-1:0]   window_idx;
                    automatic logic [15:0] addr;
                    automatic logic valid_write;
                    automatic logic not_duplicate;

                    if (tile_is_fc_mode) begin
                        ch_idx        = tile_ch_start + wr_col;
                        window_idx    = '0;
                        addr          = 16'(ch_idx);
                        not_duplicate = (ch_idx < out_channels_wr) ?
                                        !fc_written_mask[ch_idx] : 1'b0;
                        valid_write   = (wr_row == 0) &&
                                        (ch_idx < out_channels_wr) &&
                                        not_duplicate;
                    end else begin
                        ch_idx        = tile_ch_start + wr_col;
                        window_idx    = tile_win_start + wr_row;
                        addr          = 16'(ch_idx * channel_size_wr + window_idx);
                        valid_write   = (ch_idx < out_channels_wr) &&
                                        (window_idx < channel_size_wr);
                        not_duplicate = 1'b1;
                    end

                    if (valid_write) begin
                        internal_fm_wr_addr <= addr;
                        internal_fm_wr_data <= tile_is_fc_mode ?
                                               tile_buffer[0][wr_col] :
                                               tile_buffer[wr_row][wr_col];
                        internal_fm_wr_en   <= 1'b1;
                        if (tile_is_fc_mode && ch_idx < out_channels_wr)
                            fc_written_mask[ch_idx] <= 1'b1;
                    end else begin
                        internal_fm_wr_en <= 1'b0;
                    end

                    if (wr_col == ARRAY_COLS - 1) begin
                        wr_col <= '0;
                        if (wr_row == TILE_ROWS - 1)
                            wr_state <= WR_IDLE;
                        else
                            wr_row <= wr_row + 1;
                    end else begin
                        wr_col <= wr_col + 1;
                    end
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    // =========================================================================
    // fm_write_done
    // =========================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            processor_done_latched <= 1'b0;
        else begin
            if (start_layer)
                processor_done_latched <= 1'b0;
            else if (processor_done)
                processor_done_latched <= 1'b1;
        end
    end

    assign fm_write_done = processor_done_latched && (wr_state == WR_IDLE);

    // =========================================================================
    // POOLING — gated by !fc_mode
    // FIX 1: pass runtime geometry signals, not MAX parameters
    // =========================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            start_pool   <= 1'b0;
            pool_started <= 1'b0;
        end else begin
            if (start_layer)
                pool_started <= 1'b0;
            if (fm_write_done && !pool_started && !fc_mode) begin
                start_pool   <= 1'b1;
                pool_started <= 1'b1;
            end else begin
                start_pool <= 1'b0;
            end
        end
    end

    assign pool_out_addr = 16'(pool_channel * pool_out_w * pool_out_h +
                               pool_row * pool_out_w + pool_col);

    // FIX 1: MAX_* are compile-time bounds, runtime values passed as ports
    avg_pool_2x2_banked_internal_fixed #(
        .DATA_WIDTH       (DATA_WIDTH),
        .MAX_IN_CHANNELS  (MAX_OUT_CHANNELS),   // compile-time bound
        .MAX_INPUT_HEIGHT (MAX_CONV_OUT_H),      // compile-time bound
        .MAX_INPUT_WIDTH  (MAX_CONV_OUT_W)       // compile-time bound
    ) pooling (
        .clk          (clk),
        .rst          (rst),
        // FIX 1: runtime values passed as ports
        .in_channels  (out_channels),            // actual channels for this layer
        .input_height (conv_out_h),              // actual conv output height
        .input_width  (conv_out_w),              // actual conv output width
        .wr_en        (internal_fm_wr_en),
        .wr_addr      (internal_fm_wr_addr),
        .wr_data      (internal_fm_wr_data),
        .start_pool   (start_pool),
        .rd_valid     (pool_valid),
        .rd_data      (pool_data),               // signed [DATA_WIDTH+1:0]
        .rd_channel   (pool_channel),
        .rd_row       (pool_row),
        .rd_col       (pool_col),
        .done         (pool_done)
    );

    // =========================================================================
    // OUTPUT MUX
    // FIX 2: explicit [7:0] truncation of pool_data (safe: after /4 fits int8)
    // =========================================================================
    assign output_valid = !fc_mode ? pool_valid        : internal_fm_wr_en;
    assign output_addr  = !fc_mode ? pool_out_addr     : internal_fm_wr_addr;
    assign output_data  = !fc_mode ? pool_data[7:0]    : internal_fm_wr_data;
    assign layer_done   = !fc_mode ? pool_done         : fm_write_done;

endmodule
