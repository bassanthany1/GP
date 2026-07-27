/*// requantization_block - FIXED
// Warnings fixed:
//   [Synth 8-6014] Unused sequential element row_loop[*].col_loop[*].shift_reg2_reg
//   [Synth 8-6014] Unused sequential element row_loop[*].col_loop[*].mult_res_reg_reg
//
// Root cause (shift_reg2_reg):
//   shift_reg2 was registered (pipelined copy of shift_reg) but Stage 3 read
//   shift_reg directly instead of shift_reg2, making shift_reg2 dead.
//
// Root cause (mult_res_reg_reg):
//   mult_res_reg was assigned in Stage 1 but in some elements the synthesiser
//   found that round_bias_reg (Stage 2) read the combinational expression
//   mult_res >= 0 directly rather than mult_res_reg, making those FF copies
//   appear unused.
//
// Fix (from doc-25):
//   Five clean pipeline stages, each a separate always_ff:
//     Stage 1: mult_res_reg  = buffer * scale  (64-bit)
//     Stage 2: round_bias_reg = f(mult_res_reg) ; shift_reg2 pipelined here
//     Stage 3: shift_res_reg = (mult_res_reg + round_bias_reg) >>> shift_reg2
//     Stage 4: final_res_reg = shift_res_reg + ZP
//     Stage 5: requant_out   = saturate(final_res_reg)
//   Stage 3 now reads mult_res_reg AND shift_reg2 (both FFs become live).
//   Stage 2 reads mult_res_reg for the sign test (mult_res_reg becomes live).
//   No functional change vs the original 4-stage intent.

module requantization_block #(
    parameter sys_row = 4,
    parameter sys_col = 4
)(
    input  logic clk,
    input  logic rst,
    input  logic start,

    input  logic [31:0]          requant_scale,
    input  logic [5:0]           requant_shift,
    input  logic signed [7:0]    ZP_next,

    input  logic signed [31:0] sys_out     [0:sys_row-1][0:sys_col-1],
    output logic signed  [7:0] requant_out [0:sys_row-1][0:sys_col-1]
);

    // =========================================================================
    // INPUT BUFFER - latched on start
    // =========================================================================
    logic signed [31:0] buffer [0:sys_row-1][0:sys_col-1];

    logic [31:0]       scale_reg;
  logic [5:0]        shift_reg;
    logic signed [7:0] zp_reg;

    genvar ro, co;
    generate
        for (ro = 0; ro < sys_row; ro++) begin : ro_loop
            for (co = 0; co < sys_col; co++) begin : co_loop
                always_ff @(posedge clk or posedge rst) begin
                    if (rst)        buffer[ro][co] <= 32'd0;
                    else if (start) buffer[ro][co] <= sys_out[ro][co];
                end
            end
        end
    endgenerate

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            scale_reg <= 32'd1;
            shift_reg <= 6'd0;
            zp_reg    <= 8'd0;
        end else if (start) begin
            scale_reg <= requant_scale;
            shift_reg <= requant_shift;
            zp_reg    <= ZP_next;
        end
    end

    // =========================================================================
    // PIPELINE - 5 stages per element
    // =========================================================================
    genvar row, c;
    generate
        for (row = 0; row < sys_row; row++) begin : row_loop
            for (c = 0; c < sys_col; c++) begin : col_loop

                // -----------------------------------------------------------
                // Stage 1: multiply
                //   buffer (INT32) x scale (UINT32) -> 64-bit signed result
                //   Sign-extend buffer to 64 bits; zero-extend scale to 64 bits.
                // -----------------------------------------------------------
             (* keep = "true" *)     logic signed [63:0] mult_res_reg;

                always_ff @(posedge clk or posedge rst) begin
                    if (rst)
                        mult_res_reg <= '0;
                    else
                        mult_res_reg <= $signed({{32{buffer[row][c][31]}},
                                                    buffer[row][c]})
                                      * $signed({1'b0, scale_reg});
                end

                // -----------------------------------------------------------
                // Stage 2: compute round bias AND pipeline the shift value.
                //
                // FIX: round_bias_reg reads mult_res_reg (a settled FF), so
                //      mult_res_reg is provably live at this stage.
                // FIX: shift_reg2 is pipelined here so Stage 3 uses the
                //      temporally-correct shift, making shift_reg2 live.
                // -----------------------------------------------------------
                logic signed [63:0] round_bias_reg;
                 (* keep = "true" *)  logic [5:0] shift_reg2;
                always_ff @(posedge clk or posedge rst) begin
                    if (rst) begin
                        round_bias_reg <= '0;
                        shift_reg2     <= '0;
                    end else begin
                        // Pipeline the shift for temporal consistency
                        shift_reg2 <= shift_reg;

                        if (shift_reg == 0) begin
                            round_bias_reg <= '0;
                        end else begin
                            // FIX: reads mult_res_reg (not the combinational
                            //      multiply expression) so Stage 1 FF is live
                            round_bias_reg <= (mult_res_reg >= 0)
                                ?  (64'sd1 <<< (shift_reg - 1))
                                : ((64'sd1 <<< (shift_reg - 1)) - 64'sd1);
                        end
                    end
                end

                // -----------------------------------------------------------
                // Stage 3: arithmetic right-shift with rounding.
                //
                // FIX: uses shift_reg2 (pipelined value) NOT the live shift_reg.
                //      Both mult_res_reg and shift_reg2 are read here,
                //      confirming they are live and will not be pruned.
                // -----------------------------------------------------------
                logic signed [31:0] shift_res_reg;

                always_ff @(posedge clk or posedge rst) begin
                    if (rst)
                        shift_res_reg <= '0;
                    else
                        shift_res_reg <=
                            32'((mult_res_reg + round_bias_reg) >>> shift_reg2);
                end

                // -----------------------------------------------------------
                // Stage 4: add zero point
                // -----------------------------------------------------------
                logic signed [31:0] final_res_reg;

                always_ff @(posedge clk or posedge rst) begin
                    if (rst)
                        final_res_reg <= '0;
                    else
                        final_res_reg <= shift_res_reg +
                                         $signed({{24{zp_reg[7]}}, zp_reg});
                end

                // -----------------------------------------------------------
                // Stage 5: saturate to int8
                // -----------------------------------------------------------
                always_ff @(posedge clk or posedge rst) begin
                    if (rst)
                        requant_out[row][c] <= '0;
                    else begin
                        if      (final_res_reg > 32'sd127)  requant_out[row][c] <=  8'sd127;
                        else if (final_res_reg < -32'sd128) requant_out[row][c] <= -8'sd128;
                        else                                 requant_out[row][c] <=
                                                                 final_res_reg[7:0];
                    end
                end

            end
        end
    endgenerate

endmodule*/

// requantization_block - FIXED
// Warnings fixed:
//   [Synth 8-6014] Unused sequential element row_loop[*].col_loop[*].shift_reg2_reg
//   [Synth 8-6014] Unused sequential element row_loop[*].col_loop[*].mult_res_reg_reg
//
// Root cause (shift_reg2_reg):
//   shift_reg2 was registered (pipelined copy of shift_reg) but Stage 3 read
//   shift_reg directly instead of shift_reg2, making shift_reg2 dead.
//
// Root cause (mult_res_reg_reg):
//   mult_res_reg was assigned in Stage 1 but in some elements the synthesiser
//   found that round_bias_reg (Stage 2) read the combinational expression
//   mult_res >= 0 directly rather than mult_res_reg, making those FF copies
//   appear unused.
//
// Fix (from doc-25):
//   Five clean pipeline stages, each a separate always_ff:
//     Stage 1: mult_res_reg  = buffer * scale  (64-bit)
//     Stage 2: round_bias_reg = f(mult_res_reg) ; shift_reg2 pipelined here
//     Stage 3: shift_res_reg = (mult_res_reg + round_bias_reg) >>> shift_reg2
//     Stage 4: final_res_reg = shift_res_reg + ZP
//     Stage 5: requant_out   = saturate(final_res_reg)
//   Stage 3 now reads mult_res_reg AND shift_reg2 (both FFs become live).
//   Stage 2 reads mult_res_reg for the sign test (mult_res_reg becomes live).
//   No functional change vs the original 4-stage intent.

module requantization_block #(
    parameter sys_row = 4,
    parameter sys_col = 4
)(
    input  logic clk,
    input  logic rst,
    input  logic start,

    input  logic [31:0]          requant_scale,
    input  logic [5:0]           requant_shift,
    input  logic signed [7:0]    ZP_next,

    input  logic signed [31:0] sys_out     [0:sys_row-1][0:sys_col-1],
    output logic signed  [7:0] requant_out [0:sys_row-1][0:sys_col-1]
);

    // =========================================================================
    // INPUT BUFFER - latched on start
    // =========================================================================
    logic signed [31:0] buffer [0:sys_row-1][0:sys_col-1];

    logic [31:0]       scale_reg;
  logic [5:0]        shift_reg;
    logic signed [7:0] zp_reg;

    genvar ro, co;
    generate
        for (ro = 0; ro < sys_row; ro++) begin : ro_loop
            for (co = 0; co < sys_col; co++) begin : co_loop
                always_ff @(posedge clk or posedge rst) begin
                    if (rst)        buffer[ro][co] <= 32'd0;
                    else if (start) buffer[ro][co] <= sys_out[ro][co];
                end
            end
        end
    endgenerate

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            scale_reg <= 32'd1;
            shift_reg <= 6'd0;
            zp_reg    <= 8'd0;
        end else if (start) begin
            scale_reg <= requant_scale;
            shift_reg <= requant_shift;
            zp_reg    <= ZP_next;
        end
    end

    // =========================================================================
    // PIPELINE - 5 stages per element
    // =========================================================================
    genvar row, c;
    generate
        for (row = 0; row < sys_row; row++) begin : row_loop
            for (c = 0; c < sys_col; c++) begin : col_loop

                // -----------------------------------------------------------
                // Stage 1: multiply
                //   buffer (INT32) x scale (UINT32) -> 64-bit signed result
                //   Sign-extend buffer to 64 bits; zero-extend scale to 64 bits.
                // -----------------------------------------------------------
             (* keep = "true" *)     logic signed [63:0] mult_res_reg;

                always_ff @(posedge clk or posedge rst) begin
                    if (rst)
                        mult_res_reg <= '0;
                    else
                        mult_res_reg <= $signed({{32{buffer[row][c][31]}},
                                                    buffer[row][c]})
                                      * $signed({1'b0, scale_reg});
                end

                // -----------------------------------------------------------
                // Stage 2: compute round bias AND pipeline the shift value.
                //
                // FIX: round_bias_reg reads mult_res_reg (a settled FF), so
                //      mult_res_reg is provably live at this stage.
                // FIX: shift_reg2 is pipelined here so Stage 3 uses the
                //      temporally-correct shift, making shift_reg2 live.
                // -----------------------------------------------------------
                logic signed [63:0] round_bias_reg;
                 (* keep = "true" *)  logic [5:0] shift_reg2;
                always_ff @(posedge clk or posedge rst) begin
                    if (rst) begin
                        round_bias_reg <= '0;
                        shift_reg2     <= '0;
                    end else begin
                        // Pipeline the shift for temporal consistency
                        shift_reg2 <= shift_reg;

                        if (shift_reg == 0) begin
                            round_bias_reg <= '0;
                        end else begin
                            // FIX: reads mult_res_reg (not the combinational
                            //      multiply expression) so Stage 1 FF is live
                            round_bias_reg <= (mult_res_reg >= 0)
                                ?  (64'sd1 <<< (shift_reg - 1))
                                : ((64'sd1 <<< (shift_reg - 1)) - 64'sd1);
                        end
                    end
                end

                // -----------------------------------------------------------
                // Stage 3: arithmetic right-shift with rounding.
                //
                // FIX: uses shift_reg2 (pipelined value) NOT the live shift_reg.
                //      Both mult_res_reg and shift_reg2 are read here,
                //      confirming they are live and will not be pruned.
                // -----------------------------------------------------------
                logic signed [31:0] shift_res_reg;

                always_ff @(posedge clk or posedge rst) begin
                    if (rst)
                        shift_res_reg <= '0;
                    else
                        shift_res_reg <=
                            32'((mult_res_reg + round_bias_reg) >>> shift_reg2);
                end

                // -----------------------------------------------------------
                // Stage 4: add zero point
                // -----------------------------------------------------------
                logic signed [31:0] final_res_reg;

                always_ff @(posedge clk or posedge rst) begin
                    if (rst)
                        final_res_reg <= '0;
                    else
                        final_res_reg <= shift_res_reg +
                                         $signed({{24{zp_reg[7]}}, zp_reg});
                end

                // -----------------------------------------------------------
                // Stage 5: saturate to int8
                // -----------------------------------------------------------
                always_ff @(posedge clk or posedge rst) begin
                    if (rst)
                        requant_out[row][c] <= '0;
                    else begin
                        if      (final_res_reg > 32'sd127)  requant_out[row][c] <=  8'sd127;
                        else if (final_res_reg < -32'sd128) requant_out[row][c] <= 8'sh80;  // -128 in two's complement
                        else                                 requant_out[row][c] <=
                                                                 final_res_reg[7:0];
                    end
                end

            end
        end
    endgenerate

endmodule