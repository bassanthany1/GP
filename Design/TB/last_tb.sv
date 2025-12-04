// ============================================================
// RANDOM CHECK TESTBENCH - Displays random sample checks with ReLU
// ============================================================

module conv_tb_python;
    
    parameter KERNEL_SIZE   = 5;
    parameter IN_CHANNELS   = 1;
    parameter OUT_CHANNELS  = 6;
    parameter INPUT_HEIGHT  = 28;
    parameter INPUT_WIDTH   = 28;
    parameter TILE_ROWS     = 8;
    parameter ARRAY_COLS    = 6;
    parameter DATA_WIDTH    = 8;
    parameter BIAS_WIDTH    = 32;
    
    localparam OUTPUT_HEIGHT = INPUT_HEIGHT - KERNEL_SIZE + 1;
    localparam OUTPUT_WIDTH  = INPUT_WIDTH - KERNEL_SIZE + 1;
    localparam TOTAL_OUTPUTS = OUTPUT_HEIGHT * OUTPUT_WIDTH * OUT_CHANNELS;
    
    logic clk, rst;
    logic start_conv;
    logic conv_done;
    
    // Input data
    logic signed [DATA_WIDTH-1:0] input_data_flat [IN_CHANNELS*INPUT_HEIGHT*INPUT_WIDTH];
    
    // Weights
    logic signed [DATA_WIDTH-1:0] weight_data [OUT_CHANNELS*KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS];
    logic weight_data_valid;
    
    // Bias values
    logic signed [BIAS_WIDTH-1:0] bias_data [OUT_CHANNELS];
    
    // Expected outputs (after ReLU)
    logic signed [4*DATA_WIDTH-1:0] expected_output_flat [TOTAL_OUTPUTS];
    
    // Outputs
    logic output_valid;
    logic signed [4*DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(OUT_CHANNELS)-1:0] output_channel_start;
    logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] output_window_idx_start;
    
    // Storage for verification
    logic signed [4*DATA_WIDTH-1:0] output_feature_map [OUT_CHANNELS][OUTPUT_HEIGHT][OUTPUT_WIDTH];
    
    // Statistics
    int output_count;
    
    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // DUT with ReLU ENABLED
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
        .enable_relu(1'b1),  // **ReLU ENABLED**
        .conv_done(conv_done),
        .input_data_flat(input_data_flat),
        .weight_data(weight_data),
        .weight_data_valid(1'b1),
        .bias_data(bias_data),
        .output_valid(output_valid),
        .output_data(output_data),
        .output_channel_start(output_channel_start),
        .output_window_idx_start(output_window_idx_start)
    );
    
    // Main test
    initial begin
        // Initialize
        rst = 1;
        start_conv = 0;
        output_count = 0;
        
        // Initialize storage
        for (int c = 0; c < OUT_CHANNELS; c++)
            for (int h = 0; h < OUTPUT_HEIGHT; h++)
                for (int w = 0; w < OUTPUT_WIDTH; w++)
                    output_feature_map[c][h][w] = 0;
        
        $display("\n========================================");
        $display("RANDOM SAMPLE CHECKS - Conv + Bias + ReLU Test");
        $display("========================================");
        $display("ReLU: ENABLED");
        $display("Output shape: %0d channels × %0d height × %0d width", 
                 OUT_CHANNELS, OUTPUT_HEIGHT, OUTPUT_WIDTH);
        $display("Total outputs: %0d", TOTAL_OUTPUTS);
        $display("========================================\n");
        
        // Load files
        $display("[1] Loading input data...");
        $readmemh("input1.mem", input_data_flat);
        
        $display("[2] Loading weights...");
        $readmemh("conv1_weights.mem", weight_data);
        
        $display("[3] Loading bias...");
        $readmemh("conv1_bias.mem", bias_data);
        
        $display("[4] Loading expected outputs (after ReLU)...");
        $readmemh("conv1_output_relu.mem", expected_output_flat);
        
        // Display random input samples
        $display("\n========================================");
        $display("RANDOM INPUT SAMPLES (int8):");
        $display("========================================");
        for (int i = 0; i < 10; i++) begin
            int idx;
            idx = $urandom_range(0, 783);  // 28×28=784
            $display("  input[%0d] = %0d (0x%02h)", idx, 
                     $signed(input_data_flat[idx]), input_data_flat[idx]);
        end
        
        // Display random weight samples
        $display("\n========================================");
        $display("RANDOM WEIGHT SAMPLES (int8):");
        $display("========================================");
        for (int i = 0; i < 10; i++) begin
            int idx;
            idx = $urandom_range(0, 149);  // 6×5×5=150 per filter
            $display("  weight[%0d] = %0d (0x%02h)", idx, 
                     $signed(weight_data[idx]), weight_data[idx]);
        end
        
        // Display all bias values
        $display("\n========================================");
        $display("BIAS VALUES (int32):");
        $display("========================================");
        for (int c = 0; c < OUT_CHANNELS; c++) begin
            $display("  Channel %0d bias = %0d (0x%08h)", c, 
                     $signed(bias_data[c]), bias_data[c]);
        end
        
        // Display random expected output samples
        $display("\n========================================");
        $display("RANDOM EXPECTED OUTPUT SAMPLES (Python + ReLU):");
        $display("========================================");
        for (int i = 0; i < 15; i++) begin
            int idx, c, hw_idx, h, w;
            idx = $urandom_range(0, TOTAL_OUTPUTS-1);
            c = idx / (OUTPUT_HEIGHT * OUTPUT_WIDTH);
            hw_idx = idx % (OUTPUT_HEIGHT * OUTPUT_WIDTH);
            h = hw_idx / OUTPUT_WIDTH;
            w = hw_idx % OUTPUT_WIDTH;
            
            $display("  Python[ch=%0d][h=%0d][w=%0d] = %0d", 
                     c, h, w, $signed(expected_output_flat[idx]));
        end
        
        $display("\n\nStarting RTL convolution with ReLU...");
        
        // Reset and start
        #20; rst = 0; #20;
        start_conv = 1;
        #10; start_conv = 0;
        
        // Wait for completion
        wait(conv_done == 1);
        #20;
        
        $display("\nRTL convolution complete!");
        
        // Display random RTL output samples
        $display("\n========================================");
        $display("RANDOM RTL OUTPUT SAMPLES (after ReLU):");
        $display("========================================");
        for (int i = 0; i < 15; i++) begin
            int c, h, w;
            c = $urandom_range(0, OUT_CHANNELS-1);
            h = $urandom_range(0, OUTPUT_HEIGHT-1);
            w = $urandom_range(0, OUTPUT_WIDTH-1);
            
            $display("  RTL[ch=%0d][h=%0d][w=%0d] = %0d", 
                     c, h, w, output_feature_map[c][h][w]);
        end
        
        // Compare specific positions
        $display("\n========================================");
        $display("DIRECT COMPARISON AT RANDOM POSITIONS:");
        $display("========================================");
        for (int i = 0; i < 10; i++) begin
            int c, h, w, idx;
            logic signed [31:0] rtl_val, py_val;
            
            c = $urandom_range(0, OUT_CHANNELS-1);
            h = $urandom_range(0, OUTPUT_HEIGHT-1);
            w = $urandom_range(0, OUTPUT_WIDTH-1);
            idx = c * OUTPUT_HEIGHT * OUTPUT_WIDTH + h * OUTPUT_WIDTH + w;
            rtl_val = output_feature_map[c][h][w];
            py_val = expected_output_flat[idx];
            
            if (rtl_val === py_val) begin
                $display("? Position [ch=%0d][h=%0d][w=%0d]: RTL=%0d == Python=%0d", 
                         c, h, w, rtl_val, py_val);
            end else begin
                $display("? Position [ch=%0d][h=%0d][w=%0d]: RTL=%0d != Python=%0d (diff=%0d)", 
                         c, h, w, rtl_val, py_val, rtl_val - py_val);
            end
        end
        
        // Corner checks
        $display("\n========================================");
        $display("CORNER POSITION CHECKS:");
        $display("========================================");
        
        // Top-left corners of each channel
        for (int c = 0; c < OUT_CHANNELS; c++) begin
            int idx_tl;
            logic signed [31:0] rtl_tl, py_tl;
            
            idx_tl = c * OUTPUT_HEIGHT * OUTPUT_WIDTH;
            rtl_tl = output_feature_map[c][0][0];
            py_tl = expected_output_flat[idx_tl];
            
            if (rtl_tl === py_tl) begin
                $display("? Channel %0d top-left: RTL=%0d == Python=%0d", c, rtl_tl, py_tl);
            end else begin
                $display("? Channel %0d top-left: RTL=%0d != Python=%0d", c, rtl_tl, py_tl);
            end
        end
        
        // Bottom-right corners
        for (int c = 0; c < OUT_CHANNELS; c++) begin
            int idx_br;
            logic signed [31:0] rtl_br, py_br;
            
            idx_br = c * OUTPUT_HEIGHT * OUTPUT_WIDTH + 
                     (OUTPUT_HEIGHT-1) * OUTPUT_WIDTH + (OUTPUT_WIDTH-1);
            rtl_br = output_feature_map[c][OUTPUT_HEIGHT-1][OUTPUT_WIDTH-1];
            py_br = expected_output_flat[idx_br];
            
            if (rtl_br === py_br) begin
                $display("? Channel %0d bottom-right: RTL=%0d == Python=%0d", c, rtl_br, py_br);
            end else begin
                $display("? Channel %0d bottom-right: RTL=%0d != Python=%0d", c, rtl_br, py_br);
            end
        end
        
        // Final summary
        $display("\n========================================");
        $display("FINAL VERIFICATION:");
        $display("========================================");
        
        // Count correct outputs
        begin
            automatic int correct_count = 0;
            automatic int zero_count = 0;
            for (int c = 0; c < OUT_CHANNELS; c++) begin
                for (int h = 0; h < OUTPUT_HEIGHT; h++) begin
                    for (int w = 0; w < OUTPUT_WIDTH; w++) begin
                        int idx;
                        idx = c * OUTPUT_HEIGHT * OUTPUT_WIDTH + h * OUTPUT_WIDTH + w;
                        if (output_feature_map[c][h][w] === expected_output_flat[idx]) begin
                            correct_count++;
                        end
                        if (output_feature_map[c][h][w] == 0) begin
                            zero_count++;
                        end
                    end
                end
            end
            
            $display("Zero values after ReLU: %0d/%0d (%.1f%%)", 
                     zero_count, TOTAL_OUTPUTS, 100.0 * zero_count / TOTAL_OUTPUTS);
            
            if (correct_count == TOTAL_OUTPUTS) begin
                $display("? ALL %0d OUTPUTS MATCH PERFECTLY!", TOTAL_OUTPUTS);
                $display("? Python model output (with ReLU) == RTL output (with ReLU)");
                $display("? VERIFICATION SUCCESS!");
            end else begin
                $display("? %0d/%0d outputs match (%0d mismatches)", 
                         correct_count, TOTAL_OUTPUTS, TOTAL_OUTPUTS - correct_count);
                $display("? Match percentage: %.2f%%", 100.0 * correct_count / TOTAL_OUTPUTS);
            end
        end
        
        $display("\n========================================\n");
        
        #100;
        $finish;
    end
    
    // Collect outputs
    always @(posedge clk) begin
        if (output_valid) begin
            int win_idx_start, ch_start;
            
            win_idx_start = output_window_idx_start;
            ch_start = output_channel_start;
            
            for (int tile_row = 0; tile_row < TILE_ROWS; tile_row++) begin
                int win_idx, row, col;
                
                win_idx = win_idx_start + tile_row;
                
                if (win_idx < TOTAL_OUTPUTS / OUT_CHANNELS) begin
                    row = win_idx / OUTPUT_WIDTH;
                    col = win_idx % OUTPUT_WIDTH;
                    
                    for (int tile_col = 0; tile_col < ARRAY_COLS; tile_col++) begin
                        int ch_idx;
                        ch_idx = ch_start + tile_col;
                        if (ch_idx < OUT_CHANNELS) begin
                            output_feature_map[ch_idx][row][col] = output_data[tile_row][tile_col];
                            output_count++;
                        end
                    end
                end
            end
        end
    end
    
    // Timeout
    initial begin
        #1000000;
        $display("\nERROR: Simulation timeout!");
        $finish;
    end
    
endmodule
