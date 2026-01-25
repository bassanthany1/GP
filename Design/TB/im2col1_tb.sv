// ============================================================
// Testbench for im2col1 module (without matlab files)
// ============================================================

module tb_im2col1();
    parameter IMG_W = 28;
    parameter IMG_H = 28;
    parameter KERNEL_SIZE = 5;
    parameter STRIDE = 1;
    parameter TILE_ROWS = 8;
    parameter IN_CHANNELS = 1;
    parameter DATA_WIDTH = 8;
    
    localparam WINDOW_SIZE = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;
    localparam OUT_W = (IMG_W - KERNEL_SIZE) / STRIDE + 1;
    localparam OUT_H = (IMG_H - KERNEL_SIZE) / STRIDE + 1;
    localparam TOTAL_WINDOWS = OUT_W * OUT_H;
    localparam NUM_TILES = (TOTAL_WINDOWS + TILE_ROWS - 1) / TILE_ROWS;
    
    logic clk, rst, start;
    logic tile_ready, done_all;
    logic signed [DATA_WIDTH-1:0] tile_data [TILE_ROWS][WINDOW_SIZE];
    logic signed [DATA_WIDTH-1:0] img_data_flat [IN_CHANNELS*IMG_H*IMG_W];
    
    // Instantiate DUT
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
    
    // Clock generation
    always #5 clk = ~clk;
    
    // Task to process all tiles with multiple start pulses
    task process_all_tiles(int test_case);
        automatic int tiles_processed = 0;
        
        $display("=== Test Case %0d: Processing %0d tiles ===", test_case, NUM_TILES);
        
        while (tiles_processed < NUM_TILES) begin
            // Send start pulse for next tile
            start = 1;
            @(posedge clk);
            start = 0;
            
            // Wait for tile_ready with timeout
            fork
                begin
                    @(posedge tile_ready);
                    $display("Tile %0d ready at time %0t", tiles_processed, $time);
                    
                    // Print sample data for first few tiles
                    if (tiles_processed < 2) begin
                        print_tile_sample(tiles_processed);
                    end
                    
                    tiles_processed++;
                end
                begin
                    #1000; // Timeout
                    $display("ERROR: Timeout waiting for tile_ready (tile %0d)", tiles_processed);
                    $finish;
                end
            join_any
            disable fork;
            
            // Small delay between tiles
            repeat(2) @(posedge clk);
        end
        
        $display("All %0d tiles processed successfully", NUM_TILES);
        
        // Check if done_all is asserted after last tile
        if (done_all) begin
            $display("done_all correctly asserted after last tile");
        end else begin
            $display("WARNING: done_all not asserted after last tile");
        end
        
        $display("Test Case %0d PASSED\n", test_case);
    endtask
    
    // Test case 1: Sequential pattern
    task test_case_1();
        $display("Initializing Test Case 1: Sequential pattern");
        
        // Fill image with sequential values
        for (int i = 0; i < IN_CHANNELS*IMG_H*IMG_W; i++) begin
            img_data_flat[i] = i % 256; // Keep within 8-bit range
        end
        
        process_all_tiles(1);
    endtask
    
    // Test case 2: Constant pattern  
    task test_case_2();
        $display("Initializing Test Case 2: Constant pattern");
        
        // Fill image with constant pattern
        for (int i = 0; i < IN_CHANNELS*IMG_H*IMG_W; i++) begin
            img_data_flat[i] = 77; // All values = 77
        end
        
        process_all_tiles(2);
    endtask
    
    // Helper task to print sample of tile data
    task print_tile_sample(int tile_num);
        $display("Tile %0d data sample:", tile_num);
        for (int row = 0; row < 2 && row < TILE_ROWS; row++) begin // First 2 rows
            $write("  Row %2d: ", row);
            for (int elem = 0; elem < 6 && elem < WINDOW_SIZE; elem++) begin // First 6 elements
                $write("%3d ", tile_data[row][elem]);
            end
            if (WINDOW_SIZE > 6) $write("...");
            $display("");
        end
        $display("");
    endtask
    
    // Monitor FSM activity
    initial begin
        forever begin
            @(posedge clk);
            if (start) begin
                $display("[MONITOR] start pulse at time %0t", $time);
            end
            if (tile_ready) begin
                $display("[MONITOR] tile_ready pulse at time %0t", $time);
            end
            if (done_all) begin
                $display("[MONITOR] done_all asserted at time %0t", $time);
            end
        end
    end
    
    // Main test sequence
    initial begin
        $display("Starting im2col1 testbench");
        $display("Configuration: IMG_W=%0d, IMG_H=%0d, KERNEL_SIZE=%0d", IMG_W, IMG_H, KERNEL_SIZE);
        $display("TILE_ROWS=%0d, TOTAL_WINDOWS=%0d, NUM_TILES=%0d", TILE_ROWS, TOTAL_WINDOWS, NUM_TILES);
        
        // Initialize
        clk = 0;
        rst = 1;
        start = 0;
        
        // Initialize image data to zeros
        foreach(img_data_flat[i]) begin
            img_data_flat[i] = 0;
        end
        
        // Apply reset
        #10;
        rst = 1;
        #20;
        rst = 0;
        #10;
        
        $display("Reset complete, starting tests...");
        
        // Run test cases
        test_case_1();
        
        // Small gap between test cases
        repeat(10) @(posedge clk);
        
        test_case_2();
        
        $display("=== ALL TESTS PASSED ===");
        $display("Simulation completed successfully at time %0t", $time);
        $finish;
    end
    
    // Global timeout
    initial begin
        #50000; // 50,000 time units global timeout
        $display("ERROR: Global simulation timeout");
        $display("Check if FSM is waiting for start pulses");
        $finish;
    end
    
endmodule

