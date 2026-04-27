// =============================================================================
// DUT (included verbatim so this is a single self-contained file)
// =============================================================================
module bias_add_relu_streaming #(
    parameter MAX_OUT_CHANNELS = 120,
    parameter TILE_ROWS        = 4,
    parameter ARRAY_COLS       = 4,
    parameter DATA_WIDTH       = 32,
    parameter BIAS_WIDTH       = 32,
    parameter MAX_BURST_LEN    = 32
)(
    input  logic clk,
    input  logic rst,
    input  logic enable_relu,

    // Runtime channel count
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,

    // INPUT FROM CONVOLUTION
    input  logic conv_valid,
    input  logic signed [DATA_WIDTH-1:0] conv_data [TILE_ROWS][ARRAY_COLS],
    input  logic [$clog2(MAX_OUT_CHANNELS)-1:0] conv_channel_start,
    input  logic [$clog2(1024)-1:0]             conv_window_idx_start,

    // BURST BIAS SRAM INTERFACE
    output logic [$clog2(MAX_OUT_CHANNELS)-1:0]    bias_sram_addr,
    output logic [$clog2(MAX_BURST_LEN+1)-1:0]    bias_sram_burst_len,
    output logic                                    bias_sram_read_req,
    input  logic signed [BIAS_WIDTH-1:0]           bias_sram_data,
    input  logic                                    bias_sram_valid,
    input  logic                                    bias_sram_burst_done,

    // OUTPUT
    output logic output_valid,
    output logic signed [DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(MAX_OUT_CHANNELS)-1:0] output_channel_start,
    output logic [$clog2(1024)-1:0]             output_window_idx_start
);

    typedef enum logic [2:0] {
        IDLE, REQUEST_BIAS_BURST, RECEIVING_BIAS, APPLYING_BIAS, OUTPUT_DONE
    } state_t;

    state_t state;

    // Buffered conv data
    logic signed [DATA_WIDTH-1:0]       conv_data_buf [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(MAX_OUT_CHANNELS)-1:0] conv_channel_start_buf;
    logic [$clog2(1024)-1:0]            conv_window_idx_start_buf;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels_buf;

    // Bias storage – only ARRAY_COLS values needed at a time
    logic signed [BIAS_WIDTH-1:0] bias_buf [ARRAY_COLS];
    logic [$clog2(ARRAY_COLS+1)-1:0] bias_count;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state                     <= IDLE;
            output_valid              <= 1'b0;
            bias_sram_read_req        <= 1'b0;
            bias_sram_addr            <= '0;
            bias_sram_burst_len       <= '0;
            bias_count                <= '0;
            conv_channel_start_buf    <= '0;
            conv_window_idx_start_buf <= '0;
            out_channels_buf          <= '0;
            output_channel_start      <= '0;
            output_window_idx_start   <= '0;
            for (int r = 0; r < TILE_ROWS; r++)
                for (int c = 0; c < ARRAY_COLS; c++) begin
                    conv_data_buf[r][c] <= '0;
                    output_data[r][c]   <= '0;
                end
            for (int c = 0; c < ARRAY_COLS; c++)
                bias_buf[c] <= '0;
        end else begin
            output_valid       <= 1'b0;
            bias_sram_read_req <= 1'b0;

            case (state)

                IDLE: begin
                    if (conv_valid) begin
                        conv_data_buf             <= conv_data;
                        conv_channel_start_buf    <= conv_channel_start;
                        conv_window_idx_start_buf <= conv_window_idx_start;
                        out_channels_buf          <= out_channels;
                        state                     <= REQUEST_BIAS_BURST;
                    end
                end

                REQUEST_BIAS_BURST: begin
                    automatic logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] remaining;
                    automatic logic [$clog2(ARRAY_COLS+1)-1:0]       num_needed;

                    remaining  = out_channels_buf - conv_channel_start_buf;
                    num_needed = (remaining < ARRAY_COLS) ?
                                 remaining[$clog2(ARRAY_COLS+1)-1:0] :
                                 $clog2(ARRAY_COLS+1)'(ARRAY_COLS);

                    bias_sram_addr      <= conv_channel_start_buf;
                    bias_sram_burst_len <= num_needed;
                    bias_sram_read_req  <= 1'b1;
                    bias_count          <= '0;
                    state               <= RECEIVING_BIAS;
                end

                RECEIVING_BIAS: begin
                    if (bias_sram_valid) begin
                        bias_buf[bias_count] <= bias_sram_data;
                        if (bias_count == bias_sram_burst_len - 1)
                            state <= APPLYING_BIAS;
                        else
                            bias_count <= bias_count + 1;
                    end
                    if (bias_sram_burst_done)
                        state <= APPLYING_BIAS;
                end

                APPLYING_BIAS: begin
                    for (int r = 0; r < TILE_ROWS; r++) begin
                        for (int c = 0; c < ARRAY_COLS; c++) begin
                            automatic logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] ch_idx;
                            automatic logic signed [DATA_WIDTH-1:0]           biased;

                            ch_idx = conv_channel_start_buf + c;

                            if (ch_idx < out_channels_buf) begin
                                biased = conv_data_buf[r][c] + bias_buf[c];
                                if (enable_relu && biased < 0)
                                    output_data[r][c] <= '0;
                                else
                                    output_data[r][c] <= biased;
                            end else begin
                                output_data[r][c] <= conv_data_buf[r][c];
                            end
                        end
                    end
                    output_channel_start    <= conv_channel_start_buf;
                    output_window_idx_start <= conv_window_idx_start_buf;
                    state                   <= OUTPUT_DONE;
                end

                OUTPUT_DONE: begin
                    output_valid <= 1'b1;
                    state        <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule