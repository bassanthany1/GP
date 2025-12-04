module im_tb;
    localparam IMG_W        = 28;
    localparam IMG_H        = 28;
    localparam KERNEL_SIZE  = 5;
    localparam TILE_ROWS    = 8;
    localparam IN_CHANNELS  = 1;
    localparam DATA_WIDTH   = 8;
    localparam STRIDE       = 1;
    
    // Calculate expected windows
    localparam OUT_W = (IMG_W - KERNEL_SIZE) / STRIDE + 1;
    localparam OUT_H = (IMG_H - KERNEL_SIZE) / STRIDE + 1;
    localparam TOTAL_WINDOWS = OUT_W * OUT_H;
    localparam WINDOW_SIZE = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;
    localparam TOTAL_TILES = (TOTAL_WINDOWS + TILE_ROWS - 1) / TILE_ROWS;
    
    logic clk, rst, start;
    logic tile_ready, done_all;
    logic  [DATA_WIDTH-1:0] img_data_flat [IN_CHANNELS*IMG_H*IMG_W];
    logic [DATA_WIDTH-1:0] tile_data [TILE_ROWS][KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS];
    
    // Expected data from MATLAB
    logic [DATA_WIDTH-1:0] expected_windows [TOTAL_WINDOWS][WINDOW_SIZE];
    int window_count;
    int error_count;
    int tile_count;
    
    // DUT - im2col1 with img_data_flat interface
    im2col1 #(
        .IMG_W(IMG_W),
        .IMG_H(IMG_H),
        .KERNEL_SIZE(KERNEL_SIZE),
        .STRIDE(STRIDE),
        .TILE_ROWS(TILE_ROWS),
        .IN_CHANNELS(IN_CHANNELS),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .tile_ready(tile_ready),
        .done_all(done_all),
        .tile_data(tile_data),
        .img_data_flat(img_data_flat)
    );
    
    // Clock
    initial clk = 0;
    always #5 clk = ~clk;
    
    initial begin
        int idx;
        
        $display("========================================");
        $display("im2col1 Testbench with MATLAB Comparison");
        $display("Multi-Start Mode (start asserted per tile)");
        $display("========================================");
        $display("Parameters:");
        $display("  Image: %0dx%0d", IMG_W, IMG_H);
        $display("  Kernel: %0dx%0d", KERNEL_SIZE, KERNEL_SIZE);
        $display("  Stride: %0d", STRIDE);
        $display("  Tile rows: %0d", TILE_ROWS);
        $display("  Expected windows: %0d", TOTAL_WINDOWS);
        $display("  Expected tiles: %0d", TOTAL_TILES);
        $display("========================================\n");
        
        // Read flattened image file using $readmemh
        $display("Loading image from image_hex.mem...");
        $readmemh("image_hex.mem", img_data_flat);
        $display("Image loaded successfully (%0d pixels)\n", IN_CHANNELS*IMG_H*IMG_W);
        
        // Display loaded image - reconstruct for display
        $display("========================================");
        $display("Loaded Image Data (Channel 0) - First 5 rows:");
        $display("========================================");
        for (int y = 0; y < 5; y++) begin
            $write("Row %2d: ", y);
            for (int x = 0; x < IMG_W; x++) begin
             automatic   int flat_idx = y*IMG_W + x;
                $write("%3d ", img_data_flat[flat_idx]);
            end
            $display("");
        end
        $display("... (showing first 5 rows only)\n");
        
        // Show first 5x5 window manually for verification
        $display("First 5x5 window (top-left corner):");
        for (int y = 0; y < KERNEL_SIZE; y++) begin
            for (int x = 0; x < KERNEL_SIZE; x++) begin
         automatic       int flat_idx = y*IMG_W + x;
                $write("%3d ", img_data_flat[flat_idx]);
            end
            $display("");
        end
        $display("");
    end
    
    // Load expected windows from MATLAB output
    initial begin
        int fd;
        int value;
        int win_idx, elem_idx;
        int scan_result;
        int window_number;
        string line;
        
        // Initialize all expected windows to 0 first
        for (int i = 0; i < TOTAL_WINDOWS; i++) begin
            for (int j = 0; j < WINDOW_SIZE; j++) begin
                expected_windows[i][j] = 0;
            end
        end
        
        // Wait a bit for image to load
        #1;
        
        fd = $fopen("all_windows9.txt", "r");
        if (fd == 0) begin
            $display("ERROR: Cannot open all_windows9.txt");
            $display("Make sure to run MATLAB script first to generate all_windows9.txt");
            $finish;
        end
        
        $display("Loading expected windows from all_windows9.txt...");
        
        // Skip header lines (5 lines)
        for (int i = 0; i < 5; i++) begin
            void'($fgets(line, fd));
        end
        
        // Read window data - format: "Window N: val1 val2 val3 ..."
        // MATLAB starts from Window 1, array index starts from 0
        win_idx = 0;
        while (!$feof(fd) && win_idx < TOTAL_WINDOWS) begin
            // Read "Window" keyword and number and colon
            scan_result = $fscanf(fd, " Window %d :", window_number);
            
            if (scan_result != 1) begin
                // End of file or format error
                break;
            end
            
            // Read all window elements
            for (elem_idx = 0; elem_idx < WINDOW_SIZE; elem_idx++) begin
                scan_result = $fscanf(fd, "%d", value);
                if (scan_result != 1) begin
                    $display("ERROR: Failed to read window %0d element %0d", win_idx+1, elem_idx);
                    $fclose(fd);
                    $finish;
                end
                expected_windows[win_idx][elem_idx] = value[DATA_WIDTH-1:0];
            end
            
            win_idx++;
        end
        
        $fclose(fd);
        
        if (win_idx != TOTAL_WINDOWS) begin
            $display("WARNING: Expected %0d windows but loaded %0d windows", TOTAL_WINDOWS, win_idx);
        end else begin
            $display("Expected windows loaded successfully (%0d windows)\n", TOTAL_WINDOWS);
        end
        
        // Debug: Print first expected window
        $display("MATLAB First expected window:");
        $write("  Window 0: ");
        for (int i = 0; i < WINDOW_SIZE; i++)
            $write("%3d ", expected_windows[0][i]);
        $display("\n");
    end
    
    // Test sequence variables
    int current_window;
    int match;
    int r, k;
    
    // Test sequence with start assertion per tile
    initial begin
        rst = 1;
        start = 0;
        window_count = 0;
        error_count = 0;
        tile_count = 0;
        
        #20 rst = 0;
        #10;
        
        $display("========================================");
        $display("Starting comparison with multi-start mode...\n");
        
        // Main loop - assert start for each tile
        while (tile_count < TOTAL_TILES && !done_all) begin
            // Assert start pulse
            $display(">>> Asserting start for tile %0d/%0d <<<", tile_count + 1, TOTAL_TILES);
            @(posedge clk);
            start = 1;
            @(posedge clk);
            start = 0;
            
            // Wait for tile_ready
            @(posedge clk);
            while (!tile_ready && !done_all) begin
                @(posedge clk);
            end
            
            if (tile_ready) begin
                tile_count++;
                $display("====== TILE %0d READY ======", tile_count);
                
                for (r = 0; r < TILE_ROWS; r++) begin
                    current_window = window_count + r;
                    
                    // Skip if beyond total windows
                    if (current_window >= TOTAL_WINDOWS) break;
                    
                    // Print actual output
                    $write("RTL Window %3d: ", current_window);
                    for (k = 0; k < WINDOW_SIZE; k++)
                        $write("%3d ", tile_data[r][k]);
                    $display("");
                    
                    // Print expected output
                    $write("MAT Window %3d: ", current_window);
                    for (k = 0; k < WINDOW_SIZE; k++)
                        $write("%3d ", expected_windows[current_window][k]);
                    $display("");
                    
                    // Compare
                    match = 1;
                    for (k = 0; k < WINDOW_SIZE; k++) begin
                        if (tile_data[r][k] !== expected_windows[current_window][k]) begin
                            match = 0;
                            error_count++;
                            $display("  ERROR at window %0d, element %0d: RTL=%0d, Expected=%0d",
                                     current_window, k, tile_data[r][k], expected_windows[current_window][k]);
                        end
                    end
                    
                    if (match)
                        $display("  -> MATCH!");
                    else
                        $display("  -> MISMATCH!");
                    $display("");
                end
                
                window_count = window_count + TILE_ROWS;
                $display("==============================\n");
            end
            
            // Check if done
            if (done_all) begin
                $display(">>> done_all asserted <<<");
                break;
            end
            
            // Small delay between tiles
            repeat(2) @(posedge clk);
        end
        
        // Final summary
        $display("========================================");
        $display("Simulation Complete!");
        $display("========================================");
        $display("Total windows processed: %0d", window_count);
        $display("Total tiles generated: %0d", tile_count);
        $display("Expected tiles: %0d", TOTAL_TILES);
        $display("Total errors: %0d", error_count);
        if (error_count == 0 && tile_count == TOTAL_TILES)
            $display("*** ALL TESTS PASSED! ***");
        else
            $display("*** TESTS FAILED! ***");
        $display("========================================");
        #20 $finish;
    end
    
    // Monitor for unexpected done_all
    always @(posedge clk) begin
        if (done_all && tile_count < TOTAL_TILES) begin
            $display("WARNING: done_all asserted early at tile %0d/%0d", tile_count, TOTAL_TILES);
        end
    end
    
    // Timeout watchdog
    initial begin
        #100000;
        $display("ERROR: Simulation timeout!");
        $finish;
    end
    
endmodule
