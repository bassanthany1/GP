
// ============================================================
// Testbench for Complete Convolution System with Verification
// Parameters: 3x3 kernel, 5x5 input, 3 output channels
// ============================================================

module tb_conv_system_top;

    // ========== Parameters ==========
    localparam KERNEL_SIZE   = 3;
    localparam IN_CHANNELS   = 1;
    localparam OUT_CHANNELS  = 3;
    localparam INPUT_HEIGHT  = 5;
    localparam INPUT_WIDTH   = 5;
    localparam TILE_ROWS     = 3;
    localparam ARRAY_COLS    = 3;
    localparam DATA_WIDTH    = 8;
    localparam BIAS_WIDTH    = 32;
    
    localparam OUTPUT_HEIGHT = INPUT_HEIGHT - KERNEL_SIZE + 1;  // 3
    localparam OUTPUT_WIDTH  = INPUT_WIDTH - KERNEL_SIZE + 1;   // 3
    localparam TOTAL_WINDOWS = OUTPUT_HEIGHT * OUTPUT_WIDTH;    // 9
    
    // ========== Signals ==========
    logic clk;
    logic rst;
    
    // Control signals
    logic start_conv;
    logic enable_relu;
    logic conv_done;
    
    // Input data
    logic signed [DATA_WIDTH-1:0] input_data_flat [IN_CHANNELS*INPUT_HEIGHT*INPUT_WIDTH];
    
    // Weight and bias data
    logic signed [DATA_WIDTH-1:0] weight_data [OUT_CHANNELS*KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS];
    logic weight_data_valid;
    logic signed [BIAS_WIDTH-1:0] bias_data [OUT_CHANNELS];
    
    // Output interface
    logic output_valid;
    logic [7:0] output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(OUT_CHANNELS)-1:0] output_channel_start;
    logic [$clog2(INPUT_HEIGHT*INPUT_WIDTH)-1:0] output_window_idx_start;
    
    // Expected results storage
    logic [7:0] expected_output [OUT_CHANNELS][TOTAL_WINDOWS];
    int output_count;
    int errors;
    
    // ========== DUT Instantiation ==========
    conv_system_top #(
        .KERNEL_SIZE(KERNEL_SIZE),
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .INPUT_HEIGHT(INPUT_HEIGHT),
        .INPUT_WIDTH(INPUT_WIDTH),
        .TILE_ROWS(TILE_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .DATA_WIDTH(DATA_WIDTH),
        .BIAS_WIDTH(BIAS_WIDTH),
        .IN_SCALE(32'd2147484),   // 0.001
        .WE_SCALE(32'd2147484),   // 0.001
        .OUT_SCALE(32'd21474836),  // 0.01
        .QUANT_SHIFT(24)
    ) dut (.*);
    
    // ========== Clock Generation ==========
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // ========== Helper Functions ==========
    
    // Function to compute expected convolution result
    function automatic int compute_conv_manual(
        input int window_idx,
        input int out_ch
    );
        int sum;
        int wy, wx;
        int weight_idx;
        
        sum = 0;
        wy = window_idx / OUTPUT_WIDTH;
        wx = window_idx % OUTPUT_WIDTH;
        
        // Perform convolution
        for (int ky = 0; ky < KERNEL_SIZE; ky++) begin
            for (int kx = 0; kx < KERNEL_SIZE; kx++) begin
                for (int ic = 0; ic < IN_CHANNELS; ic++) begin
                    int img_y = wy + ky;
                    int img_x = wx + kx;
                    int img_idx = ic * INPUT_HEIGHT * INPUT_WIDTH + img_y * INPUT_WIDTH + img_x;
                    
                    weight_idx = out_ch * (KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS) +
                                ic * (KERNEL_SIZE * KERNEL_SIZE) +
                                ky * KERNEL_SIZE + kx;
                    
                    sum += $signed(input_data_flat[img_idx]) * $signed(weight_data[weight_idx]);
                end
            end
        end
        
        return sum;
    endfunction
    
    // Function to apply bias and ReLU
    function automatic int apply_bias_relu(
        input int conv_result,
        input int out_ch,
        input logic relu_en
    );
        int with_bias;
        
        with_bias = conv_result + bias_data[out_ch];
        
        if (relu_en && with_bias < 0)
            return 0;
        else
            return with_bias;
    endfunction
    
    // Function to perform requantization
    function automatic logic [7:0] requantize(
        input int value
    );
        longint temp_scale;
        int requant_scale;
        longint mult_res;
        int shift_res;
        
        // Calculate scale: (in_scale * we_scale) / out_scale
        // (0.02 * 0.03) / 0.01 = 0.06
        temp_scale = 64'(32'd2147484) * 64'(332'd2147484);
        requant_scale = int'((temp_scale + (32'd21474836>>1)) / 32'd21474836);
        
        // Multiply
        mult_res = longint'(value) * longint'(requant_scale);
        
        // Shift with rounding
        shift_res = int'((mult_res + (1 << 23)) >>> 24);
        
        // Saturate to uint8
        if (shift_res > 255)
            return 8'd255;
        else if (shift_res < 0)
            return 8'd0;
        else
            return shift_res[7:0];
    endfunction
    
    // ========== Test Tasks ==========
    
    // Initialize test data with known values
    task initialize_data();
        $display("\n========== Initializing Test Data ==========");
        
        // Simple input: incrementing pattern
        $display("Input Image (5x5):");
        for (int i = 0; i < INPUT_HEIGHT * INPUT_WIDTH; i++) begin
            input_data_flat[i] = $signed(8'(i + 1));  // 1, 2, 3, ... 25
            if (i % INPUT_WIDTH == 0) $write("\n  ");
            $write("%3d ", input_data_flat[i]);
        end
        $write("\n");
        
        // Simple weights: small values for manageable results
        $display("\nWeights:");
        for (int oc = 0; oc < OUT_CHANNELS; oc++) begin
            $display("  Channel %0d kernel (3x3):", oc);
            for (int i = 0; i < KERNEL_SIZE * KERNEL_SIZE; i++) begin
                automatic int idx = oc * KERNEL_SIZE * KERNEL_SIZE + i;
                // Channel 0: all 1's
                // Channel 1: alternating 1,-1
                // Channel 2: edge detector pattern
                if (oc == 0)
                    weight_data[idx] = 8'sd1;
                else if (oc == 1)
                    weight_data[idx] = (i % 2 == 0) ? 8'sd1 : -8'sd1;
                else  // oc == 2
                    weight_data[idx] = (i < 3) ? -8'sd1 : ((i > 5) ? 8'sd1 : 8'sd0);
                
                if (i % KERNEL_SIZE == 0) $write("    ");
                $write("%3d ", weight_data[idx]);
                if ((i + 1) % KERNEL_SIZE == 0) $write("\n");
            end
        end
        
        // Simple biases
        $display("\nBiases:");
        for (int i = 0; i < OUT_CHANNELS; i++) begin
            bias_data[i] = 32'sd10 * (i + 1);  // 10, 20, 30
            $display("  Channel %0d: %0d", i, bias_data[i]);
        end
        
        $display("============================================\n");
    endtask
    
    // Compute expected results
    task compute_expected_results();
        int conv_result;
        int with_bias_relu;
        
        $display("\n========== Computing Expected Results ==========");
        
        for (int oc = 0; oc < OUT_CHANNELS; oc++) begin
            $display("\nChannel %0d:", oc);
            for (int win = 0; win < TOTAL_WINDOWS; win++) begin
                // Step 1: Convolution
                conv_result = compute_conv_manual(win, oc);
                
                // Step 2: Add bias and apply ReLU
                with_bias_relu = apply_bias_relu(conv_result, oc, enable_relu);
                
                // Step 3: Requantization
                expected_output[oc][win] = requantize(with_bias_relu);
                
                $display("  Window %0d: Conv=%0d, +Bias+ReLU=%0d, Requant=%0d",
                        win, conv_result, with_bias_relu, expected_output[oc][win]);
            end
        end
        $display("================================================\n");
    endtask
    
    // Monitor and verify outputs
    task monitor_outputs();
        output_count = 0;
        errors = 0;
        
        $display("\n========== Monitoring Outputs ==========");
        
        fork
            begin
                while (!conv_done) begin
                    @(posedge clk);
                    if (output_valid) begin
                        $display("\nTime %0t: Output Tile %0d", $time, output_count);
                        $display("  Channel start: %0d, Window idx start: %0d", 
                                output_channel_start, output_window_idx_start);
                        
                        // Check each output in the tile
                        for (int r = 0; r < TILE_ROWS; r++) begin
                            for (int c = 0; c < ARRAY_COLS; c++) begin
                                automatic int channel = output_channel_start + c;
                                automatic int window = output_window_idx_start + r;
                                
                                if (channel < OUT_CHANNELS && window < TOTAL_WINDOWS) begin
                                    automatic logic [7:0] actual = output_data[r][c];
                                    automatic logic [7:0] expected = expected_output[channel][window];
                                    
                                    $write("  [%0d][%0d] Ch%0d,Win%0d: Actual=%3d, Expected=%3d",
                                           r, c, channel, window, actual, expected);
                                    
                                    if (actual == expected) begin
                                        $display(" ?");
                                    end else begin
                                        $display(" ? ERROR!");
                                        errors++;
                                    end
                                end
                            end
                        end
                        
                        output_count++;
                    end
                end
            end
        join
        
        $display("\n========================================");
    endtask
    
    // ========== Main Test ==========
    initial begin
        // Initialize
        rst = 1;
        start_conv = 0;
        enable_relu = 1;
        weight_data_valid = 1;
        output_count = 0;
        errors = 0;
        
        $display("\n========================================");
        $display("Convolution System Testbench");
        $display("5x5 Input, 3x3 Kernel, 3 Output Channels");
        $display("========================================");
        
        // Initialize test data
        initialize_data();
        
        // Compute expected results
        compute_expected_results();
        
        // Reset
        #20;
        rst = 0;
        #20;
        
        // Start convolution
        $display("\n========== Starting Convolution ==========");
        $display("Time %0t: Asserting start_conv\n", $time);
        start_conv = 1;
        #10;
        start_conv = 0;
        
        // Monitor outputs
        monitor_outputs();
        
        // Wait for completion
        wait(conv_done);
        $display("\nTime %0t: Convolution done", $time);
        #50;
        
        // Final report
        $display("\n========== TEST SUMMARY ==========");
        $display("Total output tiles: %0d", output_count);
        $display("Total comparisons: %0d", OUT_CHANNELS * TOTAL_WINDOWS);
        $display("Total errors: %0d", errors);
        
        if (errors == 0) begin
            $display("\n*** ALL TESTS PASSED ***");
        end else begin
            $display("\n*** TEST FAILED ***");
        end
        $display("==================================\n");
        
        $finish;
    end
    
    // ========== Timeout ==========
    initial begin
        #100000;
        $display("ERROR: Timeout!");
        $finish;
    end
    
    // ========== Waveform Dump ==========
    initial begin
        $dumpfile("conv_system_top.vcd");
        $dumpvars(0, tb_conv_system_top);
    end

endmodule
