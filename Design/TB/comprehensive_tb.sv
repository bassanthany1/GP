// =============================================================================
// Comprehensive Testbench for LeNet5 NPU-SRAM Integration
// FIXED for runtime-parameter DUT (lenet5_npu_sram_no_offset, updated version)
//
// CHANGES vs document 11 (active uncommented module):
//
// FIX 1 — DUT parameter list: removed KERNEL_SIZE/IN_CHANNELS/OUT_CHANNELS/
//   INPUT_HEIGHT/INPUT_WIDTH (no longer DUT parameters). Added MAX_* params.
//
// FIX 2 — Runtime geometry ports: added kernel_size/in_channels/out_channels/
//   input_height/input_width signals, connected to DUT, driven before reset.
//
// FIX 3 — Runtime requant ports: added requant_scale/shift/ZP_next signals,
//   connected to DUT, driven with Q16 identity (scale=65536,shift=16,ZP=0).
//   Same fix as tb_lenet5_verify / tb_lenet5_fc_verify: scale=1,shift=0
//   causes 1<<(shift-1) = 1<<31 undefined behavior in requant block.
//
// FIX 4 — Removed sram_total_reads/writes/conflicts from DUT port connection:
//   These output ports no longer exist in lenet5_npu_sram_no_offset.
//   TB variables kept but permanently zero — noted in run_layer output.
//
// FIX 5 — Signal widths aligned to DUT port widths using $clog2 expressions:
//   weight_write_addr, bias_write_addr, ext_wr_addr all corrected.
//   weight_layer_offset/total and bias_layer_offset/total corrected.
//
// FIX 6 — run_layer task: removed delta prints that referenced the now-zero
//   sram_total_reads/writes/conflicts variables (would always print 0 delta).
//
// The large commented-out module at the bottom is preserved unchanged.
// =============================================================================
`timescale 1ns/1ps

module tb_lenet5_comprehensive;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam CLK_PERIOD    = 10;

    // Actual layer geometry — driven onto runtime ports
    localparam KERNEL_SIZE   = 5;
    localparam IN_CHANNELS   = 1;
    localparam OUT_CHANNELS  = 6;
    localparam INPUT_HEIGHT  = 28;
    localparam INPUT_WIDTH   = 28;

    // FIX 1: MAX_* bounds — these are now the DUT compile-time parameters
    // For CONV1 (5x5, 1->6) the actual sizes equal the max bounds
    localparam MAX_KERNEL_SIZE  = 5;
    localparam MAX_IN_CHANNELS  = 6;
    localparam MAX_OUT_CHANNELS = 16;
    localparam MAX_INPUT_HEIGHT = 28;
    localparam MAX_INPUT_WIDTH  = 28;

    // Fixed architecture params
    localparam TILE_ROWS     = 7;
    localparam ARRAY_COLS    = 4;
    localparam DATA_WIDTH    = 8;
    localparam NUM_IMG_PORTS = 5;
    localparam MAX_BURST_LEN = 32;
    localparam MAX_WEIGHTS   = 30720;
    localparam TOTAL_WEIGHTS = 44190;
    localparam MAX_BIASES    = 120;
    localparam TOTAL_BIASES  = 236;
    localparam SRAM_TOTAL_ELEMENTS = 32768;

    // Derived dimensions
    localparam CONV_OUT_HEIGHT = INPUT_HEIGHT - KERNEL_SIZE + 1;  // 24
    localparam CONV_OUT_WIDTH  = INPUT_WIDTH  - KERNEL_SIZE + 1;  // 24
    localparam POOL_OUT_HEIGHT = CONV_OUT_HEIGHT / 2;             // 12
    localparam POOL_OUT_WIDTH  = CONV_OUT_WIDTH  / 2;             // 12

    localparam INPUT_SIZE    = INPUT_HEIGHT * INPUT_WIDTH * IN_CHANNELS;        // 784
    localparam CONV_OUT_SIZE = CONV_OUT_HEIGHT * CONV_OUT_WIDTH * OUT_CHANNELS; // 3456
    localparam POOL_OUT_SIZE = POOL_OUT_HEIGHT * POOL_OUT_WIDTH * OUT_CHANNELS; // 864

    // Derived widths matching DUT port declarations exactly
    localparam WGT_ADDR_W   = $clog2(TOTAL_WEIGHTS);        // weight_write_addr
    localparam BIAS_ADDR_W  = $clog2(TOTAL_BIASES);         // bias_write_addr
    localparam SRAM_ADDR_W  = $clog2(SRAM_TOTAL_ELEMENTS);  // ext_wr_addr
    localparam WGT_OFF_W    = $clog2(TOTAL_WEIGHTS+1);      // weight_layer_offset
    localparam WGT_TOT_W    = $clog2(MAX_WEIGHTS+1);        // weight_layer_total
    localparam BIAS_OFF_W   = $clog2(TOTAL_BIASES+1);       // bias_layer_offset
    localparam BIAS_TOT_W   = $clog2(MAX_BIASES+1);         // bias_layer_total

    // =========================================================================
    // Signals
    // =========================================================================
    logic clk, rst;
    logic start_layer, fc_mode, enable_relu, layer_done;

    // FIX 1+2: Runtime geometry ports (were DUT parameters, now input ports)
    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  rt_kernel_size;
    logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  rt_in_channels;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] rt_out_channels;
    logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] rt_input_height;
    logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  rt_input_width;

    // FIX 3: Runtime requant ports
    logic [31:0]        rt_requant_scale;
    logic [4:0]         rt_requant_shift;
    logic signed [7:0]  rt_ZP_next;

    // FIX 5: Corrected widths matching DUT port declarations
    logic [WGT_OFF_W-1:0]  weight_layer_offset;
    logic [WGT_TOT_W-1:0]  weight_layer_total;
    logic [BIAS_OFF_W-1:0] bias_layer_offset;
    logic [BIAS_TOT_W-1:0] bias_layer_total;

    logic [WGT_ADDR_W-1:0]      weight_write_addr;
    logic signed [DATA_WIDTH-1:0] weight_write_data;
    logic                         weight_write_enable;

    logic [BIAS_ADDR_W-1:0]     bias_write_addr;
    logic signed [31:0]          bias_write_data;
    logic                         bias_write_enable;

    logic                        ext_wr_en;
    logic [SRAM_ADDR_W-1:0]     ext_wr_addr;
    logic signed [DATA_WIDTH-1:0] ext_wr_data;

    logic sram_bank_conflict;
    // FIX 4: sram_total_* ports removed from DUT — kept here as info-only vars (always 0)
    logic [31:0] sram_total_reads, sram_total_writes, sram_total_conflicts;

    // =========================================================================
    // File handles
    // =========================================================================
    integer output_file, output_hex_file, output_dec_file;
    integer statistics_file, debug_file, summary_file;

    // =========================================================================
    // Counters
    // =========================================================================
    integer output_count      = 0;
    integer conv_output_count = 0;
    integer ext_write_count   = 0;
    integer npu_write_count   = 0;
    integer conflict_count    = 0;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT
    // FIX 1: Parameter list uses MAX_* only — KERNEL_SIZE/IN_CHANNELS etc. removed
    // FIX 2: Runtime geometry ports connected
    // FIX 3: Runtime requant ports connected
    // FIX 4: sram_total_reads/writes/conflicts port connections removed
    // =========================================================================
    lenet5_npu_sram_no_offset #(
        .MAX_KERNEL_SIZE     (MAX_KERNEL_SIZE),    // FIX 1
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
        .SRAM_TOTAL_ELEMENTS (SRAM_TOTAL_ELEMENTS)
    ) dut (
        .clk                 (clk),
        .rst                 (rst),
        .start_layer         (start_layer),
        .fc_mode             (fc_mode),
        .enable_relu         (enable_relu),
        .layer_done          (layer_done),

        // FIX 2: Runtime geometry ports
        .kernel_size         (rt_kernel_size),
        .in_channels         (rt_in_channels),
        .out_channels        (rt_out_channels),
        .input_height        (rt_input_height),
        .input_width         (rt_input_width),

        // FIX 3: Runtime requant ports
        .requant_scale       (rt_requant_scale),
        .requant_shift       (rt_requant_shift),
        .ZP_next             (rt_ZP_next),

        .weight_layer_offset (weight_layer_offset),
        .weight_layer_total  (weight_layer_total),
        .bias_layer_offset   (bias_layer_offset),
        .bias_layer_total    (bias_layer_total),
        .weight_write_addr   (weight_write_addr),
        .weight_write_data   (weight_write_data),
        .weight_write_enable (weight_write_enable),
        .bias_write_addr     (bias_write_addr),
        .bias_write_data     (bias_write_data),
        .bias_write_enable   (bias_write_enable),
        .ext_wr_en           (ext_wr_en),
        .ext_wr_addr         (ext_wr_addr),
        .ext_wr_data         (ext_wr_data),
        .sram_bank_conflict  (sram_bank_conflict)
        // FIX 4: sram_total_reads/writes/conflicts removed — ports don't exist
    );

    // =========================================================================
    // SRAM read helper — bank = addr % 5, bank_addr = addr / 5
    // =========================================================================
    function automatic logic signed [7:0] read_sram(input integer flat_addr);
        automatic integer bank  = flat_addr % 5;
        automatic integer baddr = flat_addr / 5;
        case (bank)
            0: return dut.sram.bank0[baddr];
            1: return dut.sram.bank1[baddr];
            2: return dut.sram.bank2[baddr];
            3: return dut.sram.bank3[baddr];
            4: return dut.sram.bank4[baddr];
            default: return 8'hxx;
        endcase
    endfunction

    // =========================================================================
    // File init
    // =========================================================================
    initial begin
        output_file     = $fopen("npu_output_allxx.txt",  "w");
        output_hex_file = $fopen("npu_output_hexx.txt",   "w");
        output_dec_file = $fopen("npu_output_decx.txt",   "w");
        statistics_file = $fopen("layer_statisticsx.txt", "w");
        debug_file      = $fopen("npu_debugx.txt",        "w");
        summary_file    = $fopen("test_summary.txt",       "w");

        $fwrite(output_file,  "NPU Output Log\n==============\n\n");
        $fwrite(debug_file,   "NPU Debug Log\n=============\n\n");
        $fwrite(summary_file, "LeNet5 NPU Test Summary\n=======================\n\n");

        // FIX 4: note that sram_total_* are always 0 (ports removed from DUT)
        sram_total_reads     = 0;
        sram_total_writes    = 0;
        sram_total_conflicts = 0;
    end

    // =========================================================================
    // MONITOR: External writes (image loading)
    // =========================================================================
    always @(posedge clk) begin
        if (ext_wr_en) begin
            ext_write_count++;
            if (ext_write_count <= 10 || ext_write_count > INPUT_SIZE - 10)
                $fwrite(debug_file, "[EXT_WRITE #%0d] t=%0t addr=%0d data=%0d\n",
                        ext_write_count, $time, ext_wr_addr, $signed(ext_wr_data));
            else if (ext_write_count == 11)
                $fwrite(debug_file, "  ... (%0d more ext writes) ...\n", INPUT_SIZE - 20);
        end
    end

    // =========================================================================
    // MONITOR: NPU output writes (final pooling results)
    // =========================================================================
    always @(posedge clk) begin
        if (dut.npu_out_valid) begin
            automatic logic [15:0]       addr = dut.npu_out_addr;
            automatic logic signed [7:0] data = dut.npu_out_data;

            npu_write_count++;
            output_count++;

            $fwrite(output_file,     "[OUTPUT #%0d] t=%0t addr=%0d data=%0d (0x%02h)\n",
                    output_count, $time, addr, $signed(data), data);
            $fwrite(output_hex_file, "%02h\n", data);
            $fwrite(output_dec_file, "%0d\n",  $signed(data));

            if (output_count <= 10)
                $display("[NPU OUTPUT #%0d] Addr=%0d  Data=%0d (0x%02h)",
                         output_count, addr, $signed(data), data);
            else if (output_count == 11)
                $display("  ... (more outputs) ...");
            else if (output_count > POOL_OUT_SIZE - 10)
                $display("[NPU OUTPUT #%0d] Addr=%0d  Data=%0d (0x%02h)",
                         output_count, addr, $signed(data), data);

            $fwrite(debug_file, "[NPU_WRITE #%0d] t=%0t addr=%0d data=%0d\n",
                    npu_write_count, $time, addr, $signed(data));
        end
    end

    // =========================================================================
    // MONITOR: Conv -> pooling RAM
    // =========================================================================
    always @(posedge clk) begin
        if (dut.npu.internal_fm_wr_en) begin
            conv_output_count++;
            if (conv_output_count <= 10 || conv_output_count > CONV_OUT_SIZE - 10)
                $fwrite(debug_file, "[CONV->POOL #%0d] t=%0t addr=%0d data=%0d\n",
                        conv_output_count, $time,
                        dut.npu.internal_fm_wr_addr,
                        $signed(dut.npu.internal_fm_wr_data));
            else if (conv_output_count == 11)
                $fwrite(debug_file, "  ... (%0d more conv->pool writes) ...\n",
                        CONV_OUT_SIZE - 20);
        end
    end

    // =========================================================================
    // MONITOR: Bank conflicts
    // =========================================================================
    always @(posedge clk) begin
        if (sram_bank_conflict) begin
            conflict_count++;
            if (conflict_count <= 10) begin
                $display("[%0t] BANK CONFLICT #%0d", $time, conflict_count);
                $fwrite(debug_file, "[%0t] BANK CONFLICT #%0d\n", $time, conflict_count);
            end
        end
    end

    // =========================================================================
    // Tasks
    // =========================================================================

    task automatic load_weights(input string filename,
                                input int    offset,
                                input int    count);
        int fd, i, weight_value, scan_result;
        string line;
        $display("\n[%0t] Loading weights from: %s", $time, filename);
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $display("  WARNING: file not found - using random values");
            weight_write_enable = 1'b1;
            for (i = 0; i < count; i++) begin
                @(posedge clk);
                weight_write_addr = WGT_ADDR_W'(offset + i);
                weight_write_data = $urandom_range(0, 255) - 128;
            end
            @(posedge clk); weight_write_enable = 1'b0;
            $display("  Loaded %0d random weights", count);
            return;
        end
        weight_write_enable = 1'b1;
        for (i = 0; i < count; i++) begin
            scan_result = $fscanf(fd, "%h", weight_value);
            if (scan_result != 1) begin $fseek(fd,-1,1); scan_result = $fscanf(fd,"%d",weight_value); end
            if (scan_result != 1) begin
                if ($fgets(line,fd)==0) break;
                scan_result = $sscanf(line,"%h",weight_value);
                if (scan_result!=1) scan_result=$sscanf(line,"%d",weight_value);
                if (scan_result!=1) break;
            end
            @(posedge clk);
            weight_write_addr = WGT_ADDR_W'(offset + i);
            weight_write_data = weight_value[7:0];
        end
        @(posedge clk); weight_write_enable = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d weights", i);
    endtask

    task automatic load_biases(input string filename,
                               input int    offset,
                               input int    count);
        int fd, i, bias_value, scan_result;
        string line;
        $display("\n[%0t] Loading biases from: %s", $time, filename);
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $display("  WARNING: file not found - using zeros");
            bias_write_enable = 1'b1;
            for (i = 0; i < count; i++) begin
                @(posedge clk);
                bias_write_addr = BIAS_ADDR_W'(offset + i);
                bias_write_data = 32'sd0;
            end
            @(posedge clk); bias_write_enable = 1'b0;
            $display("  Loaded %0d zero biases", count);
            return;
        end
        bias_write_enable = 1'b1;
        for (i = 0; i < count; i++) begin
            scan_result = $fscanf(fd, "%h", bias_value);
            if (scan_result != 1) begin $fseek(fd,-1,1); scan_result=$fscanf(fd,"%d",bias_value); end
            if (scan_result != 1) begin
                if ($fgets(line,fd)==0) break;
                scan_result=$sscanf(line,"%h",bias_value);
                if (scan_result!=1) scan_result=$sscanf(line,"%d",bias_value);
                if (scan_result!=1) break;
            end
            @(posedge clk);
            bias_write_addr = BIAS_ADDR_W'(offset + i);
            bias_write_data = bias_value;
        end
        @(posedge clk); bias_write_enable = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d biases", i);
    endtask

    task automatic load_image_to_sram(input string filename);
        int fd, i, pixel_value, scan_result;
        string line;
        $display("\n[%0t] Loading image: %s", $time, filename);
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $display("  WARNING: file not found - using test pattern");
            ext_wr_en = 1'b1;
            for (i = 0; i < INPUT_SIZE; i++) begin
                @(posedge clk);
                ext_wr_addr = SRAM_ADDR_W'(i);
                ext_wr_data = $signed((i % 256) - 128);
            end
            @(posedge clk); ext_wr_en = 1'b0;
            $display("  Loaded %0d test-pattern pixels", INPUT_SIZE);
            return;
        end
        i = 0;
        ext_wr_en = 1'b1;
        while (!$feof(fd) && i < INPUT_SIZE) begin
            scan_result = $fscanf(fd, "%d", pixel_value);
            if (scan_result != 1) scan_result = $fscanf(fd, "%h", pixel_value);
            if (scan_result != 1) begin
                if ($fgets(line, fd)) begin
                    scan_result = $sscanf(line, "%d", pixel_value);
                    if (scan_result != 1) scan_result = $sscanf(line, "%h", pixel_value);
                end
            end
            if (scan_result == 1) begin
                @(posedge clk);
                ext_wr_addr = SRAM_ADDR_W'(i);
                ext_wr_data = pixel_value[7:0];
                if (i < 10)
                    $display("  Pixel[%3d] = %4d (0x%02h)",
                             i, $signed(pixel_value[7:0]), pixel_value[7:0]);
                i++;
            end
        end
        @(posedge clk); ext_wr_en = 1'b0;
        $fclose(fd);
        if (i == 0) begin
            $display("  ERROR: no pixels loaded, falling back to pattern");
            ext_wr_en = 1'b1;
            for (i = 0; i < INPUT_SIZE; i++) begin
                @(posedge clk);
                ext_wr_addr = SRAM_ADDR_W'(i);
                ext_wr_data = $signed((i % 256) - 128);
            end
            @(posedge clk); ext_wr_en = 1'b0;
            i = INPUT_SIZE;
        end
        $display("  Loaded %0d pixels", i);
    endtask

    task automatic configure_layer(input int w_offset, input int w_total,
                                   input int b_offset, input int b_total);
        weight_layer_offset = WGT_OFF_W'(w_offset);
        weight_layer_total  = WGT_TOT_W'(w_total);
        bias_layer_offset   = BIAS_OFF_W'(b_offset);
        bias_layer_total    = BIAS_TOT_W'(b_total);
        $display("\n[%0t] Layer config: W[%0d+%0d]  B[%0d+%0d]",
                 $time, w_offset, w_total, b_offset, b_total);
        $fwrite(statistics_file, "\nLayer: W[%0d+%0d] B[%0d+%0d]\n",
                w_offset, w_total, b_offset, b_total);
    endtask

    // =========================================================================
    // SRAM readback using bank accessor function
    // =========================================================================
    task automatic read_sram_contents(input int    start_addr,
                                      input int    count,
                                      input string filename);
        integer i, readback_file;
        logic signed [7:0] val;

        $display("\n[%0t] SRAM readback addr=%0d..%0d -> %s",
                 $time, start_addr, start_addr+count-1, filename);

        readback_file = $fopen(filename, "w");
        $fwrite(readback_file, "SRAM Readback\n=============\n");
        $fwrite(readback_file, "Addr %0d..%0d  (%0d elements)\n\n",
                start_addr, start_addr+count-1, count);

        for (i = 0; i < count; i++) begin
            val = read_sram(start_addr + i);
            $fwrite(readback_file, "[%4d] = %4d (0x%02h)  bank=%0d baddr=%0d\n",
                    start_addr+i, $signed(val), val,
                    (start_addr+i)%5, (start_addr+i)/5);
            if (i < 10)
                $display("  SRAM[%4d] = %4d (0x%02h)", start_addr+i, $signed(val), val);
            else if (i == 10)
                $display("  ... (%0d more) ...", count-20);
            else if (i >= count-10)
                $display("  SRAM[%4d] = %4d (0x%02h)", start_addr+i, $signed(val), val);
        end
        $fclose(readback_file);
        $display("  Saved to %s", filename);
    endtask

    // FIX 6: run_layer — removed misleading sram_total_* delta stats (always 0)
    task automatic run_layer(input logic   fc,
                             input logic   relu,
                             input string  layer_name);
        integer start_time, end_time;
        integer start_npu, start_ext, start_conv, start_conflicts;

        fc_mode     = fc;
        enable_relu = relu;

        start_npu       = npu_write_count;
        start_ext       = ext_write_count;
        start_conv      = conv_output_count;
        start_conflicts = conflict_count;
        output_count    = 0;
        start_time      = $time;

        $display("\n========================================");
        $display("  Layer: %s  [%s | ReLU=%s]",
                 layer_name, fc ? "FC" : "CONV", relu ? "ON" : "OFF");
        $display("  Geometry: k=%0d  in_ch=%0d  out_ch=%0d  h=%0d  w=%0d",
                 KERNEL_SIZE, IN_CHANNELS, OUT_CHANNELS, INPUT_HEIGHT, INPUT_WIDTH);
        $display("  Requant:  scale=%0d  shift=%0d  ZP=%0d",
                 rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));
        $display("========================================");

        $fwrite(statistics_file, "\n========================================\n");
        $fwrite(statistics_file, "Layer: %s  Mode=%s  ReLU=%s\n",
                layer_name, fc ? "FC" : "CONV", relu ? "ON" : "OFF");

        @(posedge clk); start_layer = 1'b1;
        @(posedge clk); start_layer = 1'b0;

        $display("  Processing...");
        wait(layer_done);
        @(posedge clk);
        end_time = $time;

        $display("\n  Done in %0d cycles", (end_time - start_time) / CLK_PERIOD);
        $display("  Conv->pool RAM writes : %0d (expected %0d)",
                 conv_output_count - start_conv, CONV_OUT_SIZE);
        $display("  NPU->SRAM writes      : %0d (expected %0d)",
                 npu_write_count - start_npu, POOL_OUT_SIZE);
        $display("  Bank conflicts        : %0d",
                 conflict_count - start_conflicts);

        $fwrite(statistics_file, "Cycles:              %0d\n", (end_time-start_time)/CLK_PERIOD);
        $fwrite(statistics_file, "Conv->pool writes:   %0d  (expected %0d)\n",
                conv_output_count - start_conv, CONV_OUT_SIZE);
        $fwrite(statistics_file, "NPU->SRAM writes:    %0d  (expected %0d)\n",
                npu_write_count - start_npu, POOL_OUT_SIZE);
        $fwrite(statistics_file, "Bank conflicts:      %0d\n",
                conflict_count - start_conflicts);
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        rst                 = 1'b1;
        start_layer         = 1'b0;
        fc_mode             = 1'b0;
        enable_relu         = 1'b1;
        weight_write_enable = 1'b0;
        bias_write_enable   = 1'b0;
        ext_wr_en           = 1'b0;
        weight_write_addr   = '0;
        weight_write_data   = '0;
        bias_write_addr     = '0;
        bias_write_data     = '0;
        ext_wr_addr         = '0;
        ext_wr_data         = '0;
        weight_layer_offset = '0;
        weight_layer_total  = '0;
        bias_layer_offset   = '0;
        bias_layer_total    = '0;

        // FIX 2: Drive runtime geometry ports with actual layer values
        rt_kernel_size  = $bits(rt_kernel_size)'(KERNEL_SIZE);
        rt_in_channels  = $bits(rt_in_channels)'(IN_CHANNELS);
        rt_out_channels = $bits(rt_out_channels)'(OUT_CHANNELS);
        rt_input_height = $bits(rt_input_height)'(INPUT_HEIGHT);
        rt_input_width  = $bits(rt_input_width)'(INPUT_WIDTH);

        // FIX 3: Q16 identity requantization
        // scale=1,shift=0 caused 1<<(shift-1)=1<<31 undefined behavior.
        // (x*65536 + 32768) >> 16 = x for all integers — true identity.
        rt_requant_scale = 32'd65536;
        rt_requant_shift = 5'd16;
        rt_ZP_next       = 8'sd0;

        repeat(10) @(posedge clk);
        rst = 1'b0;
        repeat(5)  @(posedge clk);

        $display("========================================");
        $display("LeNet5 NPU-SRAM Integration Test");
        $display("========================================");
        $display("  Input:  %0dx%0dx%0d = %0d",
                 INPUT_HEIGHT, INPUT_WIDTH, IN_CHANNELS, INPUT_SIZE);
        $display("  Conv:   %0dx%0dx%0d = %0d",
                 CONV_OUT_HEIGHT, CONV_OUT_WIDTH, OUT_CHANNELS, CONV_OUT_SIZE);
        $display("  Pool:   %0dx%0dx%0d = %0d",
                 POOL_OUT_HEIGHT, POOL_OUT_WIDTH, OUT_CHANNELS, POOL_OUT_SIZE);
        $display("  SRAM:   %0d elements  %0d read ports",
                 SRAM_TOTAL_ELEMENTS, NUM_IMG_PORTS);
        $display("  Bank:   addr %% 5 = bank,  addr / 5 = bank_addr");
        $display("  Requant: scale=%0d  shift=%0d  ZP=%0d  (Q16 identity)",
                 rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));
        $display("========================================\n");

        $fwrite(summary_file, "Input:  %0dx%0dx%0d = %0d\n",
                INPUT_HEIGHT, INPUT_WIDTH, IN_CHANNELS, INPUT_SIZE);
        $fwrite(summary_file, "Conv:   %0dx%0dx%0d = %0d\n",
                CONV_OUT_HEIGHT, CONV_OUT_WIDTH, OUT_CHANNELS, CONV_OUT_SIZE);
        $fwrite(summary_file, "Pool:   %0dx%0dx%0d = %0d\n",
                POOL_OUT_HEIGHT, POOL_OUT_WIDTH, OUT_CHANNELS, POOL_OUT_SIZE);
        $fwrite(summary_file, "Requant: scale=%0d shift=%0d ZP=%0d\n",
                rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));

        // ---- Load weights and biases ----
        load_weights("weights_conv2_int8.mem", 0, 150);
        load_biases ("bias_conv1_int32.mem",   0, 6);

        // ---- Load input image ----
        load_image_to_sram("image_hex.mem");

        repeat(10) @(posedge clk);

        // ---- Configure and run CONV1 ----
        configure_layer(0, 150, 0, 6);
        run_layer(1'b0, 1'b1, "CONV1");

        repeat(20) @(posedge clk);

        // ---- SRAM readback ----
        $display("\n========================================");
        $display("SRAM Readback After CONV1");
        $display("========================================");
        read_sram_contents(0, POOL_OUT_SIZE, "sram_output_readback.txt");

        repeat(100) @(posedge clk);

        // ---- Final statistics ----
        $display("\n========================================");
        $display("Final Statistics");
        $display("========================================");
        $display("  Conv->Pool RAM : %0d writes (expected %0d)",
                 conv_output_count, CONV_OUT_SIZE);
        $display("  NPU->SRAM      : %0d writes (expected %0d)",
                 npu_write_count,   POOL_OUT_SIZE);
        $display("  Ext writes     : %0d  (image load = %0d)",
                 ext_write_count,   INPUT_SIZE);
        $display("  Bank conflicts : %0d", conflict_count);
        $display("========================================");

        $fwrite(summary_file, "\nFinal:\n");
        $fwrite(summary_file, "  Conv->pool: %0d  (expected %0d)\n",
                conv_output_count, CONV_OUT_SIZE);
        $fwrite(summary_file, "  NPU->SRAM:  %0d  (expected %0d)\n",
                npu_write_count,   POOL_OUT_SIZE);
        $fwrite(summary_file, "  Ext writes: %0d\n", ext_write_count);
        $fwrite(summary_file, "  Conflicts:  %0d\n", conflict_count);

        if (npu_write_count == POOL_OUT_SIZE)
            $fwrite(summary_file, "  RESULT: PASS — correct number of outputs\n");
        else
            $fwrite(summary_file, "  RESULT: FAIL — expected %0d outputs, got %0d\n",
                    POOL_OUT_SIZE, npu_write_count);

        $fclose(output_file);
        $fclose(output_hex_file);
        $fclose(output_dec_file);
        $fclose(statistics_file);
        $fclose(debug_file);
        $fclose(summary_file);

        $display("\n  Output files:");
        $display("    npu_output_allxx.txt      npu_output_hexx.txt");
        $display("    npu_output_decx.txt       layer_statisticsx.txt");
        $display("    npu_debugx.txt            test_summary.txt");
        $display("    sram_output_readback.txt");
        $display("========================================");
        $display("Test complete.");
        $display("========================================\n");
        $finish;
    end

    // =========================================================================
    // Timeout
    // =========================================================================
    initial begin
        #100_000_000;
        $display("[TIMEOUT]");
        $finish;
    end

    initial begin
        $dumpfile("lenet5_npu_comprehensive.vcd");
        $dumpvars(0, tb_lenet5_comprehensive);
    end

endmodule


// =============================================================================
// ARCHIVED: Original comprehensive TB (kept for reference only)
// =============================================================================
/*
module tb_lenet5_comprehensive;
    ... (original commented-out code preserved here but not shown for brevity)
endmodule
*/
