// =============================================================================
// TESTBENCH — cnn_top_tb.sv  (single inference, 7 layers)
// =============================================================================
//
// Drives cnn_top which instantiates:
//   cnn_controller  (7-layer LeNet-5, ports: start_inference / inference_done
//                    / current_layer — no busy port)
//   lenet5_npu_sram_no_offset
//
// Test plan:
//   Phase 0  RESET
//   Phase 1  WEIGHT PRELOAD  — 44190 weights (value = 1)
//   Phase 2  BIAS   PRELOAD  — 236  biases   (value = 0)
//   Phase 3  IMAGE  LOAD     — 28x28 pixels  (value = 1)
//   Phase 4  SINGLE INFERENCE RUN
//              * inference_done fires (single-cycle pulse)
//              * all 7 layers fire start_layer in order 0->6
//
// Timeout: 20 000 000 cycles @ 100 MHz.
// =============================================================================
// =============================================================================
// TESTBENCH ? cnn_top_tb.sv  (single inference, loads real weights/image)
// =============================================================================
// Memory file format:
//   all_weights.mem  ? 44190 hex values, one per line, signed 8-bit
//   all_bias.mem     ? 236  hex values, one per line, signed 32-bit
//   image_hex.mem    ? 784  hex values, one per line, signed 8-bit
//
// Example all_weights.mem line: FF  (= -1 in signed INT8)
// Example all_bias.mem   line: 0000001A  (= 26 in signed INT32)
// Example image_hex.mem  line: 7F  (= 127 in signed INT8)
// =============================================================================

`timescale 1ns / 1ps

module tb_cnn_top;

    // -------------------------------------------------------------------------
    // Parameters ? must match cnn_top
    // -------------------------------------------------------------------------
    localparam MAX_KERNEL_SIZE     = 5;
    localparam MAX_IN_CHANNELS     = 256;
    localparam MAX_OUT_CHANNELS    = 120;
    localparam MAX_INPUT_HEIGHT    = 28;
    localparam MAX_INPUT_WIDTH     = 28;
    localparam TILE_ROWS           = 8;
    localparam ARRAY_COLS          = 8;
    localparam DATA_WIDTH          = 8;
    localparam NUM_IMG_PORTS       = 5;
    localparam MAX_BURST_LEN       = 512;
    localparam MAX_WEIGHTS         = 30720;
    localparam TOTAL_WEIGHTS       = 44190;
    localparam MAX_BIASES          = 120;
    localparam TOTAL_BIASES        = 236;
    localparam SRAM_TOTAL_ELEMENTS = 1024;
    localparam NUM_LAYERS          = 5;

    localparam CLK_PERIOD = 10;

    localparam W_WADDR = $clog2(TOTAL_WEIGHTS);
    localparam W_BADDR = $clog2(TOTAL_BIASES);
    localparam W_IADDR = $clog2(SRAM_TOTAL_ELEMENTS);

    // -------------------------------------------------------------------------
    // Memory arrays ? loaded from files
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] weight_mem [0:TOTAL_WEIGHTS-1];
    logic signed [31:0]           bias_mem   [0:TOTAL_BIASES-1];
    logic signed [DATA_WIDTH-1:0] image_mem  [0:MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH-1];

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic clk, rst;
    logic start;
    logic inference_done;
    logic [2:0] current_layer;

    logic [W_WADDR-1:0]           weight_write_addr;
    logic signed [DATA_WIDTH-1:0] weight_write_data;
    logic                         weight_write_enable;

    logic [W_BADDR-1:0]  bias_write_addr;
    logic signed [31:0]  bias_write_data;
    logic                bias_write_enable;

    logic                         ext_wr_en;
    logic [W_IADDR-1:0]           ext_wr_addr;
    logic signed [DATA_WIDTH-1:0] ext_wr_data;

    logic sram_bank_conflict;
logic layer_done_prev;
    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    cnn_top #(
        .MAX_KERNEL_SIZE     (MAX_KERNEL_SIZE),
        .MAX_IN_CHANNELS     (MAX_IN_CHANNELS),
        .MAX_OUT_CHANNELS    (MAX_OUT_CHANNELS),
        .MAX_INPUT_HEIGHT    (MAX_INPUT_HEIGHT),
        .MAX_INPUT_WIDTH     (MAX_INPUT_WIDTH),
        .TILE_ROWS           (TILE_ROWS),
        .ARRAY_COLS          (ARRAY_COLS),
        .DATA_WIDTH          (DATA_WIDTH),
        .NUM_IMG_PORTS       (NUM_IMG_PORTS),
        .MAX_BURST_LEN       (MAX_BURST_LEN),
        .MAX_WEIGHTS         (MAX_WEIGHTS),
        .TOTAL_WEIGHTS       (TOTAL_WEIGHTS),
        .MAX_BIASES          (MAX_BIASES),
        .TOTAL_BIASES        (TOTAL_BIASES),
        .SRAM_TOTAL_ELEMENTS (SRAM_TOTAL_ELEMENTS),
        .NUM_LAYERS          (NUM_LAYERS)
    ) dut (
        .clk                  (clk),
        .rst                  (rst),
        .start                (start),
        .inference_done       (inference_done),
        .current_layer        (current_layer),
        .weight_write_addr    (weight_write_addr),
        .weight_write_data    (weight_write_data),
        .weight_write_enable  (weight_write_enable),
        .bias_write_addr      (bias_write_addr),
        .bias_write_data      (bias_write_data),
        .bias_write_enable    (bias_write_enable),
        .ext_wr_en            (ext_wr_en),
        .ext_wr_addr          (ext_wr_addr),
        .ext_wr_data          (ext_wr_data),
        .sram_bank_conflict   (sram_bank_conflict)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Watchdog
    // -------------------------------------------------------------------------
    initial begin
        #(CLK_PERIOD * 20_000_000);
        $display("[WATCHDOG] Timeout ? SIMULATION KILLED");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Scoreboard
    // -------------------------------------------------------------------------
    int layers_seen [NUM_LAYERS];
    int layer_order [$];

    always @(posedge clk) begin
        if (dut.u_ctrl.start_layer) begin
            automatic int l = int'(current_layer);
            layers_seen[l]++;
            layer_order.push_back(l);
            $display("[SCOREBOARD] t=%0t  start_layer -> layer %0d", $time, l);
        end
    end

    // -------------------------------------------------------------------------
    // Conflict counter + per-layer
    // -------------------------------------------------------------------------
    int conflict_count;
    int conflicts_per_layer [NUM_LAYERS];

    always @(posedge clk) begin
        if (sram_bank_conflict) begin
            conflict_count++;
            conflicts_per_layer[current_layer]++;
        end
    end
always @(posedge clk) begin
    layer_done_prev <= dut.u_npu.layer_done;  // 1-cycle delayed copy
end

// Only print on RISING EDGE (0?1 transition), not while high
always @(posedge clk) begin
    if (dut.u_npu.layer_done && !layer_done_prev) begin  // ? rising edge only
        automatic int layer = int'(current_layer);
        $display("\n=== Layer %0d output (first 8 values) ===", layer);
        for (int i = 0; i < 8; i++)
            $display("  sram[%0d] = %0d", i, $signed(read_sram(i)));
    end
end
    // -------------------------------------------------------------------------
    // SRAM read helper
    // -------------------------------------------------------------------------
    function automatic logic signed [7:0] read_sram(input integer flat_addr);
        automatic integer bank  = flat_addr % 5;
        automatic integer baddr = flat_addr / 5;
        case (bank)
            0: return dut.u_npu.sram.bank0[baddr];
            1: return dut.u_npu.sram.bank1[baddr];
            2: return dut.u_npu.sram.bank2[baddr];
            3: return dut.u_npu.sram.bank3[baddr];
            4: return dut.u_npu.sram.bank4[baddr];
            default: return 8'hxx;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    int pass_cnt, fail_cnt;

    task automatic tick(input int n = 1);
        repeat(n) @(posedge clk); #1;
    endtask

    task automatic do_reset();
        rst                 = 1'b1;
        start               = 1'b0;
        weight_write_enable = 1'b0;
        bias_write_enable   = 1'b0;
        ext_wr_en           = 1'b0;
        weight_write_addr   = '0;
        weight_write_data   = '0;
        bias_write_addr     = '0;
        bias_write_data     = '0;
        ext_wr_addr         = '0;
        ext_wr_data         = '0;
        tick(8);
        rst = 1'b0;
        tick(3);
        $display("[RST] Reset released at t=%0t", $time);
    endtask

    task automatic write_weight(
        input [W_WADDR-1:0]           addr,
        input signed [DATA_WIDTH-1:0] data
    );
        @(negedge clk);
        weight_write_addr   = addr;
        weight_write_data   = data;
        weight_write_enable = 1'b1;
        @(negedge clk);
        weight_write_enable = 1'b0;
    endtask

    task automatic write_bias(
        input [W_BADDR-1:0] addr,
        input signed [31:0] data
    );
        @(negedge clk);
        bias_write_addr   = addr;
        bias_write_data   = data;
        bias_write_enable = 1'b1;
        @(negedge clk);
        bias_write_enable = 1'b0;
    endtask

    task automatic write_pixel(
        input [W_IADDR-1:0]           addr,
        input signed [DATA_WIDTH-1:0] data
    );
        @(negedge clk);
        ext_wr_addr = addr;
        ext_wr_data = data;
        ext_wr_en   = 1'b1;
        @(negedge clk);
        ext_wr_en   = 1'b0;
    endtask
// Fires on ANY change to layer_offset ? catches glitches
always @(dut.u_npu.npu.layer_processor_inst.weight_memory.layer_offset) begin
    $display("[OFFSET t=%0t] layer_offset changed to %0d  (layer=%0d)",
             $time,
             dut.u_npu.npu.layer_processor_inst.weight_memory.layer_offset,
             current_layer);
end
    task automatic chk(input string name, input logic got, input logic exp);
        if (got === exp) begin
            $display("  PASS  %s", name);
            pass_cnt++;
        end else begin
            $display("  FAIL  %s  (got=%0b  exp=%0b)", name, got, exp);
            fail_cnt++;
        end
    endtask

    task automatic chk_int(input string name, input int got, input int exp);
        if (got === exp) begin
            $display("  PASS  %s  (=%0d)", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL  %s  (got=%0d  exp=%0d)", name, got, exp);
            fail_cnt++;
        end
    endtask

    // =========================================================================
    // Main sequence
    // =========================================================================
    time t0, t1;
    int  predicted_class;
    logic signed [7:0] max_val;

    initial begin
        pass_cnt       = 0;
        fail_cnt       = 0;
        conflict_count = 0;
        for (int l = 0; l < NUM_LAYERS; l++) begin
            layers_seen[l]         = 0;
            conflicts_per_layer[l] = 0;
        end

       

        // =====================================================================
        // LOAD MEMORY FILES
        // =====================================================================
        $display("\n=== Loading memory files ===");
        $readmemh("all_weights.mem", weight_mem);
        $display("  Weights loaded : all_weights.mem (%0d entries)", TOTAL_WEIGHTS);
        $readmemh("all_biases.mem", bias_mem);
        $display("  Biases  loaded : all_bias.mem    (%0d entries)", TOTAL_BIASES);
        $readmemh("image_hex.mem", image_mem);
        $display("  Image   loaded : image_hex.mem   (%0d entries)",
                 MAX_INPUT_HEIGHT * MAX_INPUT_WIDTH);

        // =====================================================================
        // PHASE 0 ? Reset
        // =====================================================================
        $display("\n=== PHASE 0: Reset ===");
        do_reset();
        chk    ("inference_done=0 after reset", inference_done, 1'b0);
        chk_int("current_layer=0 after reset",  int'(current_layer), 0);

        // =====================================================================
        // PHASE 1 ? Weight preload from file
        // =====================================================================
        $display("\n=== PHASE 1: Weight preload from all_weights.mem ===");
        t0 = $time;
        for (int i = 0; i < TOTAL_WEIGHTS; i++)
            write_weight(W_WADDR'(i), weight_mem[i]);
        $display("  Done in %0d ns (%0d cycles)",
                 $time - t0, ($time - t0) / CLK_PERIOD);

        // =====================================================================
        // PHASE 2 ? Bias preload from file
        // =====================================================================
        $display("\n=== PHASE 2: Bias preload from all_bias.mem ===");
        t0 = $time;
        for (int i = 0; i < TOTAL_BIASES; i++)
            write_bias(W_BADDR'(i), bias_mem[i]);
        $display("  Done in %0d ns (%0d cycles)",
                 $time - t0, ($time - t0) / CLK_PERIOD);

        // =====================================================================
        // PHASE 3 ? Image load from file
        // =====================================================================
        $display("\n=== PHASE 3: Image load from image_hex.mem (28x28) ===");
        t0 = $time;
        for (int i = 0; i < MAX_INPUT_HEIGHT * MAX_INPUT_WIDTH; i++)
            write_pixel(W_IADDR'(i), image_mem[i]);
        $display("  Done in %0d ns (%0d cycles)",
                 $time - t0, ($time - t0) / CLK_PERIOD);

        tick(5);

        // =====================================================================
        // PHASE 4 ? Inference
        // =====================================================================
        $display("\n=== PHASE 4: Inference ===");

        @(posedge clk); #1;
        start = 1'b1;
        @(posedge clk); #1;
        start = 1'b0;

        t0 = $time;
        @(posedge inference_done); #1;
        t1 = $time;
        $display("  inference_done at t=%0t  (%0d cycles)",
                 t1, (t1 - t0) / CLK_PERIOD);

        chk("inference_done=1", inference_done, 1'b1);
        @(posedge clk); #1;
        chk("inference_done deasserts next cycle", inference_done, 1'b0);

        $write("  Layer order observed:");
        foreach (layer_order[k]) $write(" %0d", layer_order[k]);
        $display("");

        chk_int("correct layers fired", layer_order.size(), NUM_LAYERS);
        for (int l = 0; l < NUM_LAYERS; l++)
            chk_int($sformatf("layer %0d fired once", l), layers_seen[l], 1);

        tick(10);

        // =====================================================================
        // PHASE 5 ? Read final output (10 neurons, digits 0-9)
        // =====================================================================
        $display("\n=== Final Output ? 10 class logits (pre-softmax) ===");
        $display("  %-8s  %-8s", "Digit", "Score");
        $display("  %s", {20{"-"}});

        predicted_class = 0;
        max_val         = read_sram(0);

        for (int i = 0; i < 10; i++) begin
            automatic logic signed [7:0] val = read_sram(i);
            $display("  %-8d  %-8d", i, $signed(val));
            if ($signed(val) > $signed(max_val)) begin
                max_val         = val;
                predicted_class = i;
            end
        end

        $display("\n  >>> Predicted digit = %0d  (score = %0d) <<<",
                 predicted_class, $signed(max_val));

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n==============================================");
        $display("  SRAM bank conflicts : %0d", conflict_count);
        for (int i = 0; i < NUM_LAYERS; i++)
            $display("    Layer %0d : %0d conflicts", i, conflicts_per_layer[i]);
        $display("  PASS : %0d  |  FAIL : %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail_cnt);
        $display("==============================================\n");

        $finish;
    end

endmodule
`timescale 1ns / 1ps

