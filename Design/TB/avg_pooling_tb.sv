// ============================================================
// avg_pool_test_simple.sv - Minimal working testbench
// ============================================================

module avg_pool_tbb;

 
     parameter IN_CHANNELS    = 2;
    parameter INPUT_HEIGHT   = 4;
    parameter INPUT_WIDTH    = 4;
    parameter TILE_ROWS      = 8;
    parameter ARRAY_COLS     = 2;
    parameter DATA_WIDTH     = 16;
    parameter POOL_SIZE      = 2;
    
    localparam OUT_HEIGHT = INPUT_HEIGHT / POOL_SIZE;  // 2
    localparam OUT_WIDTH  = INPUT_WIDTH / POOL_SIZE;   // 2
    localparam OUT_SIZE   = OUT_HEIGHT * OUT_WIDTH;    // 4
    
    logic clk, rst;
    
    // Input signals
    logic input_valid;
    logic signed [DATA_WIDTH-1:0] input_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(IN_CHANNELS)-1:0] input_channel_start;
    logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] input_window_idx_start;
    
    // Output signals
    logic output_valid;
    logic signed [DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(IN_CHANNELS)-1:0] output_channel_start;
    logic [$clog2(OUT_SIZE)-1:0] output_pooled_idx_start;
    
    // Test data storage
    logic signed [DATA_WIDTH-1:0] conv_feature_map [IN_CHANNELS][INPUT_HEIGHT][INPUT_WIDTH];
    logic signed [DATA_WIDTH-1:0] expected_pool [IN_CHANNELS][OUT_HEIGHT][OUT_WIDTH];
    logic signed [DATA_WIDTH-1:0] actual_pool [IN_CHANNELS][OUT_HEIGHT][OUT_WIDTH];
    
    integer errors;
    integer pool_outputs_received;
    
    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 100MHz
    end
    
    // DUT
    avg_pool_2x2 #(
        .IN_CHANNELS(IN_CHANNELS),
        .INPUT_HEIGHT(INPUT_HEIGHT),
        .INPUT_WIDTH(INPUT_WIDTH),
        .TILE_ROWS(TILE_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .DATA_WIDTH(DATA_WIDTH),
        .POOL_SIZE(POOL_SIZE)
    ) dut (
        .clk(clk),
        .rst(rst),
        .input_valid(input_valid),
        .input_data(input_data),
        .input_channel_start(input_channel_start),
        .input_window_idx_start(input_window_idx_start),
        .output_valid(output_valid),
        .output_data(output_data),
        .output_channel_start(output_channel_start),
        .output_pooled_idx_start(output_pooled_idx_start)
    );
    
    // Test stimulus
    initial begin
        integer c, h, w;
        
        rst = 1;
        input_valid = 0;
        input_channel_start = 0;
        input_window_idx_start = 0;
        errors = 0;
        pool_outputs_received = 0;
        
        for (c = 0; c < IN_CHANNELS; c = c + 1) begin
            for (h = 0; h < INPUT_HEIGHT; h = h + 1) begin
                for (w = 0; w < INPUT_WIDTH; w = w + 1) begin
                    conv_feature_map[c][h][w] = 0;
                end
            end
            for (h = 0; h < OUT_HEIGHT; h = h + 1) begin
                for (w = 0; w < OUT_WIDTH; w = w + 1) begin
                    expected_pool[c][h][w] = 0;
                    actual_pool[c][h][w] = 0;
                end
            end
        end
        
        for (h = 0; h < TILE_ROWS; h = h + 1) begin
            for (w = 0; w < ARRAY_COLS; w = w + 1) begin
                input_data[h][w] = 0;
            end
        end
        
        print_header();
        initialize_test_data();
        compute_expected_pool();
        
        #20; rst = 0; #20;
        
        $display("\n========================================");
        $display("Feeding Conv Data to Pooling Module");
        $display("========================================\n");
        
        // Feed all conv data in tiles
        feed_conv_data();
        
        // Wait for all pool outputs
        #500;
        
        // Verify results
        display_results();
        verify_results();
        
        if (errors == 0) begin
            $display("\n??????????????????????????????????????????");
            $display("?   ? ALL TESTS PASSED!                  ?");
            $display("??????????????????????????????????????????\n");
        end else begin
            $display("\n??????????????????????????????????????????");
            $display("?   ? %2d TESTS FAILED!                   ?", errors);
            $display("??????????????????????????????????????????\n");
        end
        
        #100;
        $finish;
    end
    
    // Print header
    task print_header();
        $display("\n??????????????????????????????????????????");
        $display("?  Avg Pool Standalone Test              ?");
        $display("??????????????????????????????????????????");
        $display("Channels:   %0d", IN_CHANNELS);
        $display("Input:      %0dx%0d", INPUT_HEIGHT, INPUT_WIDTH);
        $display("Pool:       %0dx%0d stride %0d", POOL_SIZE, POOL_SIZE, POOL_SIZE);
        $display("Output:     %0dx%0d", OUT_HEIGHT, OUT_WIDTH);
        $display("========================================\n");
    endtask
    
    // Initialize test data
    task initialize_test_data();
        integer c, h, w, val;
        
        $display("Initializing conv feature maps:");
        for (c = 0; c < IN_CHANNELS; c = c + 1) begin
            $display("  Channel %0d:", c);
            for (h = 0; h < INPUT_HEIGHT; h = h + 1) begin
                $write("    Row %0d: ", h);
                for (w = 0; w < INPUT_WIDTH; w = w + 1) begin
                    // Simple pattern: (channel*100) + (row*10) + col
                    val = c * 100 + h * 10 + w;
                    conv_feature_map[c][h][w] = val;
                    $write("%4d ", val);
                end
                $write("\n");
            end
        end
        $display("");
    endtask
    
    // Compute expected pooled outputs
    task compute_expected_pool();
        integer c, ph, pw, dh, dw, conv_h, conv_w;
        integer sum;
        
        $display("Computing expected pool outputs:");
        for (c = 0; c < IN_CHANNELS; c = c + 1) begin
            $display("  Channel %0d:", c);
            for (ph = 0; ph < OUT_HEIGHT; ph = ph + 1) begin
                $write("    Row %0d: ", ph);
                for (pw = 0; pw < OUT_WIDTH; pw = pw + 1) begin
                    sum = 0;
                    for (dh = 0; dh < POOL_SIZE; dh = dh + 1) begin
                        for (dw = 0; dw < POOL_SIZE; dw = dw + 1) begin
                            conv_h = ph * POOL_SIZE + dh;
                            conv_w = pw * POOL_SIZE + dw;
                            sum = sum + conv_feature_map[c][conv_h][conv_w];
                        end
                    end
                    expected_pool[c][ph][pw] = sum / 4;
                    $write("%4d ", expected_pool[c][ph][pw]);
                end
                $write("\n");
            end
        end
        $display("");
    endtask
    
    // Feed conv data in tiles
    task feed_conv_data();
        integer tile_idx, ch_idx, win_start, tile_r, tile_c;
        integer total_windows, num_tiles;
        integer win_idx, row_pos, col_pos;
        
        total_windows = INPUT_HEIGHT * INPUT_WIDTH;
        num_tiles = (total_windows + TILE_ROWS - 1) / TILE_ROWS;
        
        // Feed tiles for each channel group
        for (ch_idx = 0; ch_idx < IN_CHANNELS; ch_idx = ch_idx + ARRAY_COLS) begin
            // Feed tiles for spatial positions
            for (tile_idx = 0; tile_idx < num_tiles; tile_idx = tile_idx + 1) begin
                win_start = tile_idx * TILE_ROWS;
                
                // Prepare tile data
                for (tile_r = 0; tile_r < TILE_ROWS; tile_r = tile_r + 1) begin
                    win_idx = win_start + tile_r;
                    
                    if (win_idx < total_windows) begin
                        row_pos = win_idx / INPUT_WIDTH;
                        col_pos = win_idx % INPUT_WIDTH;
                        
                        for (tile_c = 0; tile_c < ARRAY_COLS; tile_c = tile_c + 1) begin
                            if (ch_idx + tile_c < IN_CHANNELS) begin
                                input_data[tile_r][tile_c] = conv_feature_map[ch_idx + tile_c][row_pos][col_pos];
                            end else begin
                                input_data[tile_r][tile_c] = 0;
                            end
                        end
                    end else begin
                        for (tile_c = 0; tile_c < ARRAY_COLS; tile_c = tile_c + 1) begin
                            input_data[tile_r][tile_c] = 0;
                        end
                    end
                end
                
                // Send tile
                input_valid = 1;
                input_channel_start = ch_idx;
                input_window_idx_start = win_start;
                
                $display("Sending tile: ch_start=%0d, win_start=%0d", ch_idx, win_start);
                
                #10;  // One clock cycle
                input_valid = 0;
                #10;  // Gap between tiles
            end
        end
    endtask
    
    // Collect outputs
    always @(posedge clk) begin
        if (output_valid) begin
            integer out_r, out_c, pool_idx, ch, ph, pw;
            integer valid_outputs_in_tile;
            
            pool_outputs_received = pool_outputs_received + 1;
            valid_outputs_in_tile = 0;
            
            $display("\nPool tile %0d received at time %0t:", pool_outputs_received, $time);
            $display("  Channel start: %0d, Pool idx start: %0d", 
                     output_channel_start, output_pooled_idx_start);
            
            for (out_r = 0; out_r < TILE_ROWS; out_r = out_r + 1) begin
                pool_idx = output_pooled_idx_start + out_r;
                
                if (pool_idx < OUT_SIZE) begin
                    ph = pool_idx / OUT_WIDTH;
                    pw = pool_idx % OUT_WIDTH;
                    
                    $write("    Pool[%0d,%0d]: ", ph, pw);
                    
                    for (out_c = 0; out_c < ARRAY_COLS; out_c = out_c + 1) begin
                        ch = output_channel_start + out_c;
                        if (ch < IN_CHANNELS) begin
                            actual_pool[ch][ph][pw] = output_data[out_r][out_c];
                            valid_outputs_in_tile = valid_outputs_in_tile + 1;
                            $write("Ch%0d=%4d ", ch, output_data[out_r][out_c]);
                        end
                    end
                    $write("\n");
                end
            end
            
            $display("  Valid pool windows in this tile: %0d", valid_outputs_in_tile);
        end
    end
    
    // Display results
    task display_results();
        integer c, h, w;
        
        $display("\n========================================");
        $display("Actual Pool Outputs:");
        $display("========================================");
        for (c = 0; c < IN_CHANNELS; c = c + 1) begin
            $display("  Channel %0d:", c);
            for (h = 0; h < OUT_HEIGHT; h = h + 1) begin
                $write("    Row %0d: ", h);
                for (w = 0; w < OUT_WIDTH; w = w + 1) begin
                    $write("%4d ", actual_pool[c][h][w]);
                end
                $write("\n");
            end
        end
        $display("");
    endtask
    
    // Verify results
    task verify_results();
        integer c, h, w;
        integer total_pool_windows;
        integer valid_pools;
        
        $display("\n========================================");
        $display("Verification:");
        $display("========================================");
        
        valid_pools = 0;
        
        for (c = 0; c < IN_CHANNELS; c = c + 1) begin
            for (h = 0; h < OUT_HEIGHT; h = h + 1) begin
                for (w = 0; w < OUT_WIDTH; w = w + 1) begin
                    $display("Ch%0d[%0d,%0d]: Expected=%4d, Got=%4d", 
                             c, h, w, expected_pool[c][h][w], actual_pool[c][h][w]);
                    
                    if (expected_pool[c][h][w] != actual_pool[c][h][w]) begin
                        $display("  ? FAIL (diff = %0d)", 
                                 actual_pool[c][h][w] - expected_pool[c][h][w]);
                        errors = errors + 1;
                    end else begin
                        $display("  ? PASS");
                        valid_pools = valid_pools + 1;
                    end
                end
            end
        end
        
        total_pool_windows = IN_CHANNELS * OUT_HEIGHT * OUT_WIDTH;
        
        $display("\nTotal pool tiles received: %0d", pool_outputs_received);
        $display("Total pool windows verified: %0d/%0d", valid_pools, total_pool_windows);
        
        if (valid_pools != total_pool_windows) begin
            $display("? WARNING: Missing outputs!");
            errors = errors + 1;
        end else begin
            $display("? All pool windows received and verified!");
        end
    endtask
    
    // Timeout
    initial begin
        #10000;
        $display("\nERROR: Simulation timeout!");
        $finish;
    end
    
endmodule
    
