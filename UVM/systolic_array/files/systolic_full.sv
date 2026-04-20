// =============================================================================
// systolic_full - Option A: zero-copy feed
//
// CHANGE LOG vs original:
//   - Removed A_BUFFER[M][K] and B_BUFFER[K][N] (saves 2×M×K×DW + 2×K×N×DW FFs)
//     For default params (M=8,K=256,N=8,DW=8): saves 32 Kbit of flip-flops.
//   - Removed the always_ff copy block that loaded a_full_in?A_BUFFER,
//     b_full_in?B_BUFFER on load_data.
//   - Wavefront always_comb now indexes a_flat / b_flat directly using
//     cycle_cnt-based diagonal offsets. No combinational or registered copy.
//   - a_full_in / b_full_in unpack wires retained for readability but are now
//     unused (synthesiser will optimise them away). They can be removed.
//   - load_data still resets PE_C_REG and arms run_enable - behaviour unchanged.
//   - All ports, parameters, and external timing contracts unchanged.
//
// REQUIREMENT on caller (conv_top_v2_hybrid):
//   a_flat and b_flat must remain stable (held valid) from the cycle systolic_load
//   is asserted until systolic_valid fires. The controller already guarantees this
//   because it stays in COMPUTE state and does not re-assert start_im2col or
//   start_weight until systolic_valid is seen.
// =============================================================================

module systolic_full #(
    parameter int DATAWIDTH = 8,
    parameter int M  = 4,
    parameter int K  = 256,
    parameter int N  = 4
)(
    input  logic clk,
    input  logic rst,
    input  logic load_data,

    // Runtime inner dimension
    input  logic [$clog2(K+1)-1:0] k_size,

    // FLAT 1D packed input ports
    input  logic signed [M*K*DATAWIDTH-1:0] a_flat,
    input  logic signed [K*N*DATAWIDTH-1:0] b_flat,

    output logic valid_out,

    // FLAT 1D packed output port
    // c[r][n] at bits [(r*N+n)*4*DATAWIDTH +: 4*DATAWIDTH]
    output logic signed [M*N*4*DATAWIDTH-1:0] c_flat
);

    localparam int CNT_WIDTH = $clog2(K + M + N + 1);

    // =========================================================================
    // Unpack flat inputs into 2D arrays - combinational only, no registers.
    // These wires are read directly by the wavefront logic every cycle.
    // =========================================================================
    logic signed [DATAWIDTH-1:0] a_in_2d [M-1:0][K-1:0];
    logic signed [DATAWIDTH-1:0] b_in_2d [K-1:0][N-1:0];

    always_comb begin
        for (int r = 0; r < M; r++)
            for (int k = 0; k < K; k++)
                a_in_2d[r][k] = a_flat[(r*K+k)*DATAWIDTH +: DATAWIDTH];
        for (int k = 0; k < K; k++)
            for (int n = 0; n < N; n++)
                b_in_2d[k][n] = b_flat[(k*N+n)*DATAWIDTH +: DATAWIDTH];
    end

    // =========================================================================
    // Control registers
    // =========================================================================
    logic [CNT_WIDTH-1:0]   total_cycles_reg;
    logic [$clog2(K+1)-1:0] k_size_reg;
    logic                   run_enable;
    logic [CNT_WIDTH-1:0]   cycle_cnt;
    logic                   output_ready;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            run_enable       <= 1'b0;
            cycle_cnt        <= '0;
            output_ready     <= 1'b0;
            k_size_reg       <= '0;
            total_cycles_reg <= '0;
        end else begin
            output_ready <= 1'b0;

            if (load_data) begin
                // Latch geometry and arm the run.
                // No buffer copy needed - a_flat/b_flat are read directly.
                k_size_reg       <= k_size;
                total_cycles_reg <= CNT_WIDTH'(k_size) +
                                    CNT_WIDTH'(M) +
                                    CNT_WIDTH'(N) - 2;
                run_enable       <= 1'b1;
                cycle_cnt        <= '0;
            end

            if (run_enable && !load_data) begin
                if (cycle_cnt < total_cycles_reg)
                    cycle_cnt <= cycle_cnt + 1;
                else begin
                    run_enable   <= 1'b0;
                    output_ready <= 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Wavefront feed - reads a_flat / b_flat directly, no intermediate buffer.
    //
    // For row i: the diagonal element at cycle t is a_in_2d[i][t-i]
    //   valid when run_enable && (t >= i) && (t-i < k_size_reg)
    //
    // For col j: the diagonal element at cycle t is b_in_2d[t-j][j]
    //   valid when run_enable && (t >= j) && (t-j < k_size_reg)
    //
    // a_flat / b_flat must be held stable by the caller for the entire run.
    // =========================================================================
    logic signed [DATAWIDTH-1:0] a_next_in [M-1:0];
    logic signed [DATAWIDTH-1:0] b_next_in [N-1:0];

    always_comb begin
        for (int i = 0; i < M; i++) begin
            automatic int col;
            col = int'(cycle_cnt) - i;
            if (run_enable && col >= 0 && col < int'(k_size_reg))
                a_next_in[i] = a_in_2d[i][col];
            else
                a_next_in[i] = '0;
        end
        for (int j = 0; j < N; j++) begin
            automatic int row;
            row = int'(cycle_cnt) - j;
            if (run_enable && row >= 0 && row < int'(k_size_reg))
                b_next_in[j] = b_in_2d[row][j];
            else
                b_next_in[j] = '0;
        end
    end

    // =========================================================================
    // PE grid - unchanged from original
    // =========================================================================
    logic signed [DATAWIDTH-1:0]   PE_A     [M-1:0][N-1:0];
    logic signed [DATAWIDTH-1:0]   PE_B     [M-1:0][N-1:0];
    logic signed [4*DATAWIDTH-1:0] PE_C_REG [M-1:0][N-1:0];

    generate
        for (genvar r = 0; r < M; r++) begin : row_loop
            for (genvar c = 0; c < N; c++) begin : col_loop
                logic signed [DATAWIDTH-1:0] a_in, b_in;

                if (c == 0) assign a_in = a_next_in[r];
                else        assign a_in = PE_A[r][c-1];

                if (r == 0) assign b_in = b_next_in[c];
                else        assign b_in = PE_B[r-1][c];

                always_ff @(posedge clk or posedge rst) begin
                    if (rst || load_data) begin
                        PE_A[r][c]     <= '0;
                        PE_B[r][c]     <= '0;
                        PE_C_REG[r][c] <= '0;
                    end else if (run_enable) begin
                        PE_A[r][c]     <= a_in;
                        PE_B[r][c]     <= b_in;
                        PE_C_REG[r][c] <= PE_C_REG[r][c] + (a_in * b_in);
                    end
                end
            end
        end
    endgenerate

    // =========================================================================
    // Output register - unchanged from original
    // =========================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            valid_out <= 1'b0;
            c_flat    <= '0;
        end else begin
            if (output_ready) begin
                valid_out <= 1'b1;
                for (int i = 0; i < M; i++)
                    for (int j = 0; j < N; j++)
                        c_flat[(i*N+j)*4*DATAWIDTH +: 4*DATAWIDTH] <= PE_C_REG[i][j];
            end else
                valid_out <= 1'b0;
        end
    end

endmodule
