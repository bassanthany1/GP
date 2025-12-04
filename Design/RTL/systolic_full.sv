module systolic_full #(
parameter int DATAWIDTH = 16,
parameter int M = 8, // rows of A
parameter int K = 8, // inner dimension
parameter int N = 8 // cols of B
)(
input logic clk,
input logic rst, // active high
input logic load_data, // pulse to load A,B and start
input logic signed [DATAWIDTH-1:0] a_full_in [M-1:0][K-1:0],
input logic signed [DATAWIDTH-1:0] b_full_in [K-1:0][N-1:0],
output logic valid_out,
output logic signed [4*DATAWIDTH-1:0] c_out [M-1:0][N-1:0]
);
// ---------- parameters ----------
localparam int TOTAL_CYCLES = K + M + N - 2;
localparam int CNT_WIDTH = $clog2(TOTAL_CYCLES + 1);

// ---------- internal ----------
logic signed [DATAWIDTH-1:0] A_BUFFER [M-1:0][K-1:0];
logic signed [DATAWIDTH-1:0] B_BUFFER [K-1:0][N-1:0];

logic run_enable;
logic [CNT_WIDTH-1:0] cycle_cnt;

logic signed [DATAWIDTH-1:0] a_next_in [M-1:0];
logic signed [DATAWIDTH-1:0] b_next_in [N-1:0];

logic signed [DATAWIDTH-1:0] PE_A [M-1:0][N-1:0];
logic signed [DATAWIDTH-1:0] PE_B [M-1:0][N-1:0];
logic signed [4*DATAWIDTH-1:0] PE_C_REG [M-1:0][N-1:0];

// Add output ready signal
logic output_ready;

// ------------- Load phase -------------
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        run_enable <= 1'b0;
        cycle_cnt  <= '0;
        output_ready <= 1'b0;
        for (int i=0; i<M; i++) for (int j=0; j<K; j++) A_BUFFER[i][j] <= '0;
        for (int i=0; i<K; i++) for (int j=0; j<N; j++) B_BUFFER[i][j] <= '0;
    end else begin
        output_ready <= 1'b0; // Default
        
        if (load_data) begin
            for (int i=0; i<M; i++)
                for (int j=0; j<K; j++)
                    A_BUFFER[i][j] <= a_full_in[i][j];

            for (int i=0; i<K; i++)
                for (int j=0; j<N; j++)
                    B_BUFFER[i][j] <= b_full_in[i][j];

            run_enable <= 1'b1;
            cycle_cnt  <= '0;
        end
        
        if (run_enable && !load_data) begin
            if (cycle_cnt < TOTAL_CYCLES) begin
                cycle_cnt <= cycle_cnt + 1;
            end else begin
                run_enable <= 1'b0;
                output_ready <= 1'b1; // Set output ready one cycle after completion
            end
        end
    end
end

// ------------- Feed A and B (wavefront offset) -------------
always_comb begin
    for (int i=0; i<M; i++) begin
        if (run_enable && (cycle_cnt >= i) && (cycle_cnt - i < K))
            a_next_in[i] = A_BUFFER[i][cycle_cnt - i];
        else
            a_next_in[i] = '0;
    end

    for (int j=0; j<N; j++) begin
        if (run_enable && (cycle_cnt >= j) && (cycle_cnt - j < K))
            b_next_in[j] = B_BUFFER[cycle_cnt - j][j];
        else
            b_next_in[j] = '0;
    end
end

// ------------- PE grid interconnection -------------
generate
    for (genvar r = 0; r < M; r++) begin
        for (genvar c = 0; c < N; c++) begin
            logic signed [DATAWIDTH-1:0] a_in, b_in;

            if (c == 0)
                assign a_in = a_next_in[r];
            else
                assign a_in = PE_A[r][c-1];

            if (r == 0)
                assign b_in = b_next_in[c];
            else
                assign b_in = PE_B[r-1][c];

            always_ff @(posedge clk or posedge rst) begin
                    if (rst || load_data ) begin
                        PE_A[r][c] <= '0;
                        PE_B[r][c] <= '0;
                        PE_C_REG[r][c] <= '0;
                    end else if (run_enable) begin
                        PE_A[r][c] <= a_in;
                        PE_B[r][c] <= b_in;
                        PE_C_REG[r][c] <= PE_C_REG[r][c] + (PE_A[r][c] * PE_B[r][c]);
                    end
                end
        end
    end
endgenerate

// ------------- Output logic -------------
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        valid_out <= 1'b0;
        for (int i=0; i<M; i++)
            for (int j=0; j<N; j++)
                c_out[i][j] <= '0;
    end else begin
        // Single pulse when output is ready
        if (output_ready) begin
            valid_out <= 1'b1;
            for (int i=0; i<M; i++)
                for (int j=0; j<N; j++)
                    c_out[i][j] <= PE_C_REG[i][j];
        end else begin
            valid_out <= 1'b0;
        end
    end
end

endmodule