/*module tb_cnn_top;

    // -------------------------------------------------------------------------
    // Parameters — must match cnn_top
    // -------------------------------------------------------------------------
    localparam MAX_KERNEL_SIZE     = 5;
    localparam MAX_IN_CHANNELS     = 256;
    localparam MAX_OUT_CHANNELS    = 120;
    localparam MAX_INPUT_HEIGHT    = 28;
    localparam MAX_INPUT_WIDTH     = 28;
    localparam TILE_ROWS           = 8;
    localparam ARRAY_COLS          = 8;
    localparam DATA_WIDTH          = 8;
    localparam NUM_IMG_PORTS       = 5;
    localparam MAX_BURST_LEN       = 256;
    localparam MAX_WEIGHTS         = 30720;
    localparam TOTAL_WEIGHTS       = 44190;
    localparam MAX_BIASES          = 120;
    localparam TOTAL_BIASES        = 236;
    localparam SRAM_TOTAL_ELEMENTS = 1024;
    localparam NUM_LAYERS          = 5;

    localparam CLK_PERIOD = 10; // 10 ns -> 100 MHz

    localparam W_WADDR = $clog2(TOTAL_WEIGHTS);
    localparam W_BADDR = $clog2(TOTAL_BIASES);
    localparam W_IADDR = $clog2(SRAM_TOTAL_ELEMENTS);

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic clk, rst;

    // control — note: cnn_controller has no busy port
    logic start;
    logic inference_done;
    logic [2:0] current_layer;

    // weight init
    logic [W_WADDR-1:0]           weight_write_addr;
    logic signed [DATA_WIDTH-1:0] weight_write_data;
    logic                         weight_write_enable;

    // bias init
    logic [W_BADDR-1:0]  bias_write_addr;
    logic signed [31:0]  bias_write_data;
    logic                bias_write_enable;

    // image load
    logic                         ext_wr_en;
    logic [W_IADDR-1:0]           ext_wr_addr;
    logic signed [DATA_WIDTH-1:0] ext_wr_data;

    // status
    logic sram_bank_conflict;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    cnn_top #(
        .MAX_KERNEL_SIZE     (MAX_KERNEL_SIZE),
        .MAX_IN_CHANNELS     (MAX_IN_CHANNELS),
        .MAX_OUT_CHANNELS    (MAX_OUT_CHANNELS),
        .MAX_INPUT_HEIGHT    (MAX_INPUT_HEIGHT),
        .MAX_INPUT_WIDTH     (MAX_INPUT_WIDTH),
        .TILE_ROWS           (TILE_ROWS),
        .ARRAY_COLS          (ARRAY_COLS),
        .DATA_WIDTH          (DATA_WIDTH),
        .NUM_IMG_PORTS       (NUM_IMG_PORTS),
        .MAX_BURST_LEN       (MAX_BURST_LEN),
        .MAX_WEIGHTS         (MAX_WEIGHTS),
        .TOTAL_WEIGHTS       (TOTAL_WEIGHTS),
        .MAX_BIASES          (MAX_BIASES),
        .TOTAL_BIASES        (TOTAL_BIASES),
        .SRAM_TOTAL_ELEMENTS (SRAM_TOTAL_ELEMENTS),
        .NUM_LAYERS          (NUM_LAYERS)
    ) dut (
        .clk                  (clk),
        .rst                  (rst),
        .start                (start),
        .inference_done       (inference_done),
        .current_layer        (current_layer),
        .weight_write_addr    (weight_write_addr),
        .weight_write_data    (weight_write_data),
        .weight_write_enable  (weight_write_enable),
        .bias_write_addr      (bias_write_addr),
        .bias_write_data      (bias_write_data),
        .bias_write_enable    (bias_write_enable),
        .ext_wr_en            (ext_wr_en),
        .ext_wr_addr          (ext_wr_addr),
        .ext_wr_data          (ext_wr_data),
        .sram_bank_conflict   (sram_bank_conflict)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always  #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Watchdog
    // -------------------------------------------------------------------------
    initial begin
        #(CLK_PERIOD * 200_000_000);
        $display("[WATCHDOG] Timeout — SIMULATION KILLED");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Scoreboard — track every start_layer pulse
    // -------------------------------------------------------------------------
    int layers_seen [NUM_LAYERS];
    int layer_order [$];

    always @(posedge clk) begin
        if (dut.u_ctrl.start_layer) begin
            automatic int l = int'(current_layer);
            layers_seen[l]++;
            layer_order.push_back(l);
            $display("[SCOREBOARD] t=%0t  start_layer -> layer %0d", $time, l);
        end
    end

    // -------------------------------------------------------------------------
    // Bank-conflict counter (informational)
    // -------------------------------------------------------------------------
    int conflict_count;
    always @(posedge clk)
        if (sram_bank_conflict) conflict_count++;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    int pass_cnt, fail_cnt;

    task automatic tick(input int n = 1);
        repeat(n) @(posedge clk); #1;
    endtask

    task automatic do_reset();
        rst                 = 1'b1;
        start               = 1'b0;
        weight_write_enable = 1'b0;
        bias_write_enable   = 1'b0;
        ext_wr_en           = 1'b0;
        weight_write_addr   = '0;
        weight_write_data   = '0;
        bias_write_addr     = '0;
        bias_write_data     = '0;
        ext_wr_addr         = '0;
        ext_wr_data         = '0;
        tick(8);
        rst = 1'b0;
        tick(3);
        $display("[RST] Reset released at t=%0t", $time);
    endtask
// ?? DEBUG: watch key signals around FC layer transitions ??

    task automatic write_weight(
        input [W_WADDR-1:0]           addr,
        input signed [DATA_WIDTH-1:0] data
    );
        @(negedge clk);
        weight_write_addr   = addr;
        weight_write_data   = data;
        weight_write_enable = 1'b1;
        @(negedge clk);
        weight_write_enable = 1'b0;
    endtask

    task automatic write_bias(
        input [W_BADDR-1:0] addr,
        input signed [31:0] data
    );
        @(negedge clk);
        bias_write_addr   = addr;
        bias_write_data   = data;
        bias_write_enable = 1'b1;
        @(negedge clk);
        bias_write_enable = 1'b0;
    endtask

    task automatic write_pixel(
        input [W_IADDR-1:0]           addr,
        input signed [DATA_WIDTH-1:0] data
    );
        @(negedge clk);
        ext_wr_addr = addr;
        ext_wr_data = data;
        ext_wr_en   = 1'b1;
        @(negedge clk);
        ext_wr_en   = 1'b0;
    endtask

    task automatic chk(input string name, input logic got, input logic exp);
        if (got === exp) begin
            $display("  PASS  %s", name);
            pass_cnt++;
        end else begin
            $display("  FAIL  %s  (got=%0b  exp=%0b)", name, got, exp);
            fail_cnt++;
        end
    endtask

    task automatic chk_int(input string name, input int got, input int exp);
        if (got === exp) begin
            $display("  PASS  %s  (=%0d)", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL  %s  (got=%0d  exp=%0d)", name, got, exp);
            fail_cnt++;
        end
    endtask

    // =========================================================================
    // Main sequence
    // =========================================================================
    time t0, t1;

    initial begin
        pass_cnt       = 0;
        fail_cnt       = 0;
        conflict_count = 0;
        for (int l = 0; l < NUM_LAYERS; l++) layers_seen[l] = 0;

       

        // =====================================================================
        // PHASE 0 — Reset
        // =====================================================================
        $display("\n=== PHASE 0: Reset ===");
        do_reset();
        chk    ("inference_done=0 after reset", inference_done, 1'b0);
        chk_int("current_layer=0 after reset",  int'(current_layer), 0);

        // =====================================================================
        // PHASE 1 — Weight preload  (44190 weights, all = 1)
        // Layout matches cnn_controller layer ROM:
        //   L0 C1  [      0..    149]  150 w
        //   L1 S2  [    150..    155]    6 w  (dummy)
        //   L2 C3  [    156..   2555] 2400 w
        //   L3 S4  [   2556..   2571]   16 w  (dummy)
        //   L4 C5  [   2572..  33291] 30720 w
        //   L5 F6  [  33292..  43371] 10080 w
        //   L6 Out [  43372..  44211]   840 w
        // =====================================================================
        $display("\n=== PHASE 1: Weight preload (%0d words) ===", TOTAL_WEIGHTS);
        t0 = $time;
        for (int i = 0; i < TOTAL_WEIGHTS; i++)
            write_weight(W_WADDR'(i), 8'sh01);
        $display("  Done in %0d ns (%0d cycles)",
                 $time - t0, ($time - t0) / CLK_PERIOD);

        // =====================================================================
        // PHASE 2 — Bias preload  (236 biases, all = 0)
        // Layout matches cnn_controller layer ROM:
        //   L0 C1  [  0..  5]   6 b  (offset   0)
        //   L1 S2  [  6.. 11]   6 b  (offset   6)
        //   L2 C3  [ 12.. 27]  16 b  (offset  12)
        //   L3 S4  [ 28.. 43]  16 b  (offset  28)
        //   L4 C5  [ 44..163] 120 b  (offset  44)
        //   L5 F6  [164..247]  84 b  (offset 164)
        //   L6 Out [226..235]  10 b  (offset 226)
        // =====================================================================
        $display("\n=== PHASE 2: Bias preload (%0d words) ===", TOTAL_BIASES);
        t0 = $time;
        for (int i = 0; i < TOTAL_BIASES; i++)
            write_bias(W_BADDR'(i), 32'sd0);
        $display("  Done in %0d ns (%0d cycles)",
                 $time - t0, ($time - t0) / CLK_PERIOD);

        // =====================================================================
        // PHASE 3 — Image load  (28x28 = 784 pixels, all = 1) -> SRAM[0..783]
        // =====================================================================
        $display("\n=== PHASE 3: Image load (28x28 -> SRAM[0..783]) ===");
        t0 = $time;
        for (int i = 0; i < (MAX_INPUT_HEIGHT * MAX_INPUT_WIDTH); i++)
            write_pixel(W_IADDR'(i), 8'sh01);
        $display("  Done in %0d ns (%0d cycles)",
                 $time - t0, ($time - t0) / CLK_PERIOD);

        tick(5);

        // =====================================================================
        // PHASE 4 — Single inference
        // =====================================================================
        $display("\n=== PHASE 4: Inference ===");

        // Pulse start for one cycle
        @(posedge clk); #1;
        start = 1'b1;
        @(posedge clk); #1;
        start = 1'b0;

        // Wait for inference_done
        t0 = $time;
        @(posedge inference_done); #1;
        t1 = $time;
        $display("  inference_done at t=%0t  (%0d cycles)",
                 t1, (t1 - t0) / CLK_PERIOD);

        chk("inference_done=1", inference_done, 1'b1);

        // inference_done must be a single-cycle pulse
        @(posedge clk); #1;
        chk("inference_done deasserts next cycle", inference_done, 1'b0);

        // Check layer ordering
        $write("  Layer order observed:");
        foreach (layer_order[k]) $write(" %0d", layer_order[k]);
        $display("");

        chk_int("7 start_layer pulses fired", layer_order.size(), NUM_LAYERS);
        for (int l = 0; l < NUM_LAYERS; l++)
            chk_int($sformatf("layer %0d fired once", l), layers_seen[l], 1);
        if (layer_order.size() == NUM_LAYERS) begin
            for (int l = 0; l < NUM_LAYERS; l++)
                chk_int($sformatf("layer order[%0d]=%0d", l, l),
                        layer_order[l], l);
        end

        // =====================================================================
        // Summary
        // =====================================================================
        tick(10);
        $display("\n==============================================");
        $display("  SRAM bank conflicts : %0d", conflict_count);
        $display("  PASS : %0d  |  FAIL : %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail_cnt);
        $display("==============================================\n");

        $finish;
    end

endmodule*/
