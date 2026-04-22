module lenet5_npu_complete #(
    parameter MAX_KERNEL_SIZE   = 5,
    parameter MAX_IN_CHANNELS   = 256,
    parameter MAX_OUT_CHANNELS  = 120,
    parameter MAX_INPUT_HEIGHT  = 28,
    parameter MAX_INPUT_WIDTH   = 28,
    parameter TILE_ROWS         = 4,
    parameter ARRAY_COLS        = 4,
    parameter DATA_WIDTH        = 8,
    parameter NUM_IMG_PORTS     = 3,
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
    input logic [5:0]        requant_shift,
    input logic signed [7:0] ZP_next,

    input logic [$clog2(TOTAL_WEIGHTS+1)-1:0] weight_layer_offset,

    input logic [$clog2(TOTAL_BIASES+1)-1:0]  bias_layer_offset,
   

    input logic [$clog2(TOTAL_WEIGHTS)-1:0] weight_write_addr,
    input logic signed [DATA_WIDTH-1:0]     weight_write_data,
    input logic                             weight_write_enable,
    input logic [$clog2(TOTAL_BIASES)-1:0]  bias_write_addr,
    input logic signed [31:0]               bias_write_data,
    input logic                             bias_write_enable,

    output logic [9:0]                         img_sram_addr [NUM_IMG_PORTS],
    output logic                               img_sram_read_req [NUM_IMG_PORTS],
    input  logic signed [DATA_WIDTH-1:0]       img_sram_data [NUM_IMG_PORTS],
    input  logic                               img_sram_valid [NUM_IMG_PORTS],

    output logic        output_valid,
    output logic [15:0] output_addr,
    output logic signed [7:0] output_data
);

    // =========================================================================
    // Compile-time MAX bounds
    // =========================================================================
    localparam MAX_CONV_OUT_H = MAX_INPUT_HEIGHT - MAX_KERNEL_SIZE + 1;
    localparam MAX_CONV_OUT_W = MAX_INPUT_WIDTH  - MAX_KERNEL_SIZE + 1;
    localparam MAX_CHANNEL_SZ = MAX_CONV_OUT_H * MAX_CONV_OUT_W;
    localparam MAX_POOL_OUT_H = MAX_CONV_OUT_H / 2;
    localparam MAX_POOL_OUT_W = MAX_CONV_OUT_W / 2;

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

    logic conv_wr_en;
    logic [15:0]       conv_wr_addr;
    logic signed [7:0] conv_wr_data;

    logic fc_wr_en;
    logic [15:0]       fc_wr_addr;
    logic signed [7:0] fc_wr_data;

    logic internal_fm_wr_en;
    logic [15:0]       internal_fm_wr_addr;
    logic signed [7:0] internal_fm_wr_data;

    always_comb begin
        if (fc_mode) begin
            internal_fm_wr_en   = fc_wr_en;
            internal_fm_wr_addr = fc_wr_addr;
            internal_fm_wr_data = fc_wr_data;
        end else begin
            internal_fm_wr_en   = conv_wr_en;
            internal_fm_wr_addr = conv_wr_addr;
            internal_fm_wr_data = conv_wr_data;
        end
    end

    logic processor_done_latched;
    logic fm_write_done;

    logic start_pool, pool_started, pool_done, pool_valid;
    logic signed [DATA_WIDTH-1:0] pool_data;
    logic [7:0] pool_channel, pool_row, pool_col;
    logic [15:0] pool_out_addr;

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
    
        .bias_layer_offset      (bias_layer_offset),
       
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
    // CONV TILE WRITER FSM  (active when fc_mode=0)
    // =========================================================================
    typedef enum logic [1:0] { WR_IDLE, WR_WRITING } wr_state_t;
    wr_state_t wr_state;

    logic signed [7:0] tile_buffer [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(MAX_OUT_CHANNELS)-1:0] tile_ch_start;
    logic [$clog2(MAX_CHANNEL_SZ)-1:0]   tile_win_start;
    logic [$clog2(TILE_ROWS)-1:0]        wr_row;
    logic [$clog2(ARRAY_COLS)-1:0]       wr_col;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels_wr;
    logic [$clog2(MAX_CHANNEL_SZ+1)-1:0]   channel_size_wr;

    always_ff @(posedge clk or posedge rst ) begin
        if (rst) begin
            wr_state        <= WR_IDLE;
            wr_row          <= '0;
            wr_col          <= '0;
            conv_wr_en      <= 1'b0;
            conv_wr_addr    <= '0;
            conv_wr_data    <= '0;
            tile_ch_start   <= '0;
            tile_win_start  <= '0;
            out_channels_wr <= '0;
            channel_size_wr <= '0;
            for (int r = 0; r < TILE_ROWS; r++)
                for (int c = 0; c < ARRAY_COLS; c++)
                    tile_buffer[r][c] <= '0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    conv_wr_en <= 1'b0;
                    if (!fc_mode && processor_output_valid) begin
                        tile_buffer     <= processor_output_data;
                        tile_ch_start   <= processor_channel_start;
                        tile_win_start  <= processor_window_idx_start[$clog2(MAX_CHANNEL_SZ)-1:0];
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

                    ch_idx      = tile_ch_start + wr_col;
                    window_idx  = tile_win_start + wr_row;
                    addr        = 16'(ch_idx * channel_size_wr + window_idx);
                    valid_write = (ch_idx < out_channels_wr) &&
                                  (window_idx < channel_size_wr);

                    if (valid_write) begin
                        conv_wr_addr <= addr;
                        conv_wr_data <= tile_buffer[wr_row][wr_col];
                        conv_wr_en   <= 1'b1;
                    end else begin
                        conv_wr_en <= 1'b0;
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
    // FC OUTPUT REGISTER FILE + DRAIN FSM  (active when fc_mode=1)
    // =========================================================================
    logic signed [DATA_WIDTH-1:0]          fc_out_reg [MAX_OUT_CHANNELS];
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] fc_drain_idx;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] fc_out_channels_lat;

    typedef enum logic [1:0] {
        FC_DRAIN_IDLE,
        FC_DRAIN_WAIT,
        FC_DRAIN_WRITE
    } fc_drain_state_t;
    fc_drain_state_t fc_drain_state;

    // =========================================================================
    // EXISTING: fc_drain_started flag
    // Cleared on every start_layer, set when drain enters FC_DRAIN_WRITE.
    // Prevents fm_write_done from asserting before drain has actually run.
    // =========================================================================
    logic fc_drain_started;

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            fc_drain_started <= 1'b0;
        else begin
            if (start_layer)
                fc_drain_started <= 1'b0;
            else if (fc_drain_state == FC_DRAIN_WRITE)
                fc_drain_started <= 1'b1;
        end
    end

    // =========================================================================
    // NEW FIX: fc_layer_in_progress flag
    //
    // Problem: when two FC layers run back-to-back, after FC layer N completes:
    //   fc_drain_state    = FC_DRAIN_IDLE
    //   fc_drain_started  = 1
    //   processor_done_latched = 1
    //   ? fm_write_done glitches HIGH for 1 cycle at start of FC layer N+1
    //     because start_layer clears the registered flags one cycle AFTER
    //     the combinational fm_write_done is evaluated.
    //
    // Fix: fc_layer_in_progress is SET on the same cycle as start_layer
    //      (registered) and CLEARED only when drain fully completes.
    //      fm_write_done is gated by !fc_layer_in_progress so it cannot
    //      assert while a new layer has been requested but not yet finished.
    // =========================================================================
    logic fc_layer_in_progress;

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            fc_layer_in_progress <= 1'b0;
        else begin
            if (start_layer && fc_mode)
                // Mark that a new FC layer has started ? blocks fm_write_done
                fc_layer_in_progress <= 1'b1;
            else if (fc_drain_state == FC_DRAIN_IDLE && fc_drain_started)
                // Drain has returned to IDLE after actually running ? safe to clear
                fc_layer_in_progress <= 1'b0;
        end
    end

    // =========================================================================
    // FC DRAIN FSM
    // =========================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            fc_drain_state      <= FC_DRAIN_IDLE;
            fc_drain_idx        <= '0;
            fc_out_channels_lat <= '0;
            fc_wr_en            <= 1'b0;
            fc_wr_addr          <= '0;
            fc_wr_data          <= '0;
            for (int i = 0; i < MAX_OUT_CHANNELS; i++)
                fc_out_reg[i] <= '0;
        end else begin
            fc_wr_en <= 1'b0;

            case (fc_drain_state)

                FC_DRAIN_IDLE: begin
                    fc_drain_idx <= '0;
                    if (start_layer && fc_mode) begin
                        fc_out_channels_lat <= out_channels;
                        for (int i = 0; i < MAX_OUT_CHANNELS; i++)
                            fc_out_reg[i] <= '0;
                        fc_drain_state <= FC_DRAIN_WAIT;
                    end
                end

                FC_DRAIN_WAIT: begin
                    if (processor_output_valid) begin
                        for (int c = 0; c < ARRAY_COLS; c++) begin
                            automatic int ch;
                            ch = int'(processor_channel_start) + c;
                            if (ch < int'(fc_out_channels_lat))
                                fc_out_reg[ch] <= processor_output_data[0][c];
                        end
                    end
                    if (processor_done_latched)
                        fc_drain_state <= FC_DRAIN_WRITE;
                end

                FC_DRAIN_WRITE: begin
                    if (fc_drain_idx < fc_out_channels_lat) begin
                        fc_wr_en     <= 1'b1;
                        fc_wr_addr   <= 16'(fc_drain_idx);
                        fc_wr_data   <= fc_out_reg[fc_drain_idx];
                        fc_drain_idx <= fc_drain_idx + 1;
                    end else begin
                        fc_wr_en       <= 1'b0;
                        fc_drain_state <= FC_DRAIN_IDLE;
                    end
                end

                default: fc_drain_state <= FC_DRAIN_IDLE;
            endcase
        end
    end

    // =========================================================================
    // processor_done_latched
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

    // =========================================================================
    // fm_write_done
    //
    // Conv : processor done AND tile writer back to IDLE
    // FC   : drain returned to IDLE AND processor done AND drain actually ran
    //        AND fc_layer_in_progress=0 (new layer not still starting up)
    //
    // The fc_layer_in_progress gate is the key fix for FC?FC transitions:
    // it holds fm_write_done LOW for the 1-cycle window between start_layer
    // and when the registered flags (fc_drain_started, processor_done_latched)
    // are cleared, preventing a spurious layer_done pulse.
    // =========================================================================
    assign fm_write_done = !fc_mode
        ? (processor_done_latched && wr_state == WR_IDLE)
        : (fc_drain_state == FC_DRAIN_IDLE
           && processor_done_latched
           && fc_drain_started
           && !fc_layer_in_progress &&!start_layer);   // ? NEW: blocks spurious done on FC?FC

    // =========================================================================
    // POOLING ? conv mode only
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

    avg_pool_2x2_banked_internal_fixed #(
        .DATA_WIDTH       (DATA_WIDTH),
        .MAX_IN_CHANNELS  (MAX_OUT_CHANNELS),
        .MAX_INPUT_HEIGHT (MAX_CONV_OUT_H),
        .MAX_INPUT_WIDTH  (MAX_CONV_OUT_W)
    ) pooling (
        .clk          (clk),
        .rst          (rst),
        .in_channels  (out_channels),
        .input_height (conv_out_h),
        .input_width  (conv_out_w),
        .wr_en        (internal_fm_wr_en),
        .wr_addr      (internal_fm_wr_addr),
        .wr_data      (internal_fm_wr_data),
        .start_pool   (start_pool),
        .rd_valid     (pool_valid),
        .rd_data      (pool_data),
        .rd_channel   (pool_channel),
        .rd_row       (pool_row),
        .rd_col       (pool_col),
        .done         (pool_done)
    );

    // =========================================================================
    // OUTPUT MUX
    // =========================================================================
    assign output_valid = !fc_mode ? pool_valid     : internal_fm_wr_en;
    assign output_addr  = !fc_mode ? pool_out_addr  : internal_fm_wr_addr;
    assign output_data  = !fc_mode ? pool_data[7:0] : internal_fm_wr_data;
    assign layer_done   = !fc_mode ? pool_done      : fm_write_done;

endmodule