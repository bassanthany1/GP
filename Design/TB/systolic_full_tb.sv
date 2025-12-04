`timescale 1ns/1ps

module systolic_full_tb;

    // Parameters
    parameter int DATAWIDTH = 8;  // int8 format
    parameter int M = 8;
    parameter int K = 20;
    parameter int N = 8;
    parameter int CLK_PERIOD = 10;
    
    // DUT signals
    logic clk;
    logic rst;
    logic load_data;
    logic signed [DATAWIDTH-1:0] a_full_in [M-1:0][K-1:0];
    logic signed [DATAWIDTH-1:0] b_full_in [K-1:0][N-1:0];
    logic valid_out;
    logic signed [2*DATAWIDTH-1:0] c_out [M-1:0][N-1:0];
    
    // Expected result
    logic signed [2*DATAWIDTH-1:0] c_expected [M-1:0][N-1:0];
    
    // File handles
    integer file_a, file_b, file_c;
    integer scan_result;
    
    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // DUT instantiation
    systolic_full #(
        .DATAWIDTH(DATAWIDTH),
        .M(M),
        .K(K),
        .N(N)
    ) dut (
        .clk(clk),
        .rst(rst),
        .load_data(load_data),
        .a_full_in(a_full_in),
        .b_full_in(b_full_in),
        .valid_out(valid_out),
        .c_out(c_out)
    );
    
    // Task to read Matrix A from file
    task read_matrix_a(input string filename);
        int temp;
        file_a = $fopen(filename, "r");
        if (file_a == 0) begin
            $display("ERROR: Could not open file %s", filename);
            $finish;
        end
        
        $display("Reading Matrix A from %s", filename);
        for (int i = 0; i < M; i++) begin
            for (int j = 0; j < K; j++) begin
                scan_result = $fscanf(file_a, "%d", temp);
                if (scan_result != 1) begin
                    $display("ERROR: Failed to read A[%0d][%0d]", i, j);
                    $fclose(file_a);
                    $finish;
                end
                a_full_in[i][j] = temp[DATAWIDTH-1:0];
            end
        end
        $fclose(file_a);
        $display("Matrix A loaded successfully");
    endtask
    
    // Task to read Matrix B from file
    task read_matrix_b(input string filename);
        int temp;
        file_b = $fopen(filename, "r");
        if (file_b == 0) begin
            $display("ERROR: Could not open file %s", filename);
            $finish;
        end
        
        $display("Reading Matrix B from %s", filename);
        for (int i = 0; i < K; i++) begin
            for (int j = 0; j < N; j++) begin
                scan_result = $fscanf(file_b, "%d", temp);
                if (scan_result != 1) begin
                    $display("ERROR: Failed to read B[%0d][%0d]", i, j);
                    $fclose(file_b);
                    $finish;
                end
                b_full_in[i][j] = temp[DATAWIDTH-1:0];
            end
        end
        $fclose(file_b);
        $display("Matrix B loaded successfully");
    endtask
    
    // Task to read Expected Matrix C from file
    task read_matrix_c_expected(input string filename);
        int temp;
        file_c = $fopen(filename, "r");
        if (file_c == 0) begin
            $display("ERROR: Could not open file %s", filename);
            $finish;
        end
        
        $display("Reading Expected Matrix C from %s", filename);
        for (int i = 0; i < M; i++) begin
            for (int j = 0; j < N; j++) begin
                scan_result = $fscanf(file_c, "%d", temp);
                if (scan_result != 1) begin
                    $display("ERROR: Failed to read C_expected[%0d][%0d]", i, j);
                    $fclose(file_c);
                    $finish;
                end
                c_expected[i][j] = temp[2*DATAWIDTH-1:0];
            end
        end
        $fclose(file_c);
        $display("Expected Matrix C loaded successfully\n");
    endtask
    
    // Result checking task
    task check_results();
       automatic int errors = 0;
        $display("\n=== RESULT VERIFICATION ===");
        for (int i = 0; i < M; i++) begin
            for (int j = 0; j < N; j++) begin
                if (c_out[i][j] !== c_expected[i][j]) begin
                    $display("ERROR: C[%0d][%0d] = %0d, expected %0d", 
                             i, j, c_out[i][j], c_expected[i][j]);
                    errors++;
                end
            end
        end
        
        if (errors == 0) begin
            $display("\n*** TEST PASSED! All results match expected values. ***");
        end else begin
            $display("\n*** TEST FAILED! %0d mismatches found. ***", errors);
        end
        
        // Display actual results
        $display("\nActual Result Matrix C:");
        for (int i = 0; i < M; i++) begin
            $write("Row %0d: ", i);
            for (int j = 0; j < N; j++) begin
                $write("%7d ", c_out[i][j]);
            end
            $write("\n");
        end
        
        $display("\nExpected Result Matrix C:");
        for (int i = 0; i < M; i++) begin
            $write("Row %0d: ", i);
            for (int j = 0; j < N; j++) begin
                $write("%7d ", c_expected[i][j]);
            end
            $write("\n");
        end
    endtask
    
    // Test stimulus
    initial begin
        // Initialize
        rst = 1;
        load_data = 0;
        
        // Read matrices from files
        $display("=== LOADING TEST DATA FROM FILES ===\n");
        read_matrix_a("matrix_A1.txt");
        read_matrix_b("matrix_B1.txt");
        read_matrix_c_expected("matrix_C_expected1.txt");
        
        // Reset
        $display("=== STARTING SIMULATION ===\n");
        #(CLK_PERIOD*2);
        rst = 0;
        #(CLK_PERIOD*2);
        
        // Load data and start computation
        $display("Time %0t: Loading matrices and starting computation", $time);
        load_data = 1;
        #CLK_PERIOD;
        load_data = 0;
        
        // Wait for computation to complete
        $display("Time %0t: Waiting for computation to complete...", $time);
        wait(valid_out == 1);
        #(CLK_PERIOD);
        
        // Check results
        $display("\nTime %0t: Computation complete. Checking results...", $time);
        check_results();
        
        // Finish simulation
        #(CLK_PERIOD*10);
        $display("\n=== SIMULATION COMPLETED ===");
        $finish;
    end
    
    // Monitor valid_out signal
    initial begin
        @(posedge valid_out);
        $display("Time %0t: valid_out asserted", $time);
    end
    
    // Optional: Timeout watchdog
    initial begin
        #(CLK_PERIOD * 1000);  // Adjust timeout as needed
        $display("ERROR: Simulation timeout!");
        $finish;
    end
    
endmodule

