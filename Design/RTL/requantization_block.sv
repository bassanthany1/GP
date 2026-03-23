module requantization_block #(
    parameter sys_row = 4,
    parameter sys_col = 4
)(
    input  logic clk,
    input  logic rst,
    input  logic start,

    // Runtime requantization parameters (set per layer by controller)
    input  logic [31:0]          requant_scale,
    input  logic [5:0]           requant_shift,   // max shift = 31
    input  logic signed [7:0]    ZP_next,

    input  logic signed [31:0] sys_out     [0:sys_row-1][0:sys_col-1],
    output logic signed  [7:0] requant_out [0:sys_row-1][0:sys_col-1]
);

    // =========================================================================
    // INPUT BUFFER â€” latched on start
    // =========================================================================
    logic signed [31:0] buffer [0:sys_row-1][0:sys_col-1];

    // Latch runtime params at start time so pipeline uses consistent values
    logic [31:0]       scale_reg;
    logic [5:0]        shift_reg;
    logic signed [7:0] zp_reg;

    genvar ro, co;
    generate
        for (ro = 0; ro < sys_row; ro++) begin : ro_loop
            for (co = 0; co < sys_col; co++) begin : co_loop
                always_ff @(posedge clk or posedge rst) begin
                    if (rst)
                        buffer[ro][co] <= 32'd0;
                    else if (start)
                        buffer[ro][co] <= sys_out[ro][co];
                end
            end
        end
    endgenerate

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            scale_reg <= 32'd1;
            shift_reg <= 5'd0;
            zp_reg    <= 8'd0;
        end else if (start) begin
            scale_reg <= requant_scale;
            shift_reg <= requant_shift;
            zp_reg    <= ZP_next;
        end
    end

    // =========================================================================
    // REQUANTIZATION PIPELINE â€” 4 stages per element
    // Stage 1: multiply
    // Stage 2: round-nearest shift
    // Stage 3: add zero point
    // Stage 4: saturate to int8
    // =========================================================================
    genvar row, c;
    generate
        for (row = 0; row < sys_row; row++) begin : row_loop
            for (c = 0; c < sys_col; c++) begin : col_loop

                logic signed [63:0] mult_res;
                logic signed [31:0] shift_res;
                logic signed [31:0] final_res;
                logic signed [63:0] round_bias;
                always_ff @(posedge clk or posedge rst) begin
                    if (rst) begin
                        mult_res        <= 65'd0;
                        shift_res       <= 64'd0;
                        final_res       <= 32'd0;
                        requant_out[row][c] <= 8'd0;
                    end else begin
                        // Stage 1: multiply (scale_reg latched at start)
                        mult_res <= $signed(buffer[row][c]) * $signed({1'b0, scale_reg});

                        // Stage 2: round-nearest right shift
                     
round_bias = (mult_res >= 0) ? (64'sd1 << (shift_reg - 1)) 
                              : ((64'sd1 << (shift_reg - 1)) - 64'sd1);
shift_res <= (mult_res + round_bias) >>> shift_reg;

                        // Stage 3: add zero point (sign-extend ZP to 32 bits)
                        final_res <= shift_res + $signed({{24{zp_reg[7]}}, zp_reg});

                        // Stage 4: saturate to [-128, 127]
                        if (final_res > 32'sd127)
                            requant_out[row][c] <= 8'sd127;
                        else if (final_res < -32'sd128)
                            requant_out[row][c] <= -8'sd128;
                        else
                            requant_out[row][c] <= final_res[7:0];
                    end
                end

            end
        end
    endgenerate

endmodule
