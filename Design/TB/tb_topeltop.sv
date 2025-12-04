// ============================================================
// Convolution + Bias Addition Testbench
// Tests conv_bias_top with ReLU disabled
// Small scale: 5x5 input, 2x2 kernel, 3 output channels
// ============================================================

module conv_bias_tb;
    
    parameter KERNEL_SIZE   = 2;
    parameter IN_CHANNELS   = 1;
    parameter OUT_CHANNELS  = 3;
    parameter INPUT_HEIGHT  = 5;
    parameter INPUT_WIDTH   = 5;
    parameter TILE_ROWS     = 8;
    parameter ARRAY_COLS    = 2;
    parameter DATA_WIDTH    = 8;
    parameter BIAS_WIDTH    = 16;
    
    localparam OUTPUT_HEIGHT = INPUT_HEIGHT - KERNEL_SIZE + 1;  // 4
    localparam OUTPUT_WIDTH  = INPUT_WIDTH - KERNEL_SIZE + 1;   // 4
    localparam TOTAL_WINDOWS = OUTPUT_HEIGHT * OUTPUT_WIDTH;    // 16
    localparam WINDOW_SIZE   = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;  // 4
    
    logic clk, rst;
    logic start_conv;
    logic enable_relu;
    logic conv_done;
    
    // Input data (25 elements for 5x5)
    logic signed [DATA_WIDTH-1:0] input_data_flat [IN_CHANNELS*INPUT_HEIGHT*INPUT_WIDTH];
    
    // Weights (4 elements per filter, 3 filters = 12 total)
    logic signed [DATA_WIDTH-1:0] weight_data [OUT_CHANNELS*KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS];
    logic weight_data_valid;
    
    // Bias values (one per output channel)
    logic signed [BIAS_WIDTH-1:0] bias_data [OUT_CHANNELS];
    
    // Outputs
    logic output_valid;
    logic signed [4*DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(OUT_CHANNELS)-1:0] output_channel_start;
    logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] output_window_idx_start;
    
    // Statistics
    int output_count;
    int output_tile_count;
    int cycle_count;
    real start_time, end_time;
    
    // Storage for verification
    logic signed [4*DATA_WIDTH-1:0] output_feature_map [OUT_CHANNELS][OUTPUT_HEIGHT][OUTPUT_WIDTH];
    
    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 100MHz clock
    end
    
    // DUT - Using integrated conv + bias top module
    conv_bias_top #(
        .KERNEL_SIZE(KERNEL_SIZE),
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .INPUT_HEIGHT(INPUT_HEIGHT),
        .INPUT_WIDTH(INPUT_WIDTH),
        .TILE_ROWS(TILE_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .DATA_WIDTH(DATA_WIDTH),
        .BIAS_WIDTH(BIAS_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start_conv(start_conv),
        .enable_relu(enable_relu),
        .conv_done(conv_done),
        .input_data_flat(input_data_flat),
        .weight_data(weight_data),
        .weight_data_valid(weight_data_valid),
        .bias_data(bias_data),
        .output_valid(output_valid),
        .output_data(output_data),
        .output_channel_start(output_channel_start),
        .output_window_idx_start(output_window_idx_start)
    );
    
    // Test stimulus
    initial begin
        rst = 1;
        start_conv = 0;
        enable_relu = 0;  // Disable ReLU for this test
        weight_data_valid = 1;
        output_count = 0;
        output_tile_count = 0;
        cycle_count = 0;
        
        // Initialize output storage
        for (int c = 0; c < OUT_CHANNELS; c++)
            for (int h = 0; h < OUTPUT_HEIGHT; h++)
                for (int w = 0; w < OUTPUT_WIDTH; w++)
                    output_feature_map[c][h][w] = 0;
        
        $display("\n========================================");
        $display("Convolution + Bias Test (No ReLU)");
        $display("========================================");
        $display("Input:  %0dx%0dx%0d", INPUT_HEIGHT, INPUT_WIDTH, IN_CHANNELS);
        $display("Kernel: %0dx%0dx%0d", KERNEL_SIZE, KERNEL_SIZE, IN_CHANNELS);
        $display("Output: %0dx%0dx%0d", OUTPUT_HEIGHT, OUTPUT_WIDTH, OUT_CHANNELS);
        $display("ReLU:   DISABLED");
        $display("========================================\n");
        
        // Initialize input: Simple sequential pattern [1-25]
        $display("Initializing input data (5x5):");
        for (int h = 0; h < INPUT_HEIGHT; h++) begin
            $write("  Row %0d: ", h);
            for (int w = 0; w < INPUT_WIDTH; w++) begin
                input_data_flat[h * INPUT_WIDTH + w] = $signed(h * INPUT_WIDTH + w + 1);
                $write("%3d ", input_data_flat[h * INPUT_WIDTH + w]);
            end
            $write("\n");
        end
        $display("");
        
        // Initialize weights: Simple patterns
        $display("Initializing weights:");
        for (int f = 0; f < OUT_CHANNELS; f++) begin
            $write("  Filter %0d (2x2): ", f);
            for (int i = 0; i < WINDOW_SIZE; i++) begin
                case (f)
                    0: weight_data[f * WINDOW_SIZE + i] = 1;   // All ones
                    1: weight_data[f * WINDOW_SIZE + i] = 2;   // All twos
                    2: weight_data[f * WINDOW_SIZE + i] = (i < 2) ? -1 : 1;  // Edge
                endcase
                $write("%3d ", weight_data[f * WINDOW_SIZE + i]);
            end
            $write("\n");
        end
        $display("");
        
        // Initialize bias values
        $display("Initializing bias values:");
        bias_data[0] = 100;   // Positive bias
        bias_data[1] = -50;   // Negative bias
        bias_data[2] = 0;     // Zero bias (no change)
        
        for (int c = 0; c < OUT_CHANNELS; c++) begin
            $display("  Channel %0d bias: %0d", c, bias_data[c]);
        end
        $display("");
        
        #20; rst = 0; #20;
        
        // Start convolution
        $display("========================================");
        $display("Starting convolution + bias at time %0t", $time);
        $display("========================================\n");
        start_time = $realtime;
        start_conv = 1;
        #10; start_conv = 0;
        
        // Wait for completion
        wait(conv_done == 1);
        end_time = $realtime;
        #20;
        
        // Display results
        display_results();
        
        // Verify outputs
        verify_outputs();
        
        #100;
        $finish;
    end
    
    // Count cycles
    always @(posedge clk) begin
        if (!rst && !conv_done)
            cycle_count <= cycle_count + 1;
    end
    
    // Collect outputs
    always @(posedge clk) begin
        if (output_valid) begin
            automatic int win_idx_start = output_window_idx_start;
            automatic int ch_start = output_channel_start;
            
            output_tile_count++;
            
            $display("Output Tile %0d received at time %0t:", output_tile_count, $time);
            $display("  Window start: %0d, Channel start: %0d", win_idx_start, ch_start);
            
            // Process tile
            for (int tile_row = 0; tile_row < TILE_ROWS; tile_row++) begin
                automatic int win_idx = win_idx_start + tile_row;
                
                if (win_idx < TOTAL_WINDOWS) begin
                    automatic int row = win_idx / OUTPUT_WIDTH;
                    automatic int col = win_idx % OUTPUT_WIDTH;
                    
                    $write("    Win %2d [%0d,%0d]: ", win_idx, row, col);
                    
                    for (int tile_col = 0; tile_col < ARRAY_COLS; tile_col++) begin
                        automatic int ch_idx = ch_start + tile_col;
                        if (ch_idx < OUT_CHANNELS) begin
                            output_feature_map[ch_idx][row][col] = output_data[tile_row][tile_col];
                            output_count++;
                            $write("Ch%0d=%6d ", ch_idx, output_data[tile_row][tile_col]);
                        end
                    end
                    $write("\n");
                end
            end
            $display("");
        end
    end
    
    // Display results
    task display_results();
        real duration_ns, duration_us;
        int expected_outputs;
        
        duration_ns = end_time - start_time;
        duration_us = duration_ns / 1000.0;
        expected_outputs = TOTAL_WINDOWS * OUT_CHANNELS;
        
        $display("\n========================================");
        $display("Convolution + Bias Completed!");
        $display("========================================");
        $display("Time: %.2f ns (%.2f us)", duration_ns, duration_us);
        $display("Cycles: %0d", cycle_count);
        $display("Output tiles: %0d", output_tile_count);
        $display("Outputs generated: %0d/%0d", output_count, expected_outputs);
        
        if (output_count == expected_outputs) begin
            $display("\n? All outputs generated successfully!");
        end else begin
            $display("\n? WARNING: Missing outputs!");
        end
        
        // Display all output feature maps
        for (int c = 0; c < OUT_CHANNELS; c++) begin
            $display("\n--- Output Channel %0d (with bias=%0d) ---", c, bias_data[c]);
            for (int h = 0; h < OUTPUT_HEIGHT; h++) begin
                $write("Row %0d: ", h);
                for (int w = 0; w < OUTPUT_WIDTH; w++) begin
                    $write("%6d ", output_feature_map[c][h][w]);
                end
                $write("\n");
            end
        end
        
        $display("========================================\n");
    endtask
    
    // Verify outputs with manual calculation
    task verify_outputs();
        automatic int errors = 0;
        automatic logic signed [2*DATA_WIDTH-1:0] expected_conv, expected_bias;
        
        $display("========================================");
        $display("Verification (Conv + Bias)");
        $display("========================================\n");
        
        // Test 1: Filter 0, Position [0][0]
        // Input window: [1,2; 6,7], Weights: [1,1,1,1], Bias: 100
        // Conv output: 1+2+6+7 = 16
        // After bias: 16 + 100 = 116
        expected_conv = 16;
        expected_bias = expected_conv + bias_data[0];
        
        $display("Test 1: Filter 0, Position [0][0]");
        $display("  Input window: [1,2; 6,7]");
        $display("  Weights: [1,1,1,1]");
        $display("  Conv result: %0d (expected %0d)", expected_conv, expected_conv);
        $display("  Bias value: %0d", bias_data[0]);
        $display("  Expected after bias: %0d", expected_bias);
        $display("  Got: %0d", output_feature_map[0][0][0]);
        
        if (output_feature_map[0][0][0] == expected_bias) begin
            $display("  ? PASS\n");
        end else begin
            $display("  ? FAIL\n");
            errors++;
        end
        
        // Test 2: Filter 0, Position [0][1]
        // Input window: [2,3; 7,8], Weights: [1,1,1,1], Bias: 100
        // Conv: 2+3+7+8 = 20, After bias: 20+100 = 120
        expected_conv = 20;
        expected_bias = expected_conv + bias_data[0];
        
        $display("Test 2: Filter 0, Position [0][1]");
        $display("  Conv: %0d, Bias: %0d, Expected: %0d", expected_conv, bias_data[0], expected_bias);
        $display("  Got: %0d", output_feature_map[0][0][1]);
        
        if (output_feature_map[0][0][1] == expected_bias) begin
            $display("  ? PASS\n");
        end else begin
            $display("  ? FAIL\n");
            errors++;
        end
        
        // Test 3: Filter 1, Position [0][0]
        // Weights: [2,2,2,2], Bias: -50
        // Conv: (1+2+6+7)*2 = 32, After bias: 32-50 = -18
        expected_conv = 32;
        expected_bias = expected_conv + bias_data[1];
        
        $display("Test 3: Filter 1, Position [0][0] (negative bias)");
        $display("  Conv: %0d, Bias: %0d, Expected: %0d", expected_conv, bias_data[1], expected_bias);
        $display("  Got: %0d", output_feature_map[1][0][0]);
        
        if (output_feature_map[1][0][0] == expected_bias) begin
            $display("  ? PASS\n");
        end else begin
            $display("  ? FAIL\n");
            errors++;
        end
        
        // Test 4: Filter 2, Position [0][0]
        // Weights: [-1,-1,1,1], Bias: 0
        // Conv: -1*1 -1*2 +1*6 +1*7 = -1-2+6+7 = 10, After bias: 10+0 = 10
        expected_conv = 10;
        expected_bias = expected_conv + bias_data[2];
        
        $display("Test 4: Filter 2, Position [0][0] (zero bias)");
        $display("  Conv: %0d, Bias: %0d, Expected: %0d", expected_conv, bias_data[2], expected_bias);
        $display("  Got: %0d", output_feature_map[2][0][0]);
        
        if (output_feature_map[2][0][0] == expected_bias) begin
            $display("  ? PASS\n");
        end else begin
            $display("  ? FAIL\n");
            errors++;
        end
        
        // Test 5: Check that negative result is preserved (no ReLU)
        // Filter 1 with negative bias should produce negative values
        $display("Test 5: Verify negative values preserved (ReLU disabled)");
        if (output_feature_map[1][0][0] < 0) begin
            $display("  Found negative value: %0d", output_feature_map[1][0][0]);
            $display("  ? PASS - ReLU correctly disabled\n");
        end else begin
            $display("  ? WARNING - Expected negative value but got: %0d\n", output_feature_map[1][0][0]);
        end
        
        $display("");
        if (errors == 0) begin
            $display("========================================");
            $display("*** ALL VERIFICATIONS PASSED! ***");
            $display("========================================\n");
        end else begin
            $display("========================================");
            $display("*** %0d VERIFICATIONS FAILED! ***", errors);
            $display("========================================\n");
        end
    endtask
    
    // Timeout
    initial begin
        #1000000;  // 1ms
        $display("\nERROR: Simulation timeout!");
        $display("Output tiles: %0d", output_tile_count);
        $display("Output count: %0d/%0d", output_count, TOTAL_WINDOWS * OUT_CHANNELS);
        $finish;
    end
    
endmodule
