`timescale 1ns/1ps

module systolic_full_multiple_tb;

    // Parameters
    parameter int DATAWIDTH = 8;
    parameter int M = 8;
    parameter int K = 20;
    parameter int N = 8;
    parameter int CLK_PERIOD = 10;
    parameter int NUM_TESTS = 5;  // Number of matrix multiplications to test
    
    // DUT signals
    logic clk;
    logic rst;
    logic load_data;
    logic signed [DATAWIDTH-1:0] a_full_in [M-1:0][K-1:0];
    logic signed [DATAWIDTH-1:0] b_full_in [K-1:0][N-1:0];
    logic valid_out;
    logic signed [4*DATAWIDTH-1:0] c_out [M-1:0][N-1:0];
    
    // Test control
    logic [31:0] test_count;
    logic test_in_progress;
    logic all_tests_passed;
    
    // Expected results storage
    logic signed [4*DATAWIDTH-1:0] expected_results [NUM_TESTS-1:0][M-1:0][N-1:0];
    
    // Performance monitoring
    int start_time[NUM_TESTS];
    int end_time[NUM_TESTS];
    int total_cycles;
    
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
    
    // Function to generate random matrix
    function void generate_random_matrix_a(int test_num);
        for (int i = 0; i < M; i++) begin
            for (int j = 0; j < K; j++) begin
                a_full_in[i][j] = $urandom_range(-128, 127);
            end
        end
        $display("Test %0d: Generated random Matrix A", test_num);
    endfunction
    
    function void generate_random_matrix_b(int test_num);
        for (int i = 0; i < K; i++) begin
            for (int j = 0; j < N; j++) begin
                b_full_in[i][j] = $urandom_range(-128, 127);
            end
        end
        $display("Test %0d: Generated random Matrix B", test_num);
    endfunction
    
    // Function to compute expected result (golden reference)
    function void compute_expected_result(int test_num);
        logic signed [4*DATAWIDTH-1:0] temp;
        int i, j, k;
        
        for (i = 0; i < M; i++) begin
            for (j = 0; j < N; j++) begin
                temp = 0;
                for (k = 0; k < K; k++) begin
                    temp += a_full_in[i][k] * b_full_in[k][j];
                end
                expected_results[test_count][i][j] = temp;
            end
        end
        $display("Test %0d: Computed expected result", test_num);
    endfunction
    
    // Task to display matrix
    task display_matrix_a(int test_num);
        int i, j;
        $display("Test %0d - Matrix A:", test_num);
        for (i = 0; i < M; i++) begin
            $write("  Row %0d: ", i);
            for (j = 0; j < K; j++) begin
                $write("%4d ", $signed(a_full_in[i][j]));
            end
            $display("");
        end
    endtask
    
    task display_matrix_b(int test_num);
        int i, j;
        $display("Test %0d - Matrix B:", test_num);
        for (i = 0; i < K; i++) begin
            $write("  Row %0d: ", i);
            for (j = 0; j < N; j++) begin
                $write("%4d ", $signed(b_full_in[i][j]));
            end
            $display("");
        end
    endtask
    
    // Result checking task
    task check_results(int test_num);
        int errors;
        int total_elements;
        int i, j;
        int mismatch_count;
        
        errors = 0;
        total_elements = M * N;
        mismatch_count = 0;
        
        $display("\n=== TEST %0d RESULT VERIFICATION ===", test_num);
        
        for (i = 0; i < M; i++) begin
            for (j = 0; j < N; j++) begin
                if (c_out[i][j] !== expected_results[test_num][i][j]) begin
                    $display("ERROR: C[%0d][%0d] = %0d, expected %0d", 
                             i, j, c_out[i][j], expected_results[test_num][i][j]);
                    errors++;
                end
            end
        end
        
        if (errors == 0) begin
            $display("? TEST %0d PASSED! All %0d results match expected values.", test_num, total_elements);
        end else begin
            $display("? TEST %0d FAILED! %0d/%0d mismatches found.", test_num, errors, total_elements);
            
            // Display first few mismatches only
            $display("\nFirst 5 mismatches:");
            mismatch_count = 0;
            for (i = 0; i < M && mismatch_count < 5; i++) begin
                for (j = 0; j < N && mismatch_count < 5; j++) begin
                    if (c_out[i][j] !== expected_results[test_num][i][j]) begin
                        $display("  C[%0d][%0d] = %0d, expected %0d", 
                                 i, j, c_out[i][j], expected_results[test_num][i][j]);
                        mismatch_count++;
                    end
                end
            end
        end
        
       
    endtask
    
    // Task to run one matrix multiplication test
    task run_single_test(int test_num);
        $display("\n" + "="*60);
        $display("STARTING TEST %0d", test_num);
        $display("="*60);
        
        // Generate test matrices
        generate_random_matrix_a(test_num);
        generate_random_matrix_b(test_num);
        
        // Compute expected result
        compute_expected_result(test_num);
        
        // Display matrices (optional - comment out for large matrices)
        // display_matrix_a(test_num);
        // display_matrix_b(test_num);
        
        // Start computation
        $display("Time %0t: Loading matrices and starting computation", $time);
        load_data = 1;
        @(posedge clk);
        load_data = 0;
        
        // Wait for computation to complete
        $display("Time %0t: Waiting for computation to complete...", $time);
        wait(valid_out == 1);
        @(posedge clk);
        
        $display("Time %0t: Computation complete for test %0d", $time, test_num);
    endtask
    
    // Performance monitoring tasks
    task monitor_load_data;
        if (test_in_progress) begin
            start_time[test_count] = $time;
        end
    endtask
    
    task monitor_valid_out;
        int test_cycles;
        if (test_in_progress) begin
            end_time[test_count] = $time;
            test_cycles = (end_time[test_count] - start_time[test_count]) / CLK_PERIOD;
            total_cycles += test_cycles;
            $display("Test %0d completed in %0d cycles", test_count, test_cycles);
        end
    endtask
    
    // Main test sequence
    initial begin
        // Initialize
        rst = 1;
        load_data = 0;
        test_count = 0;
        test_in_progress = 0;
        all_tests_passed = 1;
        total_cycles = 0;
        
        $display("=== MULTIPLE MATRIX MULTIPLICATION TESTBENCH ===");
        $display("Parameters: M=%0d, K=%0d, N=%0d, DATAWIDTH=%0d", M, K, N, DATAWIDTH);
        $display("Number of tests: %0d", NUM_TESTS);
        $display("Total cycles per test: %0d", (K + M + N - 2));
        
        // Reset
        #(CLK_PERIOD*2);
        rst = 0;
        #(CLK_PERIOD*2);
        
        // Run multiple tests
        for (test_count = 0; test_count < NUM_TESTS; test_count++) begin
            test_in_progress = 1;
            run_single_test(test_count);
            
      
            
            // Small delay between tests
            #(CLK_PERIOD*5);
            test_in_progress = 0;
        end
        
        // Final summary
        $display("\n" + "="*60);
        $display("TEST SUMMARY");
        $display("="*60);
        if (all_tests_passed) begin
            $display("?? ALL %0d TESTS PASSED!", NUM_TESTS);
        end else begin
            $display("?? SOME TESTS FAILED!");
        end
        $display("Total matrix multiplications: %0d", NUM_TESTS);
        $display("Total elements verified: %0d", NUM_TESTS * M * N);
        $display("Average cycles per computation: %0d", total_cycles / NUM_TESTS);
        
        #(CLK_PERIOD*10);
        $display("\n=== SIMULATION COMPLETED ===");
        $finish;
    end
    
    // Monitor for debugging
    initial begin
        forever begin
            @(posedge clk);
            if (load_data) begin
                $display("Time %0t: load_data asserted for test %0d", $time, test_count);
            end
            if (valid_out) begin
                $display("Time %0t: valid_out asserted for test %0d", $time, test_count);
            end
        end
    end
    
    // Performance monitoring
    always @(posedge load_data) begin
        monitor_load_data();
    end
    
    always @(posedge valid_out) begin
        monitor_valid_out();
    end
    
    // Timeout watchdog
    initial begin
        #(CLK_PERIOD * 1000 * NUM_TESTS);
        $display("ERROR: Simulation timeout!");
        $display("Current test: %0d, test_in_progress: %b", test_count, test_in_progress);
        $finish;
    end

endmodule
