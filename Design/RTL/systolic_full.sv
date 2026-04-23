// systolic_full - FIXED
// Warnings fixed:
//   [Synth 8-6014] Unused sequential element row_loop[0].col_loop[3].PE_A_reg[0][3]
//   [Synth 8-6014] Unused sequential element row_loop[1].col_loop[3].PE_A_reg[1][3]
//   [Synth 8-6014] Unused sequential element row_loop[2].col_loop[3].PE_A_reg[2][3]
//   [Synth 8-6014] Unused sequential element row_loop[3].col_loop[3].PE_A_reg[3][3]
//   [Synth 8-6014] Unused sequential element row_loop[3].col_loop[0].PE_B_reg[3][0]
//   [Synth 8-6014] Unused sequential element row_loop[3].col_loop[1].PE_B_reg[3][1]
//   [Synth 8-6014] Unused sequential element row_loop[3].col_loop[2].PE_B_reg[3][2]
//   [Synth 8-6014] Unused sequential element row_loop[3].col_loop[3].PE_B_reg[3][3]
//
// Root cause: PE_A[r][N-1] (last column) is written but never forwarded to
//   a neighbour (there is no column N). Similarly PE_B[M-1][c] (last row)
//   is written but never forwarded downward.
// Fix: Gate the PE_A and PE_B register writes so they only occur when
//   the forwarded value will actually be consumed:
//     PE_A[r][c] is only needed when c < N-1  (feeds PE_A[r][c+1])
//     PE_B[r][c] is only needed when r < M-1  (feeds PE_B[r+1][c])
//   PE_C_REG always updates (accumulates the product).
//   No functionality change: the forwarded values read by each PE are
//   a_in = (c==0) ? a_next_in[r] : PE_A[r][c-1]
//   b_in = (r==0) ? b_next_in[c] : PE_B[r-1][c]
//   so PE_A[r][N-1] and PE_B[M-1][c] are genuinely dead.

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
    // Wavefront feed - reads a_flat / b_flat directly.
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
    // PE grid
    // FIX: PE_A[r][c] only registered when c < N-1 (last column never forwarded)
    //      PE_B[r][c] only registered when r < M-1 (last row never forwarded)
    //      This removes the dead registers Vivado was warning about.
    //      PE_C_REG always updated for every PE.
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
                        PE_C_REG[r][c] <= '0;
                        // FIX: only reset/write PE_A when it will be forwarded
                        if (c < N-1) PE_A[r][c] <= '0;
                        // FIX: only reset/write PE_B when it will be forwarded
                        if (r < M-1) PE_B[r][c] <= '0;
                    end else if (run_enable) begin
                        PE_C_REG[r][c] <= PE_C_REG[r][c] + (a_in * b_in);
                        if (c < N-1) PE_A[r][c] <= a_in;
                        if (r < M-1) PE_B[r][c] <= b_in;
                    end
                end
            end
        end
    endgenerate

    // =========================================================================
    // Output register
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
