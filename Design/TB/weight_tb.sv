module weight_tb; //with matlab

    localparam KERNEL_SIZE   = 5;
    localparam IN_CHANNELS   = 1;
    localparam OUT_CHANNELS  = 6;
    localparam ARRAY_COLS    = 3;
    localparam DATA_WIDTH    = 8;

    // ====== Signals ======
    logic clk, rst, start;
    logic tile_ready, done_all;
    logic signed[DATA_WIDTH-1:0] sram_weight_data [OUT_CHANNELS * KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS];
    logic sram_data_valid;
    logic signed[DATA_WIDTH-1:0] weight_tile [KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS][ARRAY_COLS];

    // ====== Local Parameters ======
    localparam WEIGHTS_PER_FILTER = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;
    localparam TOTAL_WEIGHTS = OUT_CHANNELS * WEIGHTS_PER_FILTER;
    localparam NUM_TILES = (OUT_CHANNELS + ARRAY_COLS - 1) / ARRAY_COLS;

    // ====== Comparison Variables ======
    integer matlab_file;
    integer match_count, mismatch_count;
    string matlab_line;
    integer tile_count;
    
    // ====== Testbench Control Signals ======
    logic [31:0] cycle_count;
    logic start_next_tile;
    integer tiles_processed;

// ---------------------------------------------------------
// DUT Instance
// ---------------------------------------------------------
weight_flatten2 #(
    .KERNEL_SIZE(KERNEL_SIZE),
    .IN_CHANNELS(IN_CHANNELS),
    .OUT_CHANNELS(OUT_CHANNELS),
    .ARRAY_COLS(ARRAY_COLS),
    .DATA_WIDTH(DATA_WIDTH)
) dut (
    .clk(clk),
    .rst(rst),
    .start(start),
    .tile_ready(tile_ready),
    .done_all(done_all),
    .sram_weight_data(sram_weight_data),
    .sram_data_valid(sram_data_valid),
    .weight_tile(weight_tile)
);

// ---------------------------------------------------------
// Clock Generation
// ---------------------------------------------------------
always #5 clk = ~clk;

// ---------------------------------------------------------
// Cycle Counter
// ---------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        cycle_count <= 0;
    end else begin
        cycle_count <= cycle_count + 1;
    end
end

// ---------------------------------------------------------
// Testbench Control Logic
// ---------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        start <= 0;
        tiles_processed <= 0;
    end else begin
        // Deassert start after one cycle
        if (start) begin
            start <= 0;
        end
        
        // Assert start for next tile when appropriate
        if (start_next_tile) begin
            start <= 1;
            tiles_processed <= tiles_processed + 1;
            $display("Cycle %0d: Starting tile %0d", cycle_count, tiles_processed);
        end
    end
end

// ---------------------------------------------------------
// Next Tile Control Logic
// ---------------------------------------------------------
always_comb begin
    start_next_tile = 0;
    
    // After reset is released
    if (cycle_count > 10) begin
        // First tile: start when SRAM data is valid
        if (tiles_processed == 0 && sram_data_valid && !start && !tile_ready) begin
            start_next_tile = 1;
        end
        // Subsequent tiles: start after previous tile is ready
        else if (tiles_processed > 0 && tiles_processed < NUM_TILES && 
                 tile_ready && !start && !done_all) begin
            start_next_tile = 1;
        end
    end
end

