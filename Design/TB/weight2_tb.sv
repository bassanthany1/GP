module weight2_tb;
    // ====== Parameters ======
    localparam KERNEL_SIZE   = 5;
    localparam IN_CHANNELS   = 1;
    localparam OUT_CHANNELS  = 6;
    localparam DATA_WIDTH    = 8;
    
    localparam FILTER_SIZE = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;
    localparam TOTAL_COLS = OUT_CHANNELS;
    
    // ====== Signals ======
    logic clk, rst, start;
    logic col_ready, done;
    logic [DATA_WIDTH-1:0] weight_4d [OUT_CHANNELS][IN_CHANNELS][KERNEL_SIZE][KERNEL_SIZE];
    logic [DATA_WIDTH-1:0] weight_col [FILTER_SIZE];
    
    // ====== DUT Instance ======
    weight_unit2 #(
        .KERNEL_SIZE(KERNEL_SIZE),
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .col_ready(col_ready),
        .done(done),
        .weight_4d(weight_4d),
        .weight_col(weight_col)
    );
    
    // ====== Clock ======
    always #5 clk = ~clk;
    
    // ====== Column Monitor ======
    int col_count = 0;
    always @(posedge clk) begin
        if (col_ready) begin
            $display("------ Filter %0d (Column %0d / %0d) ------", col_count, col_count, TOTAL_COLS);
            $write("  Weights: ");
            for (int i = 0; i < FILTER_SIZE; i++)
                $write("%3d ", weight_col[i]);
            $display("\n");
            col_count++;
        end
    end
    
    // ====== Stimulus ======
    initial begin
        clk = 0;
        rst = 1;
        start = 0;
        
        #20 rst = 0;
        
        // Fill weights with pattern to track each filter easily
        // Pattern: oc*20 + ky*3 + kx (stays within 8-bit range)
        $display("====== Initializing Weights ======");
        for (int oc = 0; oc < OUT_CHANNELS; oc++) begin
            for (int ic = 0; ic < IN_CHANNELS; ic++) begin
                for (int ky = 0; ky < KERNEL_SIZE; ky++) begin
                    for (int kx = 0; kx < KERNEL_SIZE; kx++) begin
                        weight_4d[oc][ic][ky][kx] = oc*10 + ky*3 + kx;
                    end
                end
            end
        end
        
        // Display one filter as example
        $display("\nExample: Filter 0 (flattened):");
        $write("  ");
        for (int ic = 0; ic < IN_CHANNELS; ic++) begin
            for (int ky = 0; ky < KERNEL_SIZE; ky++) begin
                for (int kx = 0; kx < KERNEL_SIZE; kx++) begin
                    $write("%3d ", weight_4d[0][ic][ky][kx]);
                end
            end
        end
        $display("");
        
        $display("\nStarting weight flattening...");
        $display("Expected columns (filters): %0d", TOTAL_COLS);
        $display("Each column size: %0d\n", FILTER_SIZE);
        
        #10 start = 1;
        #10 start = 0;
        
        // Wait for done signal instead of counting columns
        wait(done);
        $display("? All columns processed!");
        
        #20 $finish;
    end
    
    // ====== Timeout Watchdog ======
    initial begin
        #10000;
        $display("? ERROR: Timeout!");
        $finish;
    end
    

    
endmodule
