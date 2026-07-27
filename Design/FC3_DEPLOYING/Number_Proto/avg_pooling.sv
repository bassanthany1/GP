module avg_pool_2x2_banked_internal_fixed #(
    parameter DATA_WIDTH       = 8,
    parameter MAX_IN_CHANNELS  = 120,
    parameter MAX_INPUT_HEIGHT = 24,
    parameter MAX_INPUT_WIDTH  = 24
)(
    input  logic clk,
    input  logic rst,

    // Runtime layer geometry - set by controller before start_pool
    input logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels,
    input logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height,
    input logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width,

    input  logic wr_en,
    input  logic [15:0] wr_addr,
    input  logic signed [DATA_WIDTH-1:0] wr_data,

    input  logic start_pool,

    output logic rd_valid,
    output logic signed [DATA_WIDTH-1:0] rd_data,
    output logic [7:0] rd_channel,
    output logic [7:0] rd_row,
    output logic [7:0] rd_col,
    output logic done
);

    // =========================================================================
    // MAX compile-time constants - used only for BRAM sizing
    // =========================================================================
    localparam MAX_OUT_HEIGHT   = MAX_INPUT_HEIGHT / 2;
    localparam MAX_OUT_WIDTH    = MAX_INPUT_WIDTH  / 2;
    localparam MAX_CHANNEL_SIZE = MAX_INPUT_HEIGHT * MAX_INPUT_WIDTH;
    localparam MAX_TOTAL_SIZE   = MAX_IN_CHANNELS  * MAX_CHANNEL_SIZE;

    // =========================================================================
    // Runtime geometry wires
    // =========================================================================
    logic [$clog2(MAX_OUT_HEIGHT+1)-1:0]   out_height;
    logic [$clog2(MAX_OUT_WIDTH+1)-1:0]    out_width;
    logic [$clog2(MAX_CHANNEL_SIZE+1)-1:0] channel_size;
    logic [$clog2(MAX_TOTAL_SIZE+1)-1:0]   total_size;

    assign out_height   = input_height >> 1;
    assign out_width    = input_width  >> 1;
    assign channel_size = input_height * input_width;
    assign total_size   = in_channels  * channel_size;

    // Registered - latched at start_pool
    // FIX: input_height_r REMOVED (was latched but never read)
    logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels_r;
    logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width_r;
    logic [$clog2(MAX_OUT_HEIGHT+1)-1:0]   out_height_r;
    logic [$clog2(MAX_OUT_WIDTH+1)-1:0]    out_width_r;
    logic [$clog2(MAX_CHANNEL_SIZE+1)-1:0] channel_size_r;
    logic [$clog2(MAX_TOTAL_SIZE+1)-1:0]   total_size_r;

    // =========================================================================
    // BRAM - allocated to MAX size at compile time
    // =========================================================================
    (* ram_style = "block" *)
    (* ramstyle = "M20K" *)
    (* syn_ramstyle = "block_ram" *)
    logic signed [DATA_WIDTH-1:0] ram_flat [0:MAX_TOTAL_SIZE-1];

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_RD_TL,
        ST_RD_TR,
        ST_RD_BL,
        ST_RD_BR,
        ST_OUTPUT
    } state_t;

    state_t state;

    logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  ch_cnt,  ch_cnt_next;
    logic [$clog2(MAX_OUT_HEIGHT+1)-1:0]   row_cnt, row_cnt_next;
    logic [$clog2(MAX_OUT_WIDTH+1)-1:0]    col_cnt, col_cnt_next;

    logic all_done;

    logic signed [DATA_WIDTH-1:0] val_tl, val_tr, val_bl;
    logic last_output_fired;

    assign all_done = (ch_cnt  == in_channels_r - 1) &&
                      (row_cnt == out_height_r  - 1) &&
                      (col_cnt == out_width_r   - 1);

    // =========================================================================
    // Write Port
    // =========================================================================
    always_ff @(posedge clk) begin
        if (wr_en && wr_addr < total_size)
            ram_flat[wr_addr] <= wr_data;
    end

    // =========================================================================
    // Read Address Generation (combinational)
    // =========================================================================
    logic [15:0] rd_addr;
    logic [15:0] spatial_offset;

    always_comb begin
        spatial_offset = 16'd0;
        case (state)
            ST_RD_TL: spatial_offset = 16'((row_cnt * 2)     * input_width_r + (col_cnt * 2));
            ST_RD_TR: spatial_offset = 16'((row_cnt * 2)     * input_width_r + (col_cnt * 2) + 1);
            ST_RD_BL: spatial_offset = 16'((row_cnt * 2 + 1) * input_width_r + (col_cnt * 2));
            ST_RD_BR: spatial_offset = 16'((row_cnt * 2 + 1) * input_width_r + (col_cnt * 2) + 1);
            default:  spatial_offset = 16'd0;
        endcase
        rd_addr = 16'(ch_cnt * channel_size_r) + spatial_offset;
    end

    logic signed [DATA_WIDTH-1:0] ram_q;
    always_ff @(posedge clk) begin
        if (rd_addr < total_size_r)
            ram_q <= ram_flat[rd_addr];
        else
            ram_q <= '0;
    end

    // =========================================================================
    // Counter Next-State Logic
    // =========================================================================
    always_comb begin
        col_cnt_next = col_cnt;
        row_cnt_next = row_cnt;
        ch_cnt_next  = ch_cnt;

        if (state == ST_OUTPUT && !all_done) begin
            if (col_cnt == out_width_r - 1) begin
                col_cnt_next = '0;
                if (row_cnt == out_height_r - 1) begin
                    row_cnt_next = '0;
                    ch_cnt_next  = ch_cnt + 1;
                end else begin
                    row_cnt_next = row_cnt + 1;
                end
            end else begin
                col_cnt_next = col_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Main FSM
    // =========================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state             <= ST_IDLE;
            ch_cnt            <= '0;
            row_cnt           <= '0;
            col_cnt           <= '0;
            rd_valid          <= 1'b0;
            done              <= 1'b0;
            rd_data           <= '0;
            rd_channel        <= '0;
            rd_row            <= '0;
            rd_col            <= '0;
            val_tl            <= '0;
            val_tr            <= '0;
            val_bl            <= '0;
            last_output_fired <= 1'b0;
            in_channels_r     <= '0;
            // FIX: input_height_r removed
            input_width_r     <= '0;
            out_height_r      <= '0;
            out_width_r       <= '0;
            channel_size_r    <= '0;
            total_size_r      <= '0;
        end else begin
            rd_valid          <= 1'b0;
            done              <= 1'b0;
            last_output_fired <= 1'b0;

            if (last_output_fired)
                done <= 1'b1;

            case (state)
                ST_IDLE: begin
                    if (start_pool) begin
                        in_channels_r  <= in_channels;
                        // FIX: input_height_r not latched (removed)
                        input_width_r  <= input_width;
                        out_height_r   <= out_height;
                        out_width_r    <= out_width;
                        channel_size_r <= channel_size;
                        total_size_r   <= total_size;
                        ch_cnt         <= '0;
                        row_cnt        <= '0;
                        col_cnt        <= '0;
                        state          <= ST_RD_TL;
                    end
                end

                ST_RD_TL: state <= ST_RD_TR;

                ST_RD_TR: begin
                    val_tl <= ram_q;
                    state  <= ST_RD_BL;
                end

                ST_RD_BL: begin
                    val_tr <= ram_q;
                    state  <= ST_RD_BR;
                end

                ST_RD_BR: begin
                    val_bl <= ram_q;
                    state  <= ST_OUTPUT;
                end

                ST_OUTPUT: begin
                    // FIX: pool_sum declared as automatic so it is purely
                    //      combinational within this block - no synthesised FF.
                    automatic logic signed [DATA_WIDTH+3:0] pool_sum;
                    pool_sum = val_tl + val_tr + val_bl + ram_q;
                    rd_data  <= pool_sum >>> 2;

                    rd_channel <= 8'(ch_cnt);
                    rd_row     <= 8'(row_cnt);
                    rd_col     <= 8'(col_cnt);
                    rd_valid   <= 1'b1;

                    col_cnt <= col_cnt_next;
                    row_cnt <= row_cnt_next;
                    ch_cnt  <= ch_cnt_next;

                    if (all_done) begin
                        last_output_fired <= 1'b1;
                        state             <= ST_IDLE;
                    end else begin
                        state <= ST_RD_TL;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule