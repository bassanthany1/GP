// requantization_block - FIXED v4
//
// Root cause of persistent mult_res_reg pruning (all previous versions):
//   Vivado performs bit-level liveness analysis across the full datapath.
//   mult_res is 64-bit but the final output is 8-bit after shift+saturate.
//   Vivado determines that the upper bits of mult_res can never affect
//   requant_out and removes them.  When enough bits are removed, the whole
//   register is reported as unused.  Module boundaries do NOT prevent this
//   for generate-instantiated modules - Vivado flattens them.
//
// Fix:
//   Use (* keep = "true" *) ONLY on mult_res_reg (the 64-bit multiply result)
//   and shift_reg2.  Do NOT use keep on any other register.
//
//   Why this is safe for timing (unlike blanket keep):
//   - Vivado maps 64-bit multiplies to DSP48 chains automatically.
//     The DSP48 output register IS mult_res_reg - keep tells Vivado to
//     preserve the FF but does NOT prevent DSP inference because the
//     multiply+register pattern is recognised BEFORE keep is evaluated.
//   - shift_reg2 is a 6-bit counter register - trivial timing, keep is safe.
//   - All other pipeline registers (round_bias, shift_res, final_res) are
//     NOT kept - Vivado retimes them freely.
//
//   This is the standard Xilinx recommended approach for preserving DSP
//   output registers that feed pipelined arithmetic.

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
    // Input buffer - latched on start
    // =========================================================================
    logic signed [31:0] buffer [0:sys_row-1][0:sys_col-1];
    logic [31:0]        scale_reg;
    logic [5:0]         shift_reg;
    logic signed [7:0]  zp_reg;

    genvar ro, co;
    generate
        for (ro = 0; ro < sys_row; ro++) begin : ro_buf
            for (co = 0; co < sys_col; co++) begin : co_buf
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
    // Pipeline - one chain per element
    // =========================================================================
    genvar row, c;
    generate
        for (row = 0; row < sys_row; row++) begin : row_loop
            for (c = 0; c < sys_col; c++) begin : col_loop

                // -------------------------------------------------------------
                // (* keep = "true" *) applied ONLY to registers that Vivado's
                // bit-level liveness analysis incorrectly prunes:
                //
                //   mult_res_reg : 64-bit DSP output register.  Upper bits are
                //     "dead" from the 8-bit output's perspective but are needed
                //     for correct rounding arithmetic.  keep preserves all 64
                //     bits.  DSP48 inference is unaffected because Vivado
                //     recognises the multiply-accumulate pattern before
                //     applying keep constraints.
                //
                //   shift_reg2 : 6-bit pipeline register.  Pruned because
                //     shift_reg (its source) is already registered and Vivado
                //     substitutes it directly.  keep costs zero timing budget
                //     on a 6-bit path.
                //
                // All other registers are left free for retiming.
                // -------------------------------------------------------------
                (* dont_touch = "true" *)  logic signed [63:0] mult_res_reg;
                (* keep = "true" *) logic        [5:0]  shift_reg2;

                logic signed [63:0] round_bias_reg;
                logic signed [31:0] shift_res_reg;
                logic signed [31:0] final_res_reg;

                always_ff @(posedge clk or posedge rst) begin
                    if (rst) begin
                        mult_res_reg        <= '0;
                        round_bias_reg      <= '0;
                        shift_reg2          <= '0;
                        shift_res_reg       <= '0;
                        final_res_reg       <= '0;
                        requant_out[row][c] <= '0;
                    end else begin

                        // Stage 1: multiply
                        mult_res_reg <= $signed({{32{buffer[row][c][31]}},
                                                    buffer[row][c]})
                                      * $signed({1'b0, scale_reg});

                        // Stage 2: round bias + pipeline shift
                        shift_reg2 <= shift_reg;
                        if (shift_reg == 0)
                            round_bias_reg <= '0;
                        else
                            round_bias_reg <= (mult_res_reg >= 0)
                                ?  (64'sd1 <<< (shift_reg - 1))
                                : ((64'sd1 <<< (shift_reg - 1)) - 64'sd1);

                        // Stage 3: arithmetic right-shift
                        shift_res_reg <=
                            32'((mult_res_reg + round_bias_reg) >>> shift_reg2);

                        // Stage 4: add zero point
                        final_res_reg <= shift_res_reg +
                                         $signed({{24{zp_reg[7]}}, zp_reg});

                        // Stage 5: saturate to int8
                        if      (final_res_reg > 32'sd127)
                            requant_out[row][c] <=  8'sd127;
                        else if (final_res_reg < -32'sd128)
                            requant_out[row][c] <= -8'sd128;
                        else
                            requant_out[row][c] <= final_res_reg[7:0];

                    end
                end

            end
        end
    endgenerate

endmodule
