module conv_tb_v5;
    
    parameter KERNEL_SIZE   = 5;
    parameter IN_CHANNELS   = 1;
    parameter OUT_CHANNELS  = 6;
    parameter INPUT_HEIGHT  = 28;
    parameter INPUT_WIDTH   = 28;
    parameter TILE_ROWS     = 8;   // Process 8 windows per im2col tile
    parameter ARRAY_COLS    = 6;   // Process 3 output channels per weight tile
    parameter DATA_WIDTH    = 8;
    
    localparam OUTPUT_HEIGHT = INPUT_HEIGHT - KERNEL_SIZE + 1;  // 24
    localparam OUTPUT_WIDTH  = INPUT_WIDTH - KERNEL_SIZE + 1;   // 24
    localparam TOTAL_WINDOWS = OUTPUT_HEIGHT * OUTPUT_WIDTH;    // 576
    localparam WINDOW_SIZE   = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;  // 25
    localparam NUM_WEIGHT_TILES = (OUT_CHANNELS + ARRAY_COLS - 1) / ARRAY_COLS;  // 2 tiles
    
    logic clk, rst;
    logic start_conv;
    logic conv_done;
    
    // Flattened input (784 elements for 28x28)
    logic signed [DATA_WIDTH-1:0] input_data_flat [IN_CHANNELS*INPUT_HEIGHT*INPUT_WIDTH];
    
    // Weights (150 elements per filter, 6 filters = 900 total)
    logic signed [DATA_WIDTH-1:0] weight_data [OUT_CHANNELS*KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS];
    logic weight_data_valid;
    
    // Outputs (now 2D array matching TILE_ROWS x ARRAY_COLS)
    logic output_valid;
    logic signed [4*DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(OUT_CHANNELS)-1:0] output_channel_start;
    logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] output_window_idx_start;
    
    // Statistics
    int output_count;
    int output_tile_count;
    int cycle_count;
    real start_time, end_time;
    
    // Storage for spot-check verification
    logic signed [4*DATA_WIDTH-1:0] output_feature_map [OUT_CHANNELS][OUTPUT_HEIGHT][OUTPUT_WIDTH];
    
    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 100MHz clock
    end
    
    // DUT
    conv_top_v2 #(
        .KERNEL_SIZE(KERNEL_SIZE),
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .INPUT_HEIGHT(INPUT_HEIGHT),
        .INPUT_WIDTH(INPUT_WIDTH),
        .TILE_ROWS(TILE_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start_conv(start_conv),
        .conv_done(conv_done),
        .input_data_flat(input_data_flat),
        .weight_data(weight_data),
        .weight_data_valid(weight_data_valid),
        .output_valid(output_valid),
        .output_data(output_data),
        .output_channel_start(output_channel_start),
        .output_window_idx_start(output_window_idx_start)
    );
    
    // Test
    initial begin
        rst = 1;
        start_conv = 0;
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
        $display("Large Scale Convolution Test v2");
        $display("========================================");
        $display("Input:  %0dx%0dx%0d", INPUT_HEIGHT, INPUT_WIDTH, IN_CHANNELS);
        $display("Kernel: %0dx%0dx%0d", KERNEL_SIZE, KERNEL_SIZE, IN_CHANNELS);
        $display("Output: %0dx%0dx%0d", OUTPUT_HEIGHT, OUTPUT_WIDTH, OUT_CHANNELS);
        $display("Total windows: %0d", TOTAL_WINDOWS);
        $display("Im2col tiles: %0d (TILE_ROWS=%0d)", (TOTAL_WINDOWS+TILE_ROWS-1)/TILE_ROWS, TILE_ROWS);
        $display("Weight tiles: %0d (ARRAY_COLS=%0d)", NUM_WEIGHT_TILES, ARRAY_COLS);
        $display("Systolic array: %0d x %0d x %0d (M x K x N)", TILE_ROWS, WINDOW_SIZE, ARRAY_COLS);
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
        
        $display("Data initialization complete.\n");
        
        #20; rst = 0; #20;
        
        // Start convolution
        $display("========================================");
        $display("Starting convolution at time %0t", $time);
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
    
    // Collect outputs (now processing TILE_ROWS x ARRAY_COLS tile at a time)
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
                        end
                    end
                end
            end
            
            // Print progress
            $display("Output Tile %0d: Windows [%0d:%0d], Channels [%0d:%0d]",
                     output_tile_count, win_idx_start, win_idx_start + TILE_ROWS - 1,
                     ch_start, ch_start + ARRAY_COLS - 1);
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
        $display("Convolution Completed!");
        $display("========================================");
        $display("Time: %.2f ns (%.2f us)", duration_ns, duration_us);
        $display("Cycles: %0d", cycle_count);
        $display("Output tiles: %0d", output_tile_count);
        $display("Outputs generated: %0d/%0d", output_count, expected_outputs);
        $display("Throughput: %.2f MOps/s", throughput_mops);
        $display("Cycles per output tile: %.1f", real'(cycle_count) / output_tile_count);
        
        if (output_count == expected_outputs) begin
            $display("\n? All outputs generated successfully!");
        end else begin
            $display("\n? WARNING: Missing outputs! (expected %0d)", expected_outputs);
        end
        
        // Display sample outputs
        $display("\n--- Sample Outputs (Channel 0, First 5x5) ---");
        for (int h = 0; h < 5 && h < OUTPUT_HEIGHT; h++) begin
            $write("Row %2d: ", h);
            for (int w = 0; w < 5 && w < OUTPUT_WIDTH; w++) begin
                $write("%6d ", output_feature_map[0][h][w]);
            end
            $write("\n");
        end
        
        $display("\n--- Sample Outputs (Channel 5, Last 5x5) ---");
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
        
        $display("========================================");
        $display("Spot Check Verification");
        $display("========================================\n");
        
        // Check that corner outputs are non-zero and reasonable
        $display("Checking corner outputs...");
        
        // Top-left
        if (output_feature_map[0][0][0] == 0) begin
            $display("? FAIL: Top-left corner is zero!");
            errors++;
        end else begin
            $display("? PASS: Top-left corner [0][0][0] = %0d", output_feature_map[0][0][0]);
        end
        
        // Top-right
        if (output_feature_map[0][0][OUTPUT_WIDTH-1] == 0) begin
            $display("? FAIL: Top-right corner is zero!");
            errors++;
        end else begin
            $display("? PASS: Top-right corner [0][0][%0d] = %0d", 
                     OUTPUT_WIDTH-1, output_feature_map[0][0][OUTPUT_WIDTH-1]);
        end
        
        // Bottom-left
        if (output_feature_map[0][OUTPUT_HEIGHT-1][0] == 0) begin
            $display("? FAIL: Bottom-left corner is zero!");
            errors++;
        end else begin
            $display("? PASS: Bottom-left corner [0][%0d][0] = %0d", 
                     OUTPUT_HEIGHT-1, output_feature_map[0][OUTPUT_HEIGHT-1][0]);
        end
        
        // Bottom-right
        if (output_feature_map[0][OUTPUT_HEIGHT-1][OUTPUT_WIDTH-1] == 0) begin
            $display("? FAIL: Bottom-right corner is zero!");
            errors++;
        end else begin
            $display("? PASS: Bottom-right corner [0][%0d][%0d] = %0d", 
                     OUTPUT_HEIGHT-1, OUTPUT_WIDTH-1, 
                     output_feature_map[0][OUTPUT_HEIGHT-1][OUTPUT_WIDTH-1]);
        end
        
        // Check center
        if (output_feature_map[0][OUTPUT_HEIGHT/2][OUTPUT_WIDTH/2] == 0) begin
            $display("? FAIL: Center is zero!");
            errors++;
        end else begin
            $display("? PASS: Center [0][%0d][%0d] = %0d", 
                     OUTPUT_HEIGHT/2, OUTPUT_WIDTH/2,
                     output_feature_map[0][OUTPUT_HEIGHT/2][OUTPUT_WIDTH/2]);
        end
        
        // Check last channel
        if (output_feature_map[OUT_CHANNELS-1][0][0] == 0) begin
            $display("? FAIL: Last channel corner is zero!");
            errors++;
        end else begin
            $display("? PASS: Last channel [%0d][0][0] = %0d", 
                     OUT_CHANNELS-1, output_feature_map[OUT_CHANNELS-1][0][0]);
        end
        
        $display("");
        if (errors == 0) begin
            $display("========================================");
            $display("*** ALL SPOT CHECKS PASSED! ***");
            $display("========================================\n");
        end else begin
            $display("========================================");
            $display("*** %0d SPOT CHECKS FAILED! ***", errors);
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
