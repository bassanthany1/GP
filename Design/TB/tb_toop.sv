// ============================================================
// Large Scale Convolution + Bias Testbench (without matlab)
// 28x28 input, 5x5 kernel, 6 output channels
// Tests conv_bias_top with configurable ReLU
// ============================================================

module conv_tb_v5_bias;
    
    parameter KERNEL_SIZE   = 5;
    parameter IN_CHANNELS   = 1;
    parameter OUT_CHANNELS  = 6;
    parameter INPUT_HEIGHT  = 28;
    parameter INPUT_WIDTH   = 28;
    parameter TILE_ROWS     = 8;
    parameter ARRAY_COLS    = 6;
    parameter DATA_WIDTH    = 8;
    parameter BIAS_WIDTH    = 32;
    
    localparam OUTPUT_HEIGHT = INPUT_HEIGHT - KERNEL_SIZE + 1;  // 24
    localparam OUTPUT_WIDTH  = INPUT_WIDTH - KERNEL_SIZE + 1;   // 24
    localparam TOTAL_WINDOWS = OUTPUT_HEIGHT * OUTPUT_WIDTH;    // 576
    localparam WINDOW_SIZE   = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;  // 25
    localparam NUM_WEIGHT_TILES = (OUT_CHANNELS + ARRAY_COLS - 1) / ARRAY_COLS;  // 1 tile
    
    logic clk, rst;
    logic start_conv;
    logic enable_relu;
    logic conv_done;
    
    // Flattened input (784 elements for 28x28)
    logic signed [DATA_WIDTH-1:0] input_data_flat [IN_CHANNELS*INPUT_HEIGHT*INPUT_WIDTH];
    
    // Weights (150 elements per filter, 6 filters = 900 total)
    logic signed [DATA_WIDTH-1:0] weight_data [OUT_CHANNELS*KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS];
    logic weight_data_valid;
    
    // Bias values (one per output channel)
    logic signed [BIAS_WIDTH-1:0] bias_data [OUT_CHANNELS];
    
    // Outputs (2D array matching TILE_ROWS x ARRAY_COLS)
    logic output_valid;
    logic signed [4*DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(OUT_CHANNELS)-1:0] output_channel_start;
    logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] output_window_idx_start;
    
    // Statistics
    int output_count;
    int output_tile_count;
    int cycle_count;
    real start_time, end_time;
    int negative_count, positive_count, zero_count;
    
    // Storage for spot-check verification
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
    
    // Test
    initial begin
        rst = 1;
        start_conv = 0;
        enable_relu = 1;  // CHANGED: Enable ReLU activation
        weight_data_valid = 1;
        output_count = 0;
        output_tile_count = 0;
        cycle_count = 0;
        negative_count = 0;
        positive_count = 0;
        zero_count = 0;
        
        // Initialize output storage
        for (int c = 0; c < OUT_CHANNELS; c++)
            for (int h = 0; h < OUTPUT_HEIGHT; h++)
                for (int w = 0; w < OUTPUT_WIDTH; w++)
                    output_feature_map[c][h][w] = 0;
        
        $display("\n========================================");
        $display("Large Scale Convolution + Bias Test");
        $display("========================================");
        $display("Input:  %0dx%0dx%0d", INPUT_HEIGHT, INPUT_WIDTH, IN_CHANNELS);
        $display("Kernel: %0dx%0dx%0d", KERNEL_SIZE, KERNEL_SIZE, IN_CHANNELS);
        $display("Output: %0dx%0dx%0d", OUTPUT_HEIGHT, OUTPUT_WIDTH, OUT_CHANNELS);
        $display("Total windows: %0d", TOTAL_WINDOWS);
        $display("Im2col tiles: %0d (TILE_ROWS=%0d)", (TOTAL_WINDOWS+TILE_ROWS-1)/TILE_ROWS, TILE_ROWS);
        $display("Weight tiles: %0d (ARRAY_COLS=%0d)", NUM_WEIGHT_TILES, ARRAY_COLS);
        $display("Systolic array: %0d x %0d x %0d (M x K x N)", TILE_ROWS, WINDOW_SIZE, ARRAY_COLS);
        $display("ReLU: %s", enable_relu ? "ENABLED" : "DISABLED");
        $display("========================================\n");
        
        // Initialize input: Simple pattern (checkerboard-like)
        $display("Initializing input data...");
        for (int h = 0; h < INPUT_HEIGHT; h++) begin
            for (int w = 0; w < INPUT_WIDTH; w++) begin
                // Create gradient pattern
                input_data_flat[h * INPUT_WIDTH + w] = $signed(((h + w) * 3) % 128);
            end
        end
        
        // Initialize weights: Simple patterns for each filter
        $display("Initializing weights...");
        for (int f = 0; f < OUT_CHANNELS; f++) begin
            for (int i = 0; i < WINDOW_SIZE; i++) begin
                // Each filter has different pattern
                case (f % 3)
                    0: weight_data[f * WINDOW_SIZE + i] = 1;  // Average filter
                    1: weight_data[f * WINDOW_SIZE + i] = (i < WINDOW_SIZE/2) ? -1 : 1;  // Edge detection
                    2: weight_data[f * WINDOW_SIZE + i] = (i % 2) ? 1 : -1;  // Checkerboard
                endcase
            end
        end
        
        // Initialize bias values: Mix of positive, negative, and zero
        $display("Initializing bias values...");
        bias_data[0] = 100;   // Positive bias
        bias_data[1] = -200;  // Negative bias (to create some negative outputs)
        bias_data[2] = 0;     // Zero bias
        bias_data[3] = 50;    // Small positive
        bias_data[4] = -100;  // Negative bias
        bias_data[5] = 150;   // Larger positive
        
        for (int c = 0; c < OUT_CHANNELS; c++) begin
            $display("  Channel %0d bias: %0d", c, bias_data[c]);
        end
        
        $display("Data initialization complete.\n");
        
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
        
        // Spot-check verification
        verify_spot_checks();
        
        #100;
        $finish;
    end
    
    // Count cycles
    always @(posedge clk) begin
        if (!rst && !conv_done)
            cycle_count <= cycle_count + 1;
    end
    
    // Collect outputs (processing TILE_ROWS x ARRAY_COLS tile at a time)
    always @(posedge clk) begin
        if (output_valid) begin
            automatic int win_idx_start = output_window_idx_start;
            automatic int ch_start = output_channel_start;
            
            output_tile_count++;
            
            // Process entire TILE_ROWS x ARRAY_COLS tile
            for (int tile_row = 0; tile_row < TILE_ROWS; tile_row++) begin
                automatic int win_idx = win_idx_start + tile_row;
                
                // Check if this window index is valid
                if (win_idx < TOTAL_WINDOWS) begin
                    automatic int row = win_idx / OUTPUT_WIDTH;
                    automatic int col = win_idx % OUTPUT_WIDTH;
                    
                    output_count += ARRAY_COLS;
                    
                    // Store results for all output channels in this tile
                    for (int tile_col = 0; tile_col < ARRAY_COLS; tile_col++) begin
                        automatic int ch_idx = ch_start + tile_col;
                        if (ch_idx < OUT_CHANNELS) begin
                            output_feature_map[ch_idx][row][col] = output_data[tile_row][tile_col];
                            
                            // Count value distribution
                            if (output_data[tile_row][tile_col] < 0)
                                negative_count++;
                            else if (output_data[tile_row][tile_col] > 0)
                                positive_count++;
                            else
                                zero_count++;
                        end
                    end
                end
            end
            
            // Print progress every 10 tiles
            if (output_tile_count % 10 == 0) begin
                $display("Output Tile %0d: Windows [%0d:%0d], Channels [%0d:%0d]",
                         output_tile_count, win_idx_start, win_idx_start + TILE_ROWS - 1,
                         ch_start, ch_start + ARRAY_COLS - 1);
            end
        end
    end
    
    // Display results
    task display_results();
        real duration_ns, duration_us, throughput_mops;
        int expected_outputs;
        
        duration_ns = end_time - start_time;
        duration_us = duration_ns / 1000.0;
        expected_outputs = TOTAL_WINDOWS * OUT_CHANNELS;
        
        // Calculate throughput (MACs per second)
        // Each output requires WINDOW_SIZE multiply-accumulates
        throughput_mops = (output_count * WINDOW_SIZE) / duration_ns * 1000.0;
        
        $display("\n========================================");
        $display("Convolution + Bias Completed!");
        $display("========================================");
        $display("Time: %.2f ns (%.2f us)", duration_ns, duration_us);
        $display("Cycles: %0d", cycle_count);
        $display("Output tiles: %0d", output_tile_count);
        $display("Outputs generated: %0d/%0d", output_count, expected_outputs);
        $display("Throughput: %.2f MOps/s", throughput_mops);
        $display("Cycles per output tile: %.1f", real'(cycle_count) / output_tile_count);
        
        // Display value distribution
        $display("\nOutput Value Distribution:");
        $display("  Positive: %0d (%.1f%%)", positive_count, 100.0 * positive_count / output_count);
        $display("  Negative: %0d (%.1f%%)", negative_count, 100.0 * negative_count / output_count);
        $display("  Zero:     %0d (%.1f%%)", zero_count, 100.0 * zero_count / output_count);
        
        if (enable_relu && negative_count > 0) begin
            $display("\n? WARNING: ReLU enabled but found negative values!");
        end else if (!enable_relu && negative_count == 0) begin
            $display("\n? NOTE: No negative values found (may be expected based on bias values)");
        end
        
        if (output_count == expected_outputs) begin
            $display("\n? All outputs generated successfully!");
        end else begin
            $display("\n? WARNING: Missing outputs! (expected %0d)", expected_outputs);
        end
        
        // Display sample outputs with bias information
        $display("\n--- Sample Outputs (Channel 0, bias=%0d, First 5x5) ---", bias_data[0]);
        for (int h = 0; h < 5 && h < OUTPUT_HEIGHT; h++) begin
            $write("Row %2d: ", h);
            for (int w = 0; w < 5 && w < OUTPUT_WIDTH; w++) begin
                $write("%6d ", output_feature_map[0][h][w]);
            end
            $write("\n");
        end
        
        $display("\n--- Sample Outputs (Channel 1, bias=%0d, First 5x5) ---", bias_data[1]);
        for (int h = 0; h < 5 && h < OUTPUT_HEIGHT; h++) begin
            $write("Row %2d: ", h);
            for (int w = 0; w < 5 && w < OUTPUT_WIDTH; w++) begin
                $write("%6d ", output_feature_map[1][h][w]);
            end
            $write("\n");
        end
        
        $display("\n--- Sample Outputs (Channel 5, bias=%0d, Last 5x5) ---", bias_data[OUT_CHANNELS-1]);
        for (int h = OUTPUT_HEIGHT-5; h < OUTPUT_HEIGHT; h++) begin
            $write("Row %2d: ", h);
            for (int w = OUTPUT_WIDTH-5; w < OUTPUT_WIDTH; w++) begin
                $write("%6d ", output_feature_map[OUT_CHANNELS-1][h][w]);
            end
            $write("\n");
        end
        
        $display("========================================\n");
    endtask
    
    // Verify spot checks (corner cases)
    task verify_spot_checks();
        automatic int errors = 0;
        automatic int warnings = 0;
         automatic logic signed [2*DATA_WIDTH-1:0] diff_ch0_ch2;
        $display("========================================");
        $display("Spot Check Verification");
        $display("========================================\n");
        
        // Check that outputs are affected by bias
        $display("Checking bias effects...");
        
        // Channel 0 and Channel 2 should differ by bias amount (same weights, different bias)
        // Both use same filter pattern (all 1s), so conv output should be same
       
        diff_ch0_ch2 = output_feature_map[0][0][0] - output_feature_map[2][0][0];
        
        $display("Channel 0 [0][0]: %0d (bias=%0d)", output_feature_map[0][0][0], bias_data[0]);
        $display("Channel 2 [0][0]: %0d (bias=%0d)", output_feature_map[2][0][0], bias_data[2]);
        $display("Difference: %0d, Expected bias difference: %0d", diff_ch0_ch2, bias_data[0] - bias_data[2]);
        
        if (diff_ch0_ch2 == (bias_data[0] - bias_data[2])) begin
            $display("? PASS: Bias correctly applied\n");
        end else begin
            $display("? WARNING: Bias difference mismatch (filters may differ)\n");
            warnings++;
        end
        
        // Check corner outputs
        $display("Checking corner outputs...");
        
        // Top-left
        $display("? Top-left [0][0][0] = %0d", output_feature_map[0][0][0]);
        
        // Top-right
        $display("? Top-right [0][0][%0d] = %0d", OUTPUT_WIDTH-1, output_feature_map[0][0][OUTPUT_WIDTH-1]);
        
        // Bottom-left
        $display("? Bottom-left [0][%0d][0] = %0d", OUTPUT_HEIGHT-1, output_feature_map[0][OUTPUT_HEIGHT-1][0]);
        
        // Bottom-right
        $display("? Bottom-right [0][%0d][%0d] = %0d", 
                 OUTPUT_HEIGHT-1, OUTPUT_WIDTH-1, output_feature_map[0][OUTPUT_HEIGHT-1][OUTPUT_WIDTH-1]);
        
        // Center
        $display("? Center [0][%0d][%0d] = %0d", 
                 OUTPUT_HEIGHT/2, OUTPUT_WIDTH/2, output_feature_map[0][OUTPUT_HEIGHT/2][OUTPUT_WIDTH/2]);
        
        // Check last channel
        $display("? Last channel [%0d][0][0] = %0d (bias=%0d)", 
                 OUT_CHANNELS-1, output_feature_map[OUT_CHANNELS-1][0][0], bias_data[OUT_CHANNELS-1]);
        
        // Check for negative values if ReLU disabled
        if (!enable_relu) begin
            $display("\nChecking negative value preservation (ReLU disabled)...");
            if (negative_count > 0) begin
                $display("? PASS: Found %0d negative values (ReLU correctly disabled)", negative_count);
            end else begin
                $display("? NOTE: No negative values found (bias values may prevent negatives)");
            end
        end else begin
            $display("\nChecking ReLU activation...");
            if (negative_count == 0) begin
                $display("? PASS: No negative values (ReLU active)");
            end else begin
                $display("? FAIL: Found %0d negative values with ReLU enabled!", negative_count);
                errors++;
            end
        end
        
        $display("");
        if (errors == 0 && warnings == 0) begin
            $display("========================================");
            $display("*** ALL SPOT CHECKS PASSED! ***");
            $display("========================================\n");
        end else if (errors == 0) begin
            $display("========================================");
            $display("*** PASSED WITH %0d WARNINGS ***", warnings);
            $display("========================================\n");
        end else begin
            $display("========================================");
            $display("*** %0d CHECKS FAILED! ***", errors);
            $display("========================================\n");
        end
    endtask
    
    // Timeout (5ms should be plenty)
    initial begin
        #5000000;  // 5ms
        $display("\nERROR: Simulation timeout after 5ms!");
        $display("Output tiles: %0d", output_tile_count);
        $display("Output count: %0d/%0d", output_count, TOTAL_WINDOWS * OUT_CHANNELS);
        $finish;
    end
    
endmodule