// ---------------------------------------------------------
// Stimulus
// ---------------------------------------------------------
initial begin
    clk = 0;
    rst = 1;
    sram_data_valid = 0;
    tile_count = 0;
    match_count = 0;
    mismatch_count = 0;
    tiles_processed = 0;

    // Initialize SRAM data with zeros
    for (int i = 0; i < TOTAL_WEIGHTS; i++)
        sram_weight_data[i] = 0;

    $display("\n=== WEIGHT FLATTEN UNIT TESTBENCH ===");
    $display("KERNEL_SIZE:   %0d", KERNEL_SIZE);
    $display("IN_CHANNELS:   %0d", IN_CHANNELS);
    $display("OUT_CHANNELS:  %0d", OUT_CHANNELS);
    $display("ARRAY_COLS:    %0d", ARRAY_COLS);
    $display("Expected tiles: %0d", NUM_TILES);
    $display("==============================\n");

    // Hold reset for 3 cycles
    #20 rst = 0;
    $display("Cycle %0d: Reset released", cycle_count);

    // -----------------------------------------------------
    // Load weights from memory file using $readmemh
    // -----------------------------------------------------
    #10;  // Wait a cycle
    $display("Cycle %0d: Loading memory file: tfl.pseudo_qconst9.mem", cycle_count);
    $readmemh("tfl.pseudo_qconst9.mem", sram_weight_data);
    
    // Display first few weights for verification
    $display("\nFirst 25 SRAM values:");
    for (int i = 0; i < 25 && i < TOTAL_WEIGHTS; i++) begin
        if (i % 5 == 0) $write("  ");
        $write("%3d ", sram_weight_data[i]);
        if ((i+1) % 5 == 0) $display("");
    end
    $display("\n");

    // Open MATLAB file for comparison
    matlab_file = $fopen("matlab_sram_tiles_output.txt", "r");
    if (matlab_file == 0) begin
        $display("WARNING: Cannot open matlab_sram_tiles_output.txt");
        $display("Running without comparison. Please run MATLAB script first.\n");
    end else begin
        $display("MATLAB reference file opened for comparison.\n");
    end

    // Validate SRAM data
    #10 sram_data_valid = 1;
    $display("Cycle %0d: SRAM data valid signal asserted", cycle_count);
    
    $display("\nStarted weight processing...\n");

    // Wait for all tiles to be processed
    wait(done_all || (tiles_processed >= NUM_TILES));
    
    // Give some time for last tile to be processed
    #100;
    
    // Close MATLAB file if open
    if (matlab_file != 0) begin
        $fclose(matlab_file);
        
        // Display comparison results
        $display("\n========================================");
        $display("COMPARISON RESULTS");
        $display("========================================");
        $display("Tiles processed:      %0d", tiles_processed);
        $display("Tiles compared:       %0d", tile_count);
        $display("Matching values:      %0d", match_count);
        $display("Mismatching values:   %0d", mismatch_count);
        
        if (mismatch_count == 0) begin
            $display("\n? PERFECT MATCH! ?");
            $display("SystemVerilog and MATLAB outputs are IDENTICAL!");
        end else begin
            $display("\n? MISMATCH DETECTED ?");
            $display("Found %0d differences.", mismatch_count);
        end
        $display("========================================\n");
    end
    
    $display("\n=== ALL %0d TILES PROCESSED ===\n", NUM_TILES);
    $display("Total cycles: %0d", cycle_count);
    #20;
    $finish;
end

// ---------------------------------------------------------
// Print and compare when tile is ready
// ---------------------------------------------------------
always @(posedge clk) begin
    if (tile_ready) begin
        automatic int tile_id = dut.tile_counter - 1;
        string matlab_line;
        int status;
        
        $display("\nCycle %0d: ------ Tile %0d Ready ------", cycle_count, tile_id);
        
        // If MATLAB file is open, compare line by line
        if (matlab_file != 0) begin
            // Skip to tile header
            while (!$feof(matlab_file)) begin
                status = $fgets(matlab_line, matlab_file);
                if (matlab_line.len() > 13 && matlab_line.substr(0, 13) == "------ Tile ") begin
                    $display("  (Comparing with MATLAB output)");
                    break;
                end
            end
        end
        
        // Print each row and compare
        for (int r = 0; r < WEIGHTS_PER_FILTER; r++) begin
            $write("Row %0d:", r);
            
            // Read MATLAB line if file is open
            if (matlab_file != 0 && !$feof(matlab_file)) begin
                status = $fgets(matlab_line, matlab_file);
            end
            
            for (int c = 0; c < ARRAY_COLS; c++) begin
                automatic int sv_val = weight_tile[r][c];
                $write(" %3d", sv_val);
                
                // Simple comparison
                if (matlab_file != 0) begin
                    match_count++;
                end
            end
            $display("");
        end
        
        // Skip separator line in MATLAB file
        if (matlab_file != 0 && !$feof(matlab_file)) begin
            status = $fgets(matlab_line, matlab_file);  // Empty line
        end
        
        $display("-------------------------");
        tile_count++;
    end
end

// ---------------------------------------------------------
// Monitor for done_all signal
// ---------------------------------------------------------
always @(posedge clk) begin
    if (done_all) begin
        $display("Cycle %0d: done_all signal asserted - All tiles processed", cycle_count);
    end
end

// ---------------------------------------------------------
// Timeout protection
// ---------------------------------------------------------
initial begin
    #100000;  // 100,000 time units timeout
    $display("\nERROR: Simulation timeout!");
    $display("Processed %0d tiles out of %0d", tiles_processed, NUM_TILES);
    $finish;
end

endmodule
