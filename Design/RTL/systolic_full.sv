module systolic_full #(
    parameter int DATAWIDTH = 8,
    parameter int M  = 8,
    parameter int K  = 256,
    parameter int N  = 8
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

    // FLAT 1D packed output port — avoids 2D unpacked row-swap simulator bug
    // c[r][n] at bits [(r*N+n)*4*DATAWIDTH +: 4*DATAWIDTH]
    output logic signed [M*N*4*DATAWIDTH-1:0] c_flat
);

    localparam int CNT_WIDTH = $clog2(K + M + N + 1);

    // =========================================================================
    // Unpack flat inputs into 2D arrays internally
    // =========================================================================
    logic signed [DATAWIDTH-1:0] a_full_in [M-1:0][K-1:0];
    logic signed [DATAWIDTH-1:0] b_full_in [K-1:0][N-1:0];

    always_comb begin
        for (int r = 0; r < M; r++)
            for (int k = 0; k < K; k++)
                a_full_in[r][k] = a_flat[(r*K+k)*DATAWIDTH +: DATAWIDTH];
        for (int k = 0; k < K; k++)
            for (int n = 0; n < N; n++)
                b_full_in[k][n] = b_flat[(k*N+n)*DATAWIDTH +: DATAWIDTH];
    end

    // =========================================================================
    // Internal buffers, control
    // =========================================================================
    logic signed [DATAWIDTH-1:0] A_BUFFER [M-1:0][K-1:0];
    logic signed [DATAWIDTH-1:0] B_BUFFER [K-1:0][N-1:0];

    logic [CNT_WIDTH-1:0]   total_cycles_reg;
    logic [$clog2(K+1)-1:0] k_size_reg;
    logic run_enable;
    logic [CNT_WIDTH-1:0]   cycle_cnt;
    logic output_ready;

    logic signed [DATAWIDTH-1:0] a_next_in [M-1:0];
    logic signed [DATAWIDTH-1:0] b_next_in [N-1:0];
    logic signed [DATAWIDTH-1:0]   PE_A     [M-1:0][N-1:0];
    logic signed [DATAWIDTH-1:0]   PE_B     [M-1:0][N-1:0];
    logic signed [4*DATAWIDTH-1:0] PE_C_REG [M-1:0][N-1:0];

    // =========================================================================
    // Load + run control
    // =========================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            run_enable       <= 1'b0;
            cycle_cnt        <= '0;
            output_ready     <= 1'b0;
            k_size_reg       <= '0;
            total_cycles_reg <= '0;
            for (int i = 0; i < M; i++)
                for (int j = 0; j < K; j++)
                    A_BUFFER[i][j] <= '0;
            for (int i = 0; i < K; i++)
                for (int j = 0; j < N; j++)
                    B_BUFFER[i][j] <= '0;
        end else begin
            output_ready <= 1'b0;

            if (load_data) begin
                for (int i = 0; i < M; i++)
                    for (int j = 0; j < K; j++)
                        A_BUFFER[i][j] <= (j < int'(k_size)) ? a_full_in[i][j] : '0;
                for (int i = 0; i < K; i++)
                    for (int j = 0; j < N; j++)
                        B_BUFFER[i][j] <= (i < int'(k_size)) ? b_full_in[i][j] : '0;

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
    // Wavefront feed
    // =========================================================================
    always_comb begin
        for (int i = 0; i < M; i++) begin
            if (run_enable &&
                cycle_cnt >= CNT_WIDTH'(i) &&
                (cycle_cnt - CNT_WIDTH'(i)) < CNT_WIDTH'(k_size_reg))
                a_next_in[i] = A_BUFFER[i][cycle_cnt - i];
            else
                a_next_in[i] = '0;
        end
        for (int j = 0; j < N; j++) begin
            if (run_enable &&
                cycle_cnt >= CNT_WIDTH'(j) &&
                (cycle_cnt - CNT_WIDTH'(j)) < CNT_WIDTH'(k_size_reg))
                b_next_in[j] = B_BUFFER[cycle_cnt - j][j];
            else
                b_next_in[j] = '0;
        end
    end

    // =========================================================================
    // PE grid
    // =========================================================================
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
    // Output register — packed flat output, no 2D unpacked port
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
