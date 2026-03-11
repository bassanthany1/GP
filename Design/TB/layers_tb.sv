`timescale 1ns/1ps

module tb_lenet5_fc3;

    localparam CLK_PERIOD    = 10;

    // ---- FC3 layer geometry ----
    localparam KERNEL_SIZE   = 1;
    localparam IN_CHANNELS   = 84;
    localparam OUT_CHANNELS  = 10;
    localparam INPUT_HEIGHT  = 1;
    localparam INPUT_WIDTH   = 1;

    localparam MAX_KERNEL_SIZE  = 5;
    localparam MAX_IN_CHANNELS  = 256;
    localparam MAX_OUT_CHANNELS = 120;
    localparam MAX_INPUT_HEIGHT = 28;
    localparam MAX_INPUT_WIDTH  = 28;

    localparam TILE_ROWS     = 8;
    localparam ARRAY_COLS    = 8;
    localparam DATA_WIDTH    = 8;
    localparam NUM_IMG_PORTS = 5;
    localparam MAX_BURST_LEN = 256;
    localparam MAX_WEIGHTS   = 30720;
    localparam TOTAL_WEIGHTS = 44190;
    localparam MAX_BIASES    = 120;
    localparam TOTAL_BIASES  = 236;
    localparam SRAM_TOTAL_ELEMENTS = 32768;

    localparam INPUT_SIZE    = 84;
    localparam OUTPUT_SIZE   = 10;

    localparam WEIGHT_OFFSET = 43350;
    localparam WEIGHT_TOTAL  = 840;
    localparam BIAS_OFFSET   = 226;
    localparam BIAS_TOTAL    = 10;

    localparam WGT_ADDR_W  = $clog2(TOTAL_WEIGHTS);
    localparam BIAS_ADDR_W = $clog2(TOTAL_BIASES);
    localparam SRAM_ADDR_W = $clog2(SRAM_TOTAL_ELEMENTS);
    localparam WGT_OFF_W   = $clog2(TOTAL_WEIGHTS+1);
    localparam WGT_TOT_W   = $clog2(MAX_WEIGHTS+1);
    localparam BIAS_OFF_W  = $clog2(TOTAL_BIASES+1);
    localparam BIAS_TOT_W  = $clog2(MAX_BIASES+1);

    logic clk, rst;
    logic start_layer, fc_mode, enable_relu, layer_done;

    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  rt_kernel_size;
    logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  rt_in_channels;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] rt_out_channels;
    logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] rt_input_height;
    logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  rt_input_width;

    logic [31:0]        rt_requant_scale;
    logic [5:0]         rt_requant_shift;
    logic signed [7:0]  rt_ZP_next;

    logic [WGT_OFF_W-1:0]  weight_layer_offset;
    logic [WGT_TOT_W-1:0]  weight_layer_total;
    logic [BIAS_OFF_W-1:0] bias_layer_offset;
    logic [BIAS_TOT_W-1:0] bias_layer_total;

    logic [WGT_ADDR_W-1:0]        weight_write_addr;
    logic signed [DATA_WIDTH-1:0]  weight_write_data;
    logic                           weight_write_enable;

    logic [BIAS_ADDR_W-1:0]       bias_write_addr;
    logic signed [31:0]            bias_write_data;
    logic                           bias_write_enable;

    logic                          ext_wr_en;
    logic [SRAM_ADDR_W-1:0]       ext_wr_addr;
    logic signed [DATA_WIDTH-1:0]  ext_wr_data;

    logic sram_bank_conflict;

    integer output_file, output_hex_file, output_dec_file;
    integer summary_file, latency_file;

    integer output_count    = 0;
    integer npu_write_count = 0;
    integer conflict_count  = 0;

    longint t_layer_start     = -1;
    longint t_first_out       = -1;
    longint t_last_out        = -1;
    longint t_layer_done_time = -1;

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    lenet5_npu_sram_no_offset #(
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
        .SRAM_TOTAL_ELEMENTS (SRAM_TOTAL_ELEMENTS)
    ) dut (
        .clk                 (clk),
        .rst                 (rst),
        .start_layer         (start_layer),
        .fc_mode             (fc_mode),
        .enable_relu         (enable_relu),
        .layer_done          (layer_done),
        .kernel_size         (rt_kernel_size),
        .in_channels         (rt_in_channels),
        .out_channels        (rt_out_channels),
        .input_height        (rt_input_height),
        .input_width         (rt_input_width),
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
    );

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

    initial begin
        output_file     = $fopen("fc3_output_all.txt",     "w");
        output_hex_file = $fopen("fc3_output_hex.txt",     "w");
        output_dec_file = $fopen("fc3_output_dec.txt",     "w");
        summary_file    = $fopen("fc3_summary.txt",        "w");
        latency_file    = $fopen("fc3_latency_report.txt", "w");
    end

    always @(posedge clk) begin
        if (start_layer && t_layer_start == -1)
            t_layer_start = $time;
    end
    always @(posedge clk) begin
        if (layer_done && t_layer_done_time == -1)
            t_layer_done_time = $time;
    end

    always @(posedge clk) begin
        if (dut.npu_out_valid) begin
            automatic logic [15:0]       addr = dut.npu_out_addr;
            automatic logic signed [7:0] data = dut.npu_out_data;
            npu_write_count++;
            output_count++;
            if (t_first_out == -1) t_first_out = $time;
            t_last_out = $time;
            $fwrite(output_file,     "[OUTPUT #%0d] t=%0t addr=%0d data=%0d (0x%02h)\n",
                    output_count, $time, addr, $signed(data), data);
            $fwrite(output_hex_file, "%02h\n", data);
            $fwrite(output_dec_file, "%0d\n",  $signed(data));
            // always print all 10 — it's just 10 outputs!
            $display("[FC3 OUTPUT] digit[%0d] = %0d (0x%02h)",
                     addr, $signed(data), data);
        end
    end

    always @(posedge clk) begin
        if (sram_bank_conflict) begin
            conflict_count++;
            if (conflict_count <= 5)
                $display("[%0t] BANK CONFLICT #%0d", $time, conflict_count);
        end
    end

    // =========================================================================
    // Tasks
    // =========================================================================
    task automatic load_weights(input string filename);
        int fd, i, weight_value, scan_result;
        string line;
        $display("\n[%0t] Loading weights from: %s", $time, filename);
        fd = $fopen(filename, "r");
        if (fd == 0) begin $display("ERROR: file not found"); return; end
        weight_write_enable = 1'b1;
        i = 0;
        while (!$feof(fd)) begin
            scan_result = $fscanf(fd, "%h", weight_value);
            if (scan_result != 1) begin
                if ($fgets(line, fd) == 0) break;
                scan_result = $sscanf(line, "%h", weight_value);
                if (scan_result != 1) break;
            end
            @(posedge clk);
            weight_write_addr = WGT_ADDR_W'(i);
            weight_write_data = weight_value[7:0];
            if (i >= WEIGHT_OFFSET && i < WEIGHT_OFFSET + 4)
                $display("  Weight[%0d] = %0d <-- FC3", i, $signed(weight_value[7:0]));
            i++;
        end
        @(posedge clk); weight_write_enable = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d total weights", i);
    endtask

    task automatic load_biases(input string filename);
        int fd, i, bias_value, scan_result;
        $display("\n[%0t] Loading biases from: %s", $time, filename);
        fd = $fopen(filename, "r");
        if (fd == 0) begin $display("ERROR: file not found"); return; end
        bias_write_enable = 1'b1;
        i = 0;
        while (!$feof(fd)) begin
            scan_result = $fscanf(fd, "%h", bias_value);
            if (scan_result != 1) break;
            @(posedge clk);
            bias_write_addr = BIAS_ADDR_W'(i);
            bias_write_data = $signed(bias_value);
            if (i >= BIAS_OFFSET && i < BIAS_OFFSET + 4)
                $display("  Bias[%0d] = %0d <-- FC3", i, $signed(bias_value));
            i++;
        end
        @(posedge clk); bias_write_enable = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d total biases", i);
    endtask

    task automatic load_input(input string filename);
        int fd, i, val, scan_result;
        $display("\n[%0t] Loading FC3 input: %s  (%0d values)",
                 $time, filename, INPUT_SIZE);
        fd = $fopen(filename, "r");
        if (fd == 0) begin $display("ERROR: file not found"); return; end
        i = 0;
        ext_wr_en = 1'b1;
        while (!$feof(fd) && i < INPUT_SIZE) begin
            scan_result = $fscanf(fd, "%h", val);
            if (scan_result == 1) begin
                @(posedge clk);
                ext_wr_addr = SRAM_ADDR_W'(i);
                ext_wr_data = val[7:0];
                if (i < 5)
                    $display("  Input[%0d] = %0d", i, $signed(val[7:0]));
                i++;
            end
        end
        @(posedge clk); ext_wr_en = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d values", i);
    endtask

    task automatic read_sram_contents();
        integer i, readback_file;
        logic signed [7:0] val;
        readback_file = $fopen("fc3_sram_readback.txt", "w");
        for (i = 0; i < OUTPUT_SIZE; i++) begin
            val = read_sram(i);
            $fwrite(readback_file, "[%2d] = %4d (0x%02h)  bank=%0d baddr=%0d\n",
                    i, $signed(val), val, i%5, i/5);
        end
        $fclose(readback_file);
        $display("  SRAM readback saved to fc3_sram_readback.txt");
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        rst                 = 1'b1;
        start_layer         = 1'b0;
        fc_mode             = 1'b1;
        enable_relu         = 1'b0;    // FC3: NO ReLU (final logits layer)
        weight_write_enable = 1'b0;
        bias_write_enable   = 1'b0;
        ext_wr_en           = 1'b0;
        weight_write_addr   = '0;
        weight_write_data   = '0;
        bias_write_addr     = '0;
        bias_write_data     = '0;
        ext_wr_addr         = '0;
        ext_wr_data         = '0;

        rt_kernel_size   = $bits(rt_kernel_size)'(KERNEL_SIZE);
        rt_in_channels   = $bits(rt_in_channels)'(IN_CHANNELS);
        rt_out_channels  = $bits(rt_out_channels)'(OUT_CHANNELS);
        rt_input_height  = $bits(rt_input_height)'(INPUT_HEIGHT);
        rt_input_width   = $bits(rt_input_width)'(INPUT_WIDTH);

        // FC3 requant — ZP_next = 26 (output layer, uint8)
        rt_requant_scale = 32'd1539601606;
        rt_requant_shift = 6'd38;
        rt_ZP_next       = 8'sd26;     // positive ZP for output layer

        weight_layer_offset = WGT_OFF_W'(WEIGHT_OFFSET);
        weight_layer_total  = WGT_TOT_W'(WEIGHT_TOTAL);
        bias_layer_offset   = BIAS_OFF_W'(BIAS_OFFSET);
        bias_layer_total    = BIAS_TOT_W'(BIAS_TOTAL);

        repeat(10) @(posedge clk);
        rst = 1'b0;
        repeat(5)  @(posedge clk);

        $display("========================================");
        $display("LeNet5 NPU - FC3 Standalone Test");
        $display("========================================");
        $display("  Input  : %0d values (FC2 output)", INPUT_SIZE);
        $display("  Output : %0d values (digit scores)", OUTPUT_SIZE);
        $display("  Weights: offset=%0d  total=%0d", WEIGHT_OFFSET, WEIGHT_TOTAL);
        $display("  Biases : offset=%0d  total=%0d", BIAS_OFFSET,   BIAS_TOTAL);
        $display("  Requant: scale=%0d  shift=%0d  ZP=%0d",
                 rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));
        $display("  fc_mode=1  enable_relu=0  (final layer, no ReLU)");
        $display("========================================\n");

        load_weights("all_weights.mem");
        load_biases ("all_biases_zp_fixed.mem");
        load_input  ("fc2_golden_reference.mem");

        repeat(10) @(posedge clk);

        $display("\n========================================");
        $display("  Running FC3");
        $display("========================================");

        @(posedge clk); start_layer = 1'b1;
        @(posedge clk); start_layer = 1'b0;

        $display("  Processing...");
        wait(layer_done);
        @(posedge clk);

        $display("\n  layer_done at t=%0t", $time);
        $display("  Outputs  : %0d (expected %0d)", npu_write_count, OUTPUT_SIZE);
        $display("  Cycles   : %0d", (t_layer_done_time - t_layer_start) / CLK_PERIOD);
        $display("  Conflicts: %0d", conflict_count);

        // Print predicted digit
        begin
            automatic integer max_val = -999;
            automatic integer pred    = -1;
            automatic logic signed [7:0] v;
            for (int d = 0; d < OUTPUT_SIZE; d++) begin
                v = read_sram(d);
                if ($signed(v) > max_val) begin
                    max_val = $signed(v);
                    pred    = d;
                end
            end
            $display("\n  *** Predicted digit = %0d (score=%0d) ***", pred, max_val);
            $fwrite(summary_file, "Predicted digit: %0d (score=%0d)\n", pred, max_val);
        end

        $fwrite(latency_file, "FC3 Latency\n");
        $fwrite(latency_file, "  Cycles  : %0d\n",
                (t_layer_done_time - t_layer_start) / CLK_PERIOD);
        $fwrite(latency_file, "  Outputs : %0d / %0d\n", npu_write_count, OUTPUT_SIZE);

        repeat(20) @(posedge clk);
        read_sram_contents();
        repeat(20) @(posedge clk);

        $fwrite(summary_file, "Outputs  : %0d / %0d\n", npu_write_count, OUTPUT_SIZE);
        $fwrite(summary_file, "Cycles   : %0d\n",
                (t_layer_done_time - t_layer_start) / CLK_PERIOD);
        $fwrite(summary_file, "Conflicts: %0d\n", conflict_count);
        $fwrite(summary_file, "%s\n",
                (npu_write_count==OUTPUT_SIZE) ? "RESULT: PASS" : "RESULT: FAIL");

        $fclose(output_file);
        $fclose(output_hex_file);
        $fclose(output_dec_file);
        $fclose(summary_file);
        $fclose(latency_file);

        $finish;
    end

    initial begin
        #1_000_000;
        $display("[TIMEOUT]");
        $finish;
    end

endmodule



/*module tb_lenet5_fc2;

    localparam CLK_PERIOD    = 10;
    localparam CLK_FREQ_MHZ  = 1000 / CLK_PERIOD;

    // ---- FC2 layer geometry ----
    localparam KERNEL_SIZE   = 1;
    localparam IN_CHANNELS   = 120;
    localparam OUT_CHANNELS  = 84;
    localparam INPUT_HEIGHT  = 1;
    localparam INPUT_WIDTH   = 1;

    localparam MAX_KERNEL_SIZE  = 5;
    localparam MAX_IN_CHANNELS  = 256;
    localparam MAX_OUT_CHANNELS = 120;
    localparam MAX_INPUT_HEIGHT = 28;
    localparam MAX_INPUT_WIDTH  = 28;

    localparam TILE_ROWS     = 8;
    localparam ARRAY_COLS    = 8;
    localparam DATA_WIDTH    = 8;
    localparam NUM_IMG_PORTS = 5;
    localparam MAX_BURST_LEN = 256;
    localparam MAX_WEIGHTS   = 30720;
    localparam TOTAL_WEIGHTS = 44190;
    localparam MAX_BIASES    = 120;
    localparam TOTAL_BIASES  = 236;
    localparam SRAM_TOTAL_ELEMENTS = 32768;

    localparam INPUT_SIZE    = 120;
    localparam POOL_OUT_SIZE = 84;

    localparam WEIGHT_OFFSET = 33270;
    localparam WEIGHT_TOTAL  = 10080;
    localparam BIAS_OFFSET   = 142;
    localparam BIAS_TOTAL    = 84;

    localparam WGT_ADDR_W  = $clog2(TOTAL_WEIGHTS);
    localparam BIAS_ADDR_W = $clog2(TOTAL_BIASES);
    localparam SRAM_ADDR_W = $clog2(SRAM_TOTAL_ELEMENTS);
    localparam WGT_OFF_W   = $clog2(TOTAL_WEIGHTS+1);
    localparam WGT_TOT_W   = $clog2(MAX_WEIGHTS+1);
    localparam BIAS_OFF_W  = $clog2(TOTAL_BIASES+1);
    localparam BIAS_TOT_W  = $clog2(MAX_BIASES+1);

    logic clk, rst;
    logic start_layer, fc_mode, enable_relu, layer_done;

    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  rt_kernel_size;
    logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  rt_in_channels;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] rt_out_channels;
    logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] rt_input_height;
    logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  rt_input_width;

    logic [31:0]        rt_requant_scale;
    logic [5:0]         rt_requant_shift;
    logic signed [7:0]  rt_ZP_next;

    logic [WGT_OFF_W-1:0]  weight_layer_offset;
    logic [WGT_TOT_W-1:0]  weight_layer_total;
    logic [BIAS_OFF_W-1:0] bias_layer_offset;
    logic [BIAS_TOT_W-1:0] bias_layer_total;

    logic [WGT_ADDR_W-1:0]        weight_write_addr;
    logic signed [DATA_WIDTH-1:0]  weight_write_data;
    logic                           weight_write_enable;

    logic [BIAS_ADDR_W-1:0]       bias_write_addr;
    logic signed [31:0]            bias_write_data;
    logic                           bias_write_enable;

    logic                          ext_wr_en;
    logic [SRAM_ADDR_W-1:0]       ext_wr_addr;
    logic signed [DATA_WIDTH-1:0]  ext_wr_data;

    logic sram_bank_conflict;

    integer output_file, output_hex_file, output_dec_file;
    integer summary_file, latency_file;

    integer output_count    = 0;
    integer npu_write_count = 0;
    integer conflict_count  = 0;

    longint t_layer_start     = -1;
    longint t_first_out       = -1;
    longint t_last_out        = -1;
    longint t_layer_done_time = -1;

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    lenet5_npu_sram_no_offset #(
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
        .SRAM_TOTAL_ELEMENTS (SRAM_TOTAL_ELEMENTS)
    ) dut (
        .clk                 (clk),
        .rst                 (rst),
        .start_layer         (start_layer),
        .fc_mode             (fc_mode),
        .enable_relu         (enable_relu),
        .layer_done          (layer_done),
        .kernel_size         (rt_kernel_size),
        .in_channels         (rt_in_channels),
        .out_channels        (rt_out_channels),
        .input_height        (rt_input_height),
        .input_width         (rt_input_width),
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
    );

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

    initial begin
        output_file     = $fopen("fc2_output_all.txt",     "w");
        output_hex_file = $fopen("fc2_output_hex.txt",     "w");
        output_dec_file = $fopen("fc2_output_dec.txt",     "w");
        summary_file    = $fopen("fc2_summary.txt",        "w");
        latency_file    = $fopen("fc2_latency_report.txt", "w");
    end

    always @(posedge clk) begin
        if (start_layer && t_layer_start == -1)
            t_layer_start = $time;
    end
    always @(posedge clk) begin
        if (layer_done && t_layer_done_time == -1)
            t_layer_done_time = $time;
    end

    always @(posedge clk) begin
        if (dut.npu_out_valid) begin
            automatic logic [15:0]       addr = dut.npu_out_addr;
            automatic logic signed [7:0] data = dut.npu_out_data;
            npu_write_count++;
            output_count++;
            if (t_first_out == -1) t_first_out = $time;
            t_last_out = $time;
            $fwrite(output_file,     "[OUTPUT #%0d] t=%0t addr=%0d data=%0d (0x%02h)\n",
                    output_count, $time, addr, $signed(data), data);
            $fwrite(output_hex_file, "%02h\n", data);
            $fwrite(output_dec_file, "%0d\n",  $signed(data));
            if (output_count <= 10)
                $display("[FC2 OUTPUT #%0d] addr=%0d  data=%0d",
                         output_count, addr, $signed(data));
            else if (output_count == 11)
                $display("  ... (more outputs) ...");
            else if (output_count > POOL_OUT_SIZE - 5)
                $display("[FC2 OUTPUT #%0d] addr=%0d  data=%0d",
                         output_count, addr, $signed(data));
        end
    end

    always @(posedge clk) begin
        if (sram_bank_conflict) begin
            conflict_count++;
            if (conflict_count <= 5)
                $display("[%0t] BANK CONFLICT #%0d", $time, conflict_count);
        end
    end

    // =========================================================================
    // Tasks
    // =========================================================================
    task automatic load_weights(input string filename);
        int fd, i, weight_value, scan_result;
        string line;
        $display("\n[%0t] Loading weights from: %s", $time, filename);
        fd = $fopen(filename, "r");
        if (fd == 0) begin $display("ERROR: file not found"); return; end
        weight_write_enable = 1'b1;
        i = 0;
        while (!$feof(fd)) begin
            scan_result = $fscanf(fd, "%h", weight_value);
            if (scan_result != 1) begin
                if ($fgets(line, fd) == 0) break;
                scan_result = $sscanf(line, "%h", weight_value);
                if (scan_result != 1) break;
            end
            @(posedge clk);
            weight_write_addr = WGT_ADDR_W'(i);
            weight_write_data = weight_value[7:0];
            if (i >= WEIGHT_OFFSET && i < WEIGHT_OFFSET + 4)
                $display("  Weight[%0d] = %0d <-- FC2", i, $signed(weight_value[7:0]));
            i++;
        end
        @(posedge clk); weight_write_enable = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d total weights", i);
    endtask

    task automatic load_biases(input string filename);
        int fd, i, bias_value, scan_result;
        $display("\n[%0t] Loading biases from: %s", $time, filename);
        fd = $fopen(filename, "r");
        if (fd == 0) begin $display("ERROR: file not found"); return; end
        bias_write_enable = 1'b1;
        i = 0;
        while (!$feof(fd)) begin
            scan_result = $fscanf(fd, "%h", bias_value);
            if (scan_result != 1) break;
            @(posedge clk);
            bias_write_addr = BIAS_ADDR_W'(i);
            bias_write_data = $signed(bias_value);
            if (i >= BIAS_OFFSET && i < BIAS_OFFSET + 4)
                $display("  Bias[%0d] = %0d <-- FC2", i, $signed(bias_value));
            i++;
        end
        @(posedge clk); bias_write_enable = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d total biases", i);
    endtask

    task automatic load_input(input string filename);
        int fd, i, val, scan_result;
        $display("\n[%0t] Loading FC2 input: %s  (%0d values)",
                 $time, filename, INPUT_SIZE);
        fd = $fopen(filename, "r");
        if (fd == 0) begin $display("ERROR: file not found"); return; end
        i = 0;
        ext_wr_en = 1'b1;
        while (!$feof(fd) && i < INPUT_SIZE) begin
            scan_result = $fscanf(fd, "%h", val);
            if (scan_result == 1) begin
                @(posedge clk);
                ext_wr_addr = SRAM_ADDR_W'(i);
                ext_wr_data = val[7:0];
                if (i < 5)
                    $display("  Input[%0d] = %0d", i, $signed(val[7:0]));
                i++;
            end
        end
        @(posedge clk); ext_wr_en = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d values", i);
    endtask

    task automatic read_sram_contents();
        integer i, readback_file;
        logic signed [7:0] val;
        readback_file = $fopen("fc2_sram_readback.txt", "w");
        for (i = 0; i < POOL_OUT_SIZE; i++) begin
            val = read_sram(i);
            $fwrite(readback_file, "[%3d] = %4d (0x%02h)  bank=%0d baddr=%0d\n",
                    i, $signed(val), val, i%5, i/5);
        end
        $fclose(readback_file);
        $display("  SRAM readback saved to fc2_sram_readback.txt");
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        rst                 = 1'b1;
        start_layer         = 1'b0;
        fc_mode             = 1'b1;
        enable_relu         = 1'b1;    // FC2 has ReLU
        weight_write_enable = 1'b0;
        bias_write_enable   = 1'b0;
        ext_wr_en           = 1'b0;
        weight_write_addr   = '0;
        weight_write_data   = '0;
        bias_write_addr     = '0;
        bias_write_data     = '0;
        ext_wr_addr         = '0;
        ext_wr_data         = '0;

        rt_kernel_size   = $bits(rt_kernel_size)'(KERNEL_SIZE);
        rt_in_channels   = $bits(rt_in_channels)'(IN_CHANNELS);
        rt_out_channels  = $bits(rt_out_channels)'(OUT_CHANNELS);
        rt_input_height  = $bits(rt_input_height)'(INPUT_HEIGHT);
        rt_input_width   = $bits(rt_input_width)'(INPUT_WIDTH);

        rt_requant_scale = 32'd1132918009;
        rt_requant_shift = 6'd37;
        rt_ZP_next       = -8'sd128;

        weight_layer_offset = WGT_OFF_W'(WEIGHT_OFFSET);
        weight_layer_total  = WGT_TOT_W'(WEIGHT_TOTAL);
        bias_layer_offset   = BIAS_OFF_W'(BIAS_OFFSET);
        bias_layer_total    = BIAS_TOT_W'(BIAS_TOTAL);

        repeat(10) @(posedge clk);
        rst = 1'b0;
        repeat(5)  @(posedge clk);

        $display("========================================");
        $display("LeNet5 NPU - FC2 Standalone Test");
        $display("========================================");
        $display("  Input  : %0d values (FC1 output)", INPUT_SIZE);
        $display("  Output : %0d values", POOL_OUT_SIZE);
        $display("  Weights: offset=%0d  total=%0d", WEIGHT_OFFSET, WEIGHT_TOTAL);
        $display("  Biases : offset=%0d  total=%0d", BIAS_OFFSET,   BIAS_TOTAL);
        $display("  Requant: scale=%0d  shift=%0d  ZP=%0d",
                 rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));
        $display("  fc_mode=1  enable_relu=1");
        $display("========================================\n");

        load_weights("all_weights.mem");
        load_biases ("all_biases_zp_fixed.mem");
        load_input  ("fc1_golden_reference.mem");  // use SW reference as input

        repeat(10) @(posedge clk);

        $display("\n========================================");
        $display("  Running FC2");
        $display("========================================");

        @(posedge clk); start_layer = 1'b1;
        @(posedge clk); start_layer = 1'b0;

        $display("  Processing...");
        wait(layer_done);
        @(posedge clk);

        $display("\n  layer_done at t=%0t", $time);
        $display("  Outputs  : %0d (expected %0d)", npu_write_count, POOL_OUT_SIZE);
        $display("  Cycles   : %0d", (t_layer_done_time - t_layer_start) / CLK_PERIOD);
        $display("  Conflicts: %0d", conflict_count);

        $fwrite(latency_file, "FC2 Latency\n");
        $fwrite(latency_file, "  Compute : %0d cyc\n",
                (t_layer_done_time - t_layer_start) / CLK_PERIOD);
        $fwrite(latency_file, "  Outputs : %0d / %0d\n", npu_write_count, POOL_OUT_SIZE);

        repeat(20) @(posedge clk);
        read_sram_contents();
        repeat(20) @(posedge clk);

        $display("\n========================================");
        $display("FC2 Test Complete");
        if (npu_write_count == POOL_OUT_SIZE)
            $display("  RESULT: PASS (%0d/%0d)", npu_write_count, POOL_OUT_SIZE);
        else
            $display("  RESULT: FAIL (got %0d expected %0d)",
                     npu_write_count, POOL_OUT_SIZE);
        $display("========================================\n");

        $fwrite(summary_file, "FC2 Test\n");
        $fwrite(summary_file, "Outputs  : %0d / %0d\n", npu_write_count, POOL_OUT_SIZE);
        $fwrite(summary_file, "Cycles   : %0d\n",
                (t_layer_done_time - t_layer_start) / CLK_PERIOD);
        $fwrite(summary_file, "Conflicts: %0d\n", conflict_count);
        $fwrite(summary_file, "%s\n", (npu_write_count==POOL_OUT_SIZE) ? "RESULT: PASS" : "RESULT: FAIL");

        $fclose(output_file);
        $fclose(output_hex_file);
        $fclose(output_dec_file);
        $fclose(summary_file);
        $fclose(latency_file);

        $finish;
    end

    initial begin
        #1_000_000;
        $display("[TIMEOUT]");
        $finish;
    end

endmodule*/
/*module tb_lenet5_fc1;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam CLK_PERIOD    = 10;
    localparam CLK_FREQ_MHZ  = 1000 / CLK_PERIOD;

    // ---- FC1 layer geometry ----
    localparam KERNEL_SIZE   = 1;
    localparam IN_CHANNELS   = 256;
    localparam OUT_CHANNELS  = 120;
    localparam INPUT_HEIGHT  = 1;
    localparam INPUT_WIDTH   = 1;

    // MAX_* bounds
    localparam MAX_KERNEL_SIZE  = 5;
    localparam MAX_IN_CHANNELS  = 256;
    localparam MAX_OUT_CHANNELS = 120;
    localparam MAX_INPUT_HEIGHT = 28;
    localparam MAX_INPUT_WIDTH  = 28;

    localparam TILE_ROWS     = 8;
    localparam ARRAY_COLS    = 8;
    localparam DATA_WIDTH    = 8;
    localparam NUM_IMG_PORTS = 5;
    localparam MAX_BURST_LEN = 256;
    localparam MAX_WEIGHTS   = 30720;
    localparam TOTAL_WEIGHTS = 44190;
    localparam MAX_BIASES    = 120;
    localparam TOTAL_BIASES  = 236;
    localparam SRAM_TOTAL_ELEMENTS = 32768;

    // ---- FC1 derived dimensions ----
    // FC mode: input is 256 values, output is 120 values, no pooling
    localparam INPUT_SIZE    = 256;   // flattened CONV2 output
    localparam POOL_OUT_SIZE = 120;   // FC1 output

    // ---- FC1 weight/bias offsets ----
    localparam WEIGHT_OFFSET = 2550;
    localparam WEIGHT_TOTAL  = 30720;
    localparam BIAS_OFFSET   = 22;
    localparam BIAS_TOTAL    = 120;

    // Port-width localparams
    localparam WGT_ADDR_W  = $clog2(TOTAL_WEIGHTS);
    localparam BIAS_ADDR_W = $clog2(TOTAL_BIASES);
    localparam SRAM_ADDR_W = $clog2(SRAM_TOTAL_ELEMENTS);
    localparam WGT_OFF_W   = $clog2(TOTAL_WEIGHTS+1);
    localparam WGT_TOT_W   = $clog2(MAX_WEIGHTS+1);
    localparam BIAS_OFF_W  = $clog2(TOTAL_BIASES+1);
    localparam BIAS_TOT_W  = $clog2(MAX_BIASES+1);

    // =========================================================================
    // Signals
    // =========================================================================
    logic clk, rst;
    logic start_layer, fc_mode, enable_relu, layer_done;

    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  rt_kernel_size;
    logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  rt_in_channels;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] rt_out_channels;
    logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] rt_input_height;
    logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  rt_input_width;

    logic [31:0]        rt_requant_scale;
    logic [5:0]         rt_requant_shift;
    logic signed [7:0]  rt_ZP_next;

    logic [WGT_OFF_W-1:0]  weight_layer_offset;
    logic [WGT_TOT_W-1:0]  weight_layer_total;
    logic [BIAS_OFF_W-1:0] bias_layer_offset;
    logic [BIAS_TOT_W-1:0] bias_layer_total;

    logic [WGT_ADDR_W-1:0]        weight_write_addr;
    logic signed [DATA_WIDTH-1:0]  weight_write_data;
    logic                           weight_write_enable;

    logic [BIAS_ADDR_W-1:0]       bias_write_addr;
    logic signed [31:0]            bias_write_data;
    logic                           bias_write_enable;

    logic                          ext_wr_en;
    logic [SRAM_ADDR_W-1:0]       ext_wr_addr;
    logic signed [DATA_WIDTH-1:0]  ext_wr_data;

    logic sram_bank_conflict;

    // =========================================================================
    // File handles & counters
    // =========================================================================
    integer output_hex_file, output_dec_file, output_file;
    integer summary_file, debug_file, statistics_file;
    integer latency_file, ts_file;

    integer output_count      = 0;
    integer npu_write_count   = 0;
    integer ext_write_count   = 0;
    integer conflict_count    = 0;

    // =========================================================================
    // Latency
    // =========================================================================
    longint t_layer_start     = -1;
    longint t_first_out       = -1;
    longint t_last_out        = -1;
    longint t_layer_done_time = -1;
    longint t_wgt_load_start  = -1;
    longint t_wgt_load_end    = -1;
    longint t_bias_load_start = -1;
    longint t_bias_load_end   = -1;
    longint t_img_load_start  = -1;
    longint t_img_load_end    = -1;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT
    // =========================================================================
    lenet5_npu_sram_no_offset #(
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
        .SRAM_TOTAL_ELEMENTS (SRAM_TOTAL_ELEMENTS)
    ) dut (
        .clk                 (clk),
        .rst                 (rst),
        .start_layer         (start_layer),
        .fc_mode             (fc_mode),
        .enable_relu         (enable_relu),
        .layer_done          (layer_done),
        .kernel_size         (rt_kernel_size),
        .in_channels         (rt_in_channels),
        .out_channels        (rt_out_channels),
        .input_height        (rt_input_height),
        .input_width         (rt_input_width),
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
    );

    // =========================================================================
    // SRAM read helper
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
        output_file     = $fopen("fc1_output_all.txt",      "w");
        output_hex_file = $fopen("fc1_output_hex.txt",      "w");
        output_dec_file = $fopen("fc1_output_dec.txt",      "w");
        summary_file    = $fopen("fc1_summary.txt",         "w");
        debug_file      = $fopen("fc1_debug.txt",           "w");
        statistics_file = $fopen("fc1_statistics.txt",      "w");
        latency_file    = $fopen("fc1_latency_report.txt",  "w");
        ts_file         = $fopen("fc1_timestamps.txt",      "w");
    end

    // =========================================================================
    // Latency monitors
    // =========================================================================
    always @(posedge clk) begin
        if (weight_write_enable) begin
            if (t_wgt_load_start == -1) t_wgt_load_start = $time;
            t_wgt_load_end = $time;
        end
    end
    always @(posedge clk) begin
        if (bias_write_enable) begin
            if (t_bias_load_start == -1) t_bias_load_start = $time;
            t_bias_load_end = $time;
        end
    end
    always @(posedge clk) begin
        if (ext_wr_en) begin
            if (t_img_load_start == -1) t_img_load_start = $time;
            t_img_load_end = $time;
        end
    end
    always @(posedge clk) begin
        if (start_layer && t_layer_start == -1)
            t_layer_start = $time;
    end
    always @(posedge clk) begin
        if (layer_done && t_layer_done_time == -1)
            t_layer_done_time = $time;
    end

    // =========================================================================
    // Output monitor
    // =========================================================================
    always @(posedge clk) begin
        if (dut.npu_out_valid) begin
            automatic logic [15:0]       addr = dut.npu_out_addr;
            automatic logic signed [7:0] data = dut.npu_out_data;
            npu_write_count++;
            output_count++;
            if (t_first_out == -1) t_first_out = $time;
            t_last_out = $time;
            $fwrite(output_file,     "[OUTPUT #%0d] t=%0t addr=%0d data=%0d (0x%02h)\n",
                    output_count, $time, addr, $signed(data), data);
            $fwrite(output_hex_file, "%02h\n", data);
            $fwrite(output_dec_file, "%0d\n",  $signed(data));
            $fwrite(ts_file, "#%04d  addr=%0d  data=%0d  t=%0d  cycle=%0d\n",
                    output_count, addr, $signed(data), $time, $time/CLK_PERIOD);
            if (output_count <= 10)
                $display("[FC1 OUTPUT #%0d] addr=%0d  data=%0d (0x%02h)",
                         output_count, addr, $signed(data), data);
            else if (output_count == 11)
                $display("  ... (more outputs) ...");
            else if (output_count > POOL_OUT_SIZE - 10)
                $display("[FC1 OUTPUT #%0d] addr=%0d  data=%0d (0x%02h)",
                         output_count, addr, $signed(data), data);
        end
    end

    always @(posedge clk) begin
        if (sram_bank_conflict) begin
            conflict_count++;
            if (conflict_count <= 10)
                $display("[%0t] BANK CONFLICT #%0d", $time, conflict_count);
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
        $display("\n[%0t] Loading weights from: %s  (FC1 window addr %0d..%0d)",
                 $time, filename, offset, offset+count-1);
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $display("  ERROR: file not found"); return;
        end
        weight_write_enable = 1'b1;
        i = 0;
        while (!$feof(fd)) begin
            scan_result = $fscanf(fd, "%h", weight_value);
            if (scan_result != 1) begin
                if ($fgets(line, fd) == 0) break;
                scan_result = $sscanf(line, "%h", weight_value);
                if (scan_result != 1) break;
            end
            @(posedge clk);
            weight_write_addr = WGT_ADDR_W'(i);
            weight_write_data = weight_value[7:0];
            if (i >= offset && i < offset + 4)
                $display("  Weight[%0d] = %0d (0x%02h)  <-- FC1",
                         i, $signed(weight_value[7:0]), weight_value[7:0]);
            i++;
        end
        @(posedge clk); weight_write_enable = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d total weights", i);
    endtask

    task automatic load_biases(input string filename,
                               input int    offset,
                               input int    count);
        int fd, i, bias_value, scan_result;
        $display("\n[%0t] Loading biases from: %s  (FC1 window addr %0d..%0d)",
                 $time, filename, offset, offset+count-1);
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $display("  ERROR: file not found"); return;
        end
        bias_write_enable = 1'b1;
        i = 0;
        while (!$feof(fd)) begin
            scan_result = $fscanf(fd, "%h", bias_value);
            if (scan_result != 1) break;
            @(posedge clk);
            bias_write_addr = BIAS_ADDR_W'(i);
            bias_write_data = $signed(bias_value);
            if (i >= offset && i < offset + 4)
                $display("  Bias[%0d] = %0d (0x%08h)  <-- FC1",
                         i, $signed(bias_value), bias_value);
            i++;
        end
        @(posedge clk); bias_write_enable = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d total biases", i);
    endtask

    task automatic load_image_to_sram(input string filename);
        int fd, i, pixel_value, scan_result;
        $display("\n[%0t] Loading FC1 input: %s  (%0d values)",
                 $time, filename, INPUT_SIZE);
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $display("  ERROR: file not found"); return;
        end
        i = 0;
        ext_wr_en = 1'b1;
        while (!$feof(fd) && i < INPUT_SIZE) begin
            scan_result = $fscanf(fd, "%h", pixel_value);
            if (scan_result == 1) begin
                @(posedge clk);
                ext_wr_addr = SRAM_ADDR_W'(i);
                ext_wr_data = pixel_value[7:0];
                if (i < 10)
                    $display("  Input[%3d] = %4d (0x%02h)",
                             i, $signed(pixel_value[7:0]), pixel_value[7:0]);
                i++;
            end
        end
        @(posedge clk); ext_wr_en = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d values", i);
    endtask

    task automatic read_sram_contents(input int    start_addr,
                                      input int    count,
                                      input string filename);
        integer i, readback_file;
        logic signed [7:0] val;
        readback_file = $fopen(filename, "w");
        $fwrite(readback_file, "FC1 SRAM Readback\n=================\n");
        for (i = 0; i < count; i++) begin
            val = read_sram(start_addr + i);
            $fwrite(readback_file, "[%4d] = %4d (0x%02h)  bank=%0d baddr=%0d\n",
                    start_addr+i, $signed(val), val,
                    (start_addr+i)%5, (start_addr+i)/5);
        end
        $fclose(readback_file);
        $display("  SRAM readback saved to %s", filename);
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        rst                 = 1'b1;
        start_layer         = 1'b0;
        fc_mode             = 1'b1;       // FC mode ON
        enable_relu         = 1'b1;       // ReLU ON for FC1
        weight_write_enable = 1'b0;
        bias_write_enable   = 1'b0;
        ext_wr_en           = 1'b0;
        weight_write_addr   = '0;
        weight_write_data   = '0;
        bias_write_addr     = '0;
        bias_write_data     = '0;
        ext_wr_addr         = '0;
        ext_wr_data         = '0;

        // FC1 runtime geometry
        rt_kernel_size   = $bits(rt_kernel_size)'(KERNEL_SIZE);    // 1
        rt_in_channels   = $bits(rt_in_channels)'(IN_CHANNELS);    // 256
        rt_out_channels  = $bits(rt_out_channels)'(OUT_CHANNELS);  // 120
        rt_input_height  = $bits(rt_input_height)'(INPUT_HEIGHT);  // 1
        rt_input_width   = $bits(rt_input_width)'(INPUT_WIDTH);    // 1

        // FC1 requantization
        rt_requant_scale = 32'd1773475289;
        rt_requant_shift = 6'd38;
        rt_ZP_next       = -8'sd128;

        // Layer window offsets
        weight_layer_offset = WGT_OFF_W'(WEIGHT_OFFSET);
        weight_layer_total  = WGT_TOT_W'(WEIGHT_TOTAL);
        bias_layer_offset   = BIAS_OFF_W'(BIAS_OFFSET);
        bias_layer_total    = BIAS_TOT_W'(BIAS_TOTAL);

        repeat(10) @(posedge clk);
        rst = 1'b0;
        repeat(5)  @(posedge clk);

        $display("========================================");
        $display("LeNet5 NPU - FC1 Standalone Test");
        $display("========================================");
        $display("  Input  : %0d values (flattened CONV2 output)", INPUT_SIZE);
        $display("  Output : %0d values", POOL_OUT_SIZE);
        $display("  Weights: offset=%0d  total=%0d", WEIGHT_OFFSET, WEIGHT_TOTAL);
        $display("  Biases : offset=%0d  total=%0d", BIAS_OFFSET,   BIAS_TOTAL);
        $display("  Requant: scale=%0d  shift=%0d  ZP=%0d",
                 rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));
        $display("  fc_mode=1  enable_relu=1");
        $display("========================================\n");

        load_weights      ("all_weights.mem",         WEIGHT_OFFSET, WEIGHT_TOTAL);
        load_biases       ("all_biases_zp_fixed.mem", BIAS_OFFSET,   BIAS_TOTAL);
        load_image_to_sram("conv2_pool2_output.mem");  // SW reference as input

        repeat(10) @(posedge clk);

        $display("\n========================================");
        $display("  Running FC1");
        $display("========================================");

        @(posedge clk); start_layer = 1'b1;
        @(posedge clk); start_layer = 1'b0;

        $display("  Processing...");
        wait(layer_done);
        @(posedge clk);

        $display("\n  layer_done at t=%0t", $time);
        $display("  Outputs written: %0d (expected %0d)", npu_write_count, POOL_OUT_SIZE);
        $display("  Bank conflicts : %0d", conflict_count);
        $display("  Total cycles   : %0d", (t_layer_done_time - t_layer_start) / CLK_PERIOD);

        $fwrite(latency_file, "FC1 Latency\n");
        $fwrite(latency_file, "  Weight load : %0d cyc\n", (t_wgt_load_end-t_wgt_load_start)/CLK_PERIOD);
        $fwrite(latency_file, "  Bias load   : %0d cyc\n", (t_bias_load_end-t_bias_load_start)/CLK_PERIOD);
        $fwrite(latency_file, "  Input load  : %0d cyc\n", (t_img_load_end-t_img_load_start)/CLK_PERIOD);
        $fwrite(latency_file, "  Compute     : %0d cyc\n", (t_layer_done_time-t_layer_start)/CLK_PERIOD);
        $fwrite(latency_file, "  First out   : %0d cyc after start\n", (t_first_out-t_layer_start)/CLK_PERIOD);

        repeat(20) @(posedge clk);
        read_sram_contents(0, POOL_OUT_SIZE, "fc1_sram_readback.txt");
        repeat(50) @(posedge clk);

        $display("\n========================================");
        $display("FC1 Test Complete");
        if (npu_write_count == POOL_OUT_SIZE)
            $display("  RESULT: PASS (%0d/%0d outputs)", npu_write_count, POOL_OUT_SIZE);
        else
            $display("  RESULT: FAIL (got %0d, expected %0d)", npu_write_count, POOL_OUT_SIZE);
        $display("========================================\n");

        $fwrite(summary_file, "FC1 Test\n");
        $fwrite(summary_file, "Outputs  : %0d / %0d\n", npu_write_count, POOL_OUT_SIZE);
        $fwrite(summary_file, "Conflicts: %0d\n", conflict_count);
        $fwrite(summary_file, "Cycles   : %0d\n", (t_layer_done_time-t_layer_start)/CLK_PERIOD);
        if (npu_write_count == POOL_OUT_SIZE)
            $fwrite(summary_file, "RESULT: PASS\n");
        else
            $fwrite(summary_file, "RESULT: FAIL\n");

        $fclose(output_file);
        $fclose(output_hex_file);
        $fclose(output_dec_file);
        $fclose(summary_file);
        $fclose(debug_file);
        $fclose(statistics_file);
        $fclose(latency_file);
        $fclose(ts_file);

        $finish;
    end

    initial begin
        #200_000_000;
        $display("[TIMEOUT] Simulation exceeded 200ms");
        $finish;
    end

endmodule*/
/*module tb_lenet5_conv2;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam CLK_PERIOD    = 10;      // ns  (100 MHz)
    localparam CLK_FREQ_MHZ  = 1000 / CLK_PERIOD;

    // ---- CONV2 layer geometry ----
    localparam KERNEL_SIZE   = 5;
    localparam IN_CHANNELS   = 6;
    localparam OUT_CHANNELS  = 16;
    localparam INPUT_HEIGHT  = 12;
    localparam INPUT_WIDTH   = 12;

    // MAX_* bounds – DUT compile-time parameters
    localparam MAX_KERNEL_SIZE  = 5;
    localparam MAX_IN_CHANNELS  = 6;
    localparam MAX_OUT_CHANNELS = 16;
    localparam MAX_INPUT_HEIGHT = 28;
    localparam MAX_INPUT_WIDTH  = 28;

    // Fixed architecture params
    localparam TILE_ROWS     = 8;
    localparam ARRAY_COLS    = 8;
    localparam DATA_WIDTH    = 8;
    localparam NUM_IMG_PORTS = 5;
    localparam MAX_BURST_LEN = 256;
    localparam MAX_WEIGHTS   = 30720;
    localparam TOTAL_WEIGHTS = 44190;
    localparam MAX_BIASES    = 120;
    localparam TOTAL_BIASES  = 236;
    localparam SRAM_TOTAL_ELEMENTS = 32768;

    // ---- CONV2 derived dimensions ----
    localparam CONV_OUT_HEIGHT = INPUT_HEIGHT - KERNEL_SIZE + 1;  // 8
    localparam CONV_OUT_WIDTH  = INPUT_WIDTH  - KERNEL_SIZE + 1;  // 8
    localparam POOL_OUT_HEIGHT = CONV_OUT_HEIGHT / 2;             // 4
    localparam POOL_OUT_WIDTH  = CONV_OUT_WIDTH  / 2;             // 4

    localparam INPUT_SIZE    = INPUT_HEIGHT * INPUT_WIDTH * IN_CHANNELS;         // 864
    localparam CONV_OUT_SIZE = CONV_OUT_HEIGHT * CONV_OUT_WIDTH * OUT_CHANNELS;  // 1024
    localparam POOL_OUT_SIZE = POOL_OUT_HEIGHT * POOL_OUT_WIDTH * OUT_CHANNELS;  // 256

    // ---- CONV2 weight/bias offsets in shared memory files ----
    localparam WEIGHT_OFFSET = 150;   // skip CONV1 weights (1*6*5*5 = 150)
    localparam WEIGHT_TOTAL  = 2400;  // CONV2 weights (6*16*5*5 = 2400)
    localparam BIAS_OFFSET   = 6;     // skip CONV1 biases
    localparam BIAS_TOTAL    = 16;    // CONV2 biases

    // Port-width localparams
    localparam WGT_ADDR_W  = $clog2(TOTAL_WEIGHTS);
    localparam BIAS_ADDR_W = $clog2(TOTAL_BIASES);
    localparam SRAM_ADDR_W = $clog2(SRAM_TOTAL_ELEMENTS);
    localparam WGT_OFF_W   = $clog2(TOTAL_WEIGHTS+1);
    localparam WGT_TOT_W   = $clog2(MAX_WEIGHTS+1);
    localparam BIAS_OFF_W  = $clog2(TOTAL_BIASES+1);
    localparam BIAS_TOT_W  = $clog2(MAX_BIASES+1);

    // ---- Comparison tolerance ----
    // A result is PASS when |got - expected| <= CMP_TOLERANCE
    localparam int CMP_TOLERANCE = 3;

    // =========================================================================
    // Signals
    // =========================================================================
    logic clk, rst;
    logic start_layer, fc_mode, enable_relu, layer_done;

    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  rt_kernel_size;
    logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  rt_in_channels;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] rt_out_channels;
    logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] rt_input_height;
    logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  rt_input_width;

    logic [31:0]        rt_requant_scale;
    logic [5:0]         rt_requant_shift;
    logic signed [7:0]  rt_ZP_next;

    logic [WGT_OFF_W-1:0]  weight_layer_offset;
    logic [WGT_TOT_W-1:0]  weight_layer_total;
    logic [BIAS_OFF_W-1:0] bias_layer_offset;
    logic [BIAS_TOT_W-1:0] bias_layer_total;

    logic [WGT_ADDR_W-1:0]        weight_write_addr;
    logic signed [DATA_WIDTH-1:0]  weight_write_data;
    logic                           weight_write_enable;

    logic [BIAS_ADDR_W-1:0]       bias_write_addr;
    logic signed [31:0]            bias_write_data;
    logic                           bias_write_enable;

    logic                          ext_wr_en;
    logic [SRAM_ADDR_W-1:0]       ext_wr_addr;
    logic signed [DATA_WIDTH-1:0]  ext_wr_data;

    logic sram_bank_conflict;

    // =========================================================================
    // Golden reference storage
    // =========================================================================
    logic signed [7:0] golden [0:POOL_OUT_SIZE-1];
    integer            golden_loaded = 0;   // how many entries were read

    // Per-output comparison result captured in the streaming monitor
    integer cmp_pass  = 0;
    integer cmp_fail  = 0;
    integer cmp_total = 0;

    // =========================================================================
    // File handles
    // =========================================================================
    integer output_file, output_hex_file, output_dec_file;
    integer statistics_file, debug_file, summary_file;
    integer latency_file, ts_file;
    integer compare_file;   // NEW – per-output comparison log

    // =========================================================================
    // Counters
    // =========================================================================
    integer output_count      = 0;
    integer conv_output_count = 0;
    integer ext_write_count   = 0;
    integer npu_write_count   = 0;
    integer conflict_count    = 0;

    // =========================================================================
    // LATENCY MEASUREMENT
    // =========================================================================
    longint t_wgt_load_start  = -1;
    longint t_wgt_load_end    = -1;
    longint t_bias_load_start = -1;
    longint t_bias_load_end   = -1;
    longint t_img_load_start  = -1;
    longint t_img_load_end    = -1;
    longint t_layer_start     = -1;
    longint t_first_conv_out  = -1;
    longint t_last_conv_out   = -1;
    longint t_first_pool_out  = -1;
    longint t_last_pool_out   = -1;
    longint t_layer_done_time = -1;

    longint pool_out_ts [POOL_OUT_SIZE];
    integer pool_out_logged = 0;

    longint t_prev_pool_out = -1;
    longint max_ioi         =  0;
    longint min_ioi         = 64'h7FFF_FFFF_FFFF_FFFF;
    longint sum_ioi         =  0;
    integer ioi_count       =  0;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT
    // =========================================================================
    lenet5_npu_sram_no_offset #(
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
        .SRAM_TOTAL_ELEMENTS (SRAM_TOTAL_ELEMENTS)
    ) dut (
        .clk                 (clk),
        .rst                 (rst),
        .start_layer         (start_layer),
        .fc_mode             (fc_mode),
        .enable_relu         (enable_relu),
        .layer_done          (layer_done),
        .kernel_size         (rt_kernel_size),
        .in_channels         (rt_in_channels),
        .out_channels        (rt_out_channels),
        .input_height        (rt_input_height),
        .input_width         (rt_input_width),
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
    );

    // =========================================================================
    // SRAM read helper
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
        output_file     = $fopen("conv2_output_all.txt",          "w");
        output_hex_file = $fopen("conv2_output_hex.txt",          "w");
        output_dec_file = $fopen("conv2_output_dec.txt",          "w");
        statistics_file = $fopen("conv2_statistics.txt",          "w");
        debug_file      = $fopen("conv2_debug.txt",               "w");
        summary_file    = $fopen("conv2_summary.txt",             "w");
        latency_file    = $fopen("conv2_latency_report.txt",      "w");
        ts_file         = $fopen("conv2_pool_timestamps.txt",     "w");
        compare_file    = $fopen("conv2_compare.txt",             "w");   // NEW

        $fwrite(output_file,  "CONV2 NPU Output Log\n====================\n\n");
        $fwrite(debug_file,   "CONV2 Debug Log\n===============\n\n");
        $fwrite(summary_file, "CONV2 Test Summary\n==================\n\n");

        $fwrite(latency_file, "CONV2 Latency Report\n");
        $fwrite(latency_file, "====================\n");
        $fwrite(latency_file, "Timescale : 1ns / 1ps\n");
        $fwrite(latency_file, "Clock     : %0d ns (%0d MHz)\n\n", CLK_PERIOD, CLK_FREQ_MHZ);

        $fwrite(ts_file, "CONV2 Pool Output Timestamp Log\n");
        $fwrite(ts_file, "================================\n");
        $fwrite(ts_file, "Format: #idx  addr  data  time_ns  cycle\n\n");

        // NEW – comparison file header
        $fwrite(compare_file, "CONV2 Golden Reference Comparison\n");
        $fwrite(compare_file, "==================================\n");
        $fwrite(compare_file, "Golden file  : conv2_pool2_output.mem\n");
        $fwrite(compare_file, "Expected outs: %0d\n", POOL_OUT_SIZE);
        $fwrite(compare_file, "Tolerance    : +/- %0d  (|got-exp| <= %0d => PASS)\n\n",
                CMP_TOLERANCE, CMP_TOLERANCE);
        $fwrite(compare_file, "Format: #idx  addr  got  expected  error  PASS/FAIL\n\n");
    end

    // =========================================================================
    // LATENCY MONITORS
    // =========================================================================

    always @(posedge clk) begin
        if (weight_write_enable) begin
            if (t_wgt_load_start == -1) t_wgt_load_start = $time;
            t_wgt_load_end = $time;
        end
    end

    always @(posedge clk) begin
        if (bias_write_enable) begin
            if (t_bias_load_start == -1) t_bias_load_start = $time;
            t_bias_load_end = $time;
        end
    end

    always @(posedge clk) begin
        if (ext_wr_en) begin
            if (t_img_load_start == -1) t_img_load_start = $time;
            t_img_load_end = $time;
        end
    end

    always @(posedge clk) begin
        if (start_layer && t_layer_start == -1)
            t_layer_start = $time;
    end

    always @(posedge clk) begin
        if (dut.npu.internal_fm_wr_en) begin
            if (t_first_conv_out == -1) t_first_conv_out = $time;
            t_last_conv_out = $time;
        end
    end

    always @(posedge clk) begin
        if (dut.npu_out_valid) begin
            automatic longint now = $time;
            if (t_first_pool_out == -1) t_first_pool_out = now;
            t_last_pool_out = now;
            if (pool_out_logged < POOL_OUT_SIZE) begin
                pool_out_ts[pool_out_logged] = now;
                $fwrite(ts_file, "#%04d  addr=%0d  data=%0d  t=%0d ns  cycle=%0d\n",
                        pool_out_logged,
                        dut.npu_out_addr, $signed(dut.npu_out_data),
                        now, now / CLK_PERIOD);
                pool_out_logged++;
            end
            if (t_prev_pool_out != -1) begin
                automatic longint ioi = now - t_prev_pool_out;
                if (ioi > max_ioi) max_ioi = ioi;
                if (ioi < min_ioi) min_ioi = ioi;
                sum_ioi  = sum_ioi + ioi;
                ioi_count++;
            end
            t_prev_pool_out = now;
        end
    end

    always @(posedge clk) begin
        if (layer_done && t_layer_done_time == -1)
            t_layer_done_time = $time;
    end

    // =========================================================================
    // OUTPUT MONITORS
    // =========================================================================

    always @(posedge clk) begin
        if (ext_wr_en) begin
            ext_write_count++;
            if (ext_write_count <= 10 || ext_write_count > INPUT_SIZE - 10)
                $fwrite(debug_file, "[EXT_WRITE #%0d] t=%0t addr=%0d data=%0d\n",
                        ext_write_count, $time, ext_wr_addr, $signed(ext_wr_data));
            else if (ext_write_count == 11)
                $fwrite(debug_file, "  ... more ext writes ...\n");
        end
    end

    // =========================================================================
    // OUTPUT MONITOR + INLINE GOLDEN COMPARISON  (NEW / MODIFIED)
    // =========================================================================
    always @(posedge clk) begin
        if (dut.npu_out_valid) begin
            automatic logic [15:0]       addr    = dut.npu_out_addr;
            automatic logic signed [7:0] got     = dut.npu_out_data;
            automatic logic signed [7:0] exp_val;
            automatic string             cmp_str;

            npu_write_count++;
            output_count++;

            // ---- log to output files ----
            $fwrite(output_file,     "[OUTPUT #%0d] t=%0t addr=%0d data=%0d (0x%02h)\n",
                    output_count, $time, addr, $signed(got), got);
            $fwrite(output_hex_file, "%02h\n", got);
            $fwrite(output_dec_file, "%0d\n",  $signed(got));

            if (output_count <= 10)
                $display("[NPU OUTPUT #%0d] Addr=%0d  Data=%0d (0x%02h)",
                         output_count, addr, $signed(got), got);
            else if (output_count == 11)
                $display("  ... (more outputs) ...");
            else if (output_count > POOL_OUT_SIZE - 10)
                $display("[NPU OUTPUT #%0d] Addr=%0d  Data=%0d (0x%02h)",
                         output_count, addr, $signed(got), got);

            $fwrite(debug_file, "[NPU_WRITE #%0d] t=%0t addr=%0d data=%0d\n",
                    npu_write_count, $time, addr, $signed(got));

            // ---- golden comparison ----
            // addr is the flat output index (0-based, same order as .mem file)
            cmp_total++;
            if (addr < POOL_OUT_SIZE && golden_loaded > int'(addr)) begin
                automatic int err;
                exp_val = golden[addr];
                err     = int'($signed(got)) - int'($signed(exp_val));
                if (err < 0) err = -err;   // |got - expected|
                if (err <= CMP_TOLERANCE) begin
                    cmp_pass++;
                    cmp_str = "PASS";
                end else begin
                    cmp_fail++;
                    cmp_str = "FAIL";
                    $display("[MISMATCH] #%0d  addr=%0d  got=%0d  expected=%0d  err=%0d  <<<",
                             cmp_total, addr, $signed(got), $signed(exp_val),
                             int'($signed(got)) - int'($signed(exp_val)));
                end
                $fwrite(compare_file, "#%04d  addr=%4d  got=%4d  exp=%4d  err=%4d  %s\n",
                        cmp_total, addr, $signed(got), $signed(exp_val),
                        int'($signed(got)) - int'($signed(exp_val)), cmp_str);
            end else begin
                // golden not loaded or addr out of range – log without comparing
                $fwrite(compare_file, "#%04d  addr=%4d  got=%4d  exp=????  err=????  (no golden)\n",
                        cmp_total, addr, $signed(got));
            end
        end
    end

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
    // LATENCY REPORT TASK
    // =========================================================================
    task automatic report_latency();

        longint wgt_load_ns, bias_load_ns, img_load_ns;
        longint conv_start_lat_ns, conv_total_ns;
        longint pool_start_lat_ns, pool_total_ns;
        longint total_layer_ns, output_stream_ns;
        longint setup_overhead_ns, total_setup_ns;

        longint wgt_load_cyc, bias_load_cyc, img_load_cyc;
        longint conv_start_lat_cyc, conv_total_cyc;
        longint pool_start_lat_cyc, pool_total_cyc;
        longint total_layer_cyc, output_stream_cyc;
        longint setup_overhead_cyc, total_setup_cyc;

        real output_tput, conv_efficiency, avg_ioi_ns;

        // Intervals
        wgt_load_ns       = (t_wgt_load_end  >= t_wgt_load_start  && t_wgt_load_start  >= 0)
                            ? t_wgt_load_end  - t_wgt_load_start  + CLK_PERIOD : 0;
        bias_load_ns      = (t_bias_load_end >= t_bias_load_start && t_bias_load_start >= 0)
                            ? t_bias_load_end - t_bias_load_start + CLK_PERIOD : 0;
        img_load_ns       = (t_img_load_end  >= t_img_load_start  && t_img_load_start  >= 0)
                            ? t_img_load_end  - t_img_load_start  + CLK_PERIOD : 0;
        conv_start_lat_ns = (t_first_conv_out >= 0 && t_layer_start >= 0)
                            ? t_first_conv_out - t_layer_start : -1;
        conv_total_ns     = (t_last_conv_out  >= 0 && t_layer_start >= 0)
                            ? t_last_conv_out  - t_layer_start : -1;
        pool_start_lat_ns = (t_first_pool_out >= 0 && t_last_conv_out >= 0)
                            ? t_first_pool_out - t_last_conv_out : -1;
        pool_total_ns     = (t_last_pool_out  >= 0 && t_last_conv_out >= 0)
                            ? t_last_pool_out  - t_last_conv_out : -1;
        total_layer_ns    = (t_layer_done_time >= 0 && t_layer_start >= 0)
                            ? t_layer_done_time - t_layer_start : -1;
        output_stream_ns  = (t_last_pool_out >= 0 && t_first_pool_out >= 0)
                            ? t_last_pool_out - t_first_pool_out : -1;
        setup_overhead_ns = (total_layer_ns > 0 && conv_total_ns > 0)
                            ? total_layer_ns - conv_total_ns : -1;
        total_setup_ns    = wgt_load_ns + bias_load_ns + img_load_ns;

        // Cycles
        wgt_load_cyc       = wgt_load_ns       / CLK_PERIOD;
        bias_load_cyc      = bias_load_ns      / CLK_PERIOD;
        img_load_cyc       = img_load_ns       / CLK_PERIOD;
        conv_start_lat_cyc = conv_start_lat_ns / CLK_PERIOD;
        conv_total_cyc     = conv_total_ns      / CLK_PERIOD;
        pool_start_lat_cyc = pool_start_lat_ns / CLK_PERIOD;
        pool_total_cyc     = pool_total_ns      / CLK_PERIOD;
        total_layer_cyc    = total_layer_ns     / CLK_PERIOD;
        output_stream_cyc  = output_stream_ns   / CLK_PERIOD;
        setup_overhead_cyc = setup_overhead_ns  / CLK_PERIOD;
        total_setup_cyc    = total_setup_ns     / CLK_PERIOD;

        output_tput     = (output_stream_cyc > 0)
                          ? real'(POOL_OUT_SIZE) / real'(output_stream_cyc) : 0.0;
        conv_efficiency = (total_layer_cyc > 0)
                          ? real'(CONV_OUT_SIZE) / real'(total_layer_cyc) : 0.0;
        avg_ioi_ns      = (ioi_count > 0)
                          ? real'(sum_ioi) / real'(ioi_count) : 0.0;

        // Console
        $display("\n════════════════════════════════════════════════════════");
        $display("  LATENCY REPORT – CONV2");
        $display("════════════════════════════════════════════════════════");
        $display("  Clock   : %0d MHz  |  Timescale: 1ns/1ps", CLK_FREQ_MHZ);
        $display("  Geometry: k=%0d  in=%0d  out=%0d  h=%0d  w=%0d",
                 KERNEL_SIZE, IN_CHANNELS, OUT_CHANNELS, INPUT_HEIGHT, INPUT_WIDTH);
        $display("  W offset=%0d  W total=%0d  B offset=%0d  B total=%0d",
                 WEIGHT_OFFSET, WEIGHT_TOTAL, BIAS_OFFSET, BIAS_TOTAL);
        $display("  Requant : scale=%0d  shift=%0d  ZP=%0d",
                 rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));
        $display("────────────────────────────────────────────────────────");
        $display("  SETUP PHASE (before start_layer)");
        $display("    Weight load  : %0d ns  /  %0d cycles", wgt_load_ns,    wgt_load_cyc);
        $display("    Bias load    : %0d ns  /  %0d cycles", bias_load_ns,   bias_load_cyc);
        $display("    Image load   : %0d ns  /  %0d cycles", img_load_ns,    img_load_cyc);
        $display("    Total setup  : %0d ns  /  %0d cycles", total_setup_ns, total_setup_cyc);
        $display("────────────────────────────────────────────────────────");
        $display("  CONV PHASE (from start_layer)");
        if (conv_start_lat_ns >= 0)
            $display("    Start latency  : %0d ns  /  %0d cycles",
                     conv_start_lat_ns, conv_start_lat_cyc);
        else
            $display("    Start latency  : N/A");
        if (conv_total_ns >= 0)
            $display("    Total duration : %0d ns  /  %0d cycles",
                     conv_total_ns, conv_total_cyc);
        $display("    Outputs written: %0d  (expected %0d)", conv_output_count, CONV_OUT_SIZE);
        $display("────────────────────────────────────────────────────────");
        $display("  POOL PHASE (from last conv output)");
        if (pool_start_lat_ns >= 0)
            $display("    Start latency  : %0d ns  /  %0d cycles",
                     pool_start_lat_ns, pool_start_lat_cyc);
        else
            $display("    Start latency  : N/A");
        if (pool_total_ns >= 0)
            $display("    Total duration : %0d ns  /  %0d cycles",
                     pool_total_ns, pool_total_cyc);
        $display("    Outputs written: %0d  (expected %0d)", npu_write_count, POOL_OUT_SIZE);
        $display("────────────────────────────────────────────────────────");
        $display("  TOTAL LAYER LATENCY (start_layer -> layer_done)");
        if (total_layer_ns >= 0)
            $display("    %0d ns  /  %0d cycles  /  %.3f µs",
                     total_layer_ns, total_layer_cyc,
                     real'(total_layer_ns) / 1000.0);
        else
            $display("    N/A");
        $display("────────────────────────────────────────────────────────");
        $display("  OUTPUT STREAM (first -> last pool output)");
        if (output_stream_ns >= 0) begin
            $display("    Duration   : %0d ns  /  %0d cycles",
                     output_stream_ns, output_stream_cyc);
            $display("    Throughput : %.4f outputs/cycle  (%.1f outputs/µs)",
                     output_tput, output_tput * CLK_FREQ_MHZ);
        end
        $display("────────────────────────────────────────────────────────");
        $display("  INTER-OUTPUT INTERVAL");
        if (ioi_count > 0)
            $display("    n=%0d  min=%0d ns  max=%0d ns  avg=%.1f ns",
                     ioi_count, min_ioi, max_ioi, avg_ioi_ns);
        else
            $display("    No intervals recorded");
        $display("────────────────────────────────────────────────────────");
        $display("  EFFICIENCY");
        $display("    Conv outputs/cycle    : %.4f", conv_efficiency);
        if (setup_overhead_ns >= 0)
            $display("    Non-compute overhead : %0d cycles", setup_overhead_cyc);
        $display("    Bank conflicts        : %0d", conflict_count);
        $display("────────────────────────────────────────────────────────");
        $display("  GOLDEN COMPARISON  (tolerance +/-%0d)", CMP_TOLERANCE);
        if (golden_loaded > 0) begin
            $display("    Compared : %0d / %0d", cmp_total, POOL_OUT_SIZE);
            $display("    PASS     : %0d", cmp_pass);
            $display("    FAIL     : %0d", cmp_fail);
            if (cmp_fail == 0)
                $display("    *** ALL WITHIN TOLERANCE ***");
            else
                $display("    *** %0d OUTPUT(S) OUTSIDE TOLERANCE ***", cmp_fail);
        end else
            $display("    Golden file not loaded – no comparison performed");
        $display("════════════════════════════════════════════════════════");

        // File
        $fwrite(latency_file, "Layer    : CONV2\n");
        $fwrite(latency_file, "Geometry : k=%0d  in=%0d  out=%0d  h=%0d  w=%0d\n",
                KERNEL_SIZE, IN_CHANNELS, OUT_CHANNELS, INPUT_HEIGHT, INPUT_WIDTH);
        $fwrite(latency_file, "Requant  : scale=%0d  shift=%0d  ZP=%0d\n\n",
                rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));

        $fwrite(latency_file, "--- TIMESTAMPS (ns) ---\n");
        $fwrite(latency_file, "  t_wgt_load_start  = %0d\n", t_wgt_load_start);
        $fwrite(latency_file, "  t_wgt_load_end    = %0d\n", t_wgt_load_end);
        $fwrite(latency_file, "  t_bias_load_start = %0d\n", t_bias_load_start);
        $fwrite(latency_file, "  t_bias_load_end   = %0d\n", t_bias_load_end);
        $fwrite(latency_file, "  t_img_load_start  = %0d\n", t_img_load_start);
        $fwrite(latency_file, "  t_img_load_end    = %0d\n", t_img_load_end);
        $fwrite(latency_file, "  t_layer_start     = %0d\n", t_layer_start);
        $fwrite(latency_file, "  t_first_conv_out  = %0d\n", t_first_conv_out);
        $fwrite(latency_file, "  t_last_conv_out   = %0d\n", t_last_conv_out);
        $fwrite(latency_file, "  t_first_pool_out  = %0d\n", t_first_pool_out);
        $fwrite(latency_file, "  t_last_pool_out   = %0d\n", t_last_pool_out);
        $fwrite(latency_file, "  t_layer_done      = %0d\n\n", t_layer_done_time);

        $fwrite(latency_file, "--- SETUP ---\n");
        $fwrite(latency_file, "  Weight load  : %0d ns / %0d cyc\n", wgt_load_ns,   wgt_load_cyc);
        $fwrite(latency_file, "  Bias load    : %0d ns / %0d cyc\n", bias_load_ns,  bias_load_cyc);
        $fwrite(latency_file, "  Image load   : %0d ns / %0d cyc\n", img_load_ns,   img_load_cyc);
        $fwrite(latency_file, "  Total setup  : %0d ns / %0d cyc\n\n", total_setup_ns, total_setup_cyc);

        $fwrite(latency_file, "--- CONV PHASE ---\n");
        $fwrite(latency_file, "  Start lat  : %0d ns / %0d cyc\n", conv_start_lat_ns, conv_start_lat_cyc);
        $fwrite(latency_file, "  Total dur  : %0d ns / %0d cyc\n", conv_total_ns,     conv_total_cyc);
        $fwrite(latency_file, "  Outputs    : %0d (expected %0d)\n\n",
                conv_output_count, CONV_OUT_SIZE);

        $fwrite(latency_file, "--- POOL PHASE ---\n");
        $fwrite(latency_file, "  Start lat  : %0d ns / %0d cyc\n", pool_start_lat_ns, pool_start_lat_cyc);
        $fwrite(latency_file, "  Total dur  : %0d ns / %0d cyc\n", pool_total_ns,     pool_total_cyc);
        $fwrite(latency_file, "  Outputs    : %0d (expected %0d)\n\n",
                npu_write_count, POOL_OUT_SIZE);

        $fwrite(latency_file, "--- TOTAL LAYER ---\n");
        $fwrite(latency_file, "  %0d ns / %0d cyc / %.3f us\n\n",
                total_layer_ns, total_layer_cyc, real'(total_layer_ns) / 1000.0);

        $fwrite(latency_file, "--- OUTPUT STREAM ---\n");
        $fwrite(latency_file, "  Duration   : %0d ns / %0d cyc\n", output_stream_ns, output_stream_cyc);
        $fwrite(latency_file, "  Throughput : %.4f outputs/cycle\n", output_tput);
        $fwrite(latency_file, "  Throughput : %.2f outputs/us @ %0d MHz\n\n",
                output_tput * CLK_FREQ_MHZ, CLK_FREQ_MHZ);

        $fwrite(latency_file, "--- IOI ---\n");
        if (ioi_count > 0)
            $fwrite(latency_file, "  n=%0d  min=%0d ns  max=%0d ns  avg=%.1f ns\n\n",
                    ioi_count, min_ioi, max_ioi, avg_ioi_ns);
        else
            $fwrite(latency_file, "  No intervals\n\n");

        $fwrite(latency_file, "--- EFFICIENCY ---\n");
        $fwrite(latency_file, "  Conv out/cyc : %.4f\n",  conv_efficiency);
        $fwrite(latency_file, "  Overhead cyc : %0d\n",   setup_overhead_cyc);
        $fwrite(latency_file, "  Conflicts    : %0d\n\n", conflict_count);

        $fwrite(latency_file, "--- GOLDEN COMPARISON (tolerance +/-%0d) ---\n", CMP_TOLERANCE);
        if (golden_loaded > 0) begin
            $fwrite(latency_file, "  Compared : %0d / %0d\n", cmp_total, POOL_OUT_SIZE);
            $fwrite(latency_file, "  PASS     : %0d\n", cmp_pass);
            $fwrite(latency_file, "  FAIL     : %0d\n", cmp_fail);
            if (cmp_fail == 0)
                $fwrite(latency_file, "  Result   : ALL WITHIN TOLERANCE\n\n");
            else
                $fwrite(latency_file, "  Result   : %0d OUTPUT(S) OUTSIDE TOLERANCE\n\n", cmp_fail);
        end else
            $fwrite(latency_file, "  Golden file not loaded\n\n");

        $fwrite(latency_file, "--- FIRST/LAST POOL TIMESTAMPS ---\n");
        if (pool_out_logged >= 1)
            $fwrite(latency_file, "  pool[0]   at %0d ns (cycle %0d)\n",
                    pool_out_ts[0], pool_out_ts[0] / CLK_PERIOD);
        if (pool_out_logged >= 2)
            $fwrite(latency_file, "  pool[1]   at %0d ns (cycle %0d)\n",
                    pool_out_ts[1], pool_out_ts[1] / CLK_PERIOD);
        if (pool_out_logged > 4) $fwrite(latency_file, "  ...\n");
        if (pool_out_logged >= 2) begin
            $fwrite(latency_file, "  pool[%0d] at %0d ns (cycle %0d)\n",
                    pool_out_logged-2, pool_out_ts[pool_out_logged-2],
                    pool_out_ts[pool_out_logged-2] / CLK_PERIOD);
            $fwrite(latency_file, "  pool[%0d] at %0d ns (cycle %0d)\n",
                    pool_out_logged-1, pool_out_ts[pool_out_logged-1],
                    pool_out_ts[pool_out_logged-1] / CLK_PERIOD);
        end
        $fwrite(latency_file, "\n(Full log: conv2_pool_timestamps.txt)\n");
    endtask

    // =========================================================================
    // Tasks – weight / bias / image loading
    // =========================================================================

    task automatic load_weights(input string filename,
                                input int    offset,
                                input int    count);
        int fd, i, weight_value, scan_result;
        string line;
        $display("\n[%0t] Loading weights from: %s  (full file, CONV2 window addr %0d..%0d)",
                 $time, filename, offset, offset+count-1);
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $display("  WARNING: file not found - writing random values at addr %0d..%0d",
                     offset, offset+count-1);
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
        i = 0;
        while (!$feof(fd)) begin
            scan_result = $fscanf(fd, "%h", weight_value);
            if (scan_result != 1) begin $fseek(fd,-1,1); scan_result = $fscanf(fd,"%d",weight_value); end
            if (scan_result != 1) begin
                if ($fgets(line, fd) == 0) break;
                scan_result = $sscanf(line, "%h", weight_value);
                if (scan_result != 1) scan_result = $sscanf(line, "%d", weight_value);
                if (scan_result != 1) break;
            end
            @(posedge clk);
            weight_write_addr = WGT_ADDR_W'(i);
            weight_write_data = weight_value[7:0];
            if (i >= offset && i < offset + 4)
                $display("  Weight[%0d] = %0d (0x%02h)  <-- CONV2",
                         i, $signed(weight_value[7:0]), weight_value[7:0]);
            i++;
        end
        @(posedge clk); weight_write_enable = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d total weights  (CONV2 window: addr %0d..%0d)",
                 i, offset, offset+count-1);
    endtask

    task automatic load_biases(input string filename,
                               input int    offset,
                               input int    count);
        int fd, i, bias_value, scan_result;
        $display("\n[%0t] Loading biases from: %s  (full file, CONV2 window addr %0d..%0d)",
                 $time, filename, offset, offset+count-1);
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $display("  WARNING: file not found - using zeros at addr %0d..%0d",
                     offset, offset+count-1);
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
        i = 0;
        while (!$feof(fd)) begin
            scan_result = $fscanf(fd, "%h", bias_value);
            if (scan_result != 1) break;
            @(posedge clk);
            bias_write_addr = BIAS_ADDR_W'(i);
            bias_write_data  = $signed(bias_value);
            if (i >= offset && i < offset + 4)
                $display("  Bias[%0d] = %0d (0x%08h)  <-- CONV2",
                         i, $signed(bias_value), bias_value);
            i++;
        end
        @(posedge clk); bias_write_enable = 1'b0;
        $fclose(fd);
        $display("  Loaded %0d total biases  (CONV2 window: addr %0d..%0d)",
                 i, offset, offset+count-1);
    endtask

    task automatic load_image_to_sram(input string filename);
        int fd, i, pixel_value, scan_result;
        $display("\n[%0t] Loading CONV2 input image: %s  (%0d pixels)",
                 $time, filename, INPUT_SIZE);
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
            scan_result = $fscanf(fd, "%h", pixel_value);
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
            $display("  ERROR: no pixels loaded - falling back to test pattern");
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

    // =========================================================================
    // Task – load golden reference from conv2_pool2_output.mem
    // File format: one hex byte per line (signed int8, same as .mem convention)
    // Values are stored in flat output order:
    //   addr = ch * POOL_OUT_HEIGHT * POOL_OUT_WIDTH + row * POOL_OUT_WIDTH + col
    // =========================================================================
    task automatic load_golden(input string filename);
        int fd, i, val, scan_result;
        $display("\n[%0t] Loading golden reference: %s  (%0d entries expected)",
                 $time, filename, POOL_OUT_SIZE);
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $display("  WARNING: golden file '%s' not found - comparison disabled", filename);
            golden_loaded = 0;
            return;
        end
        i = 0;
        while (!$feof(fd) && i < POOL_OUT_SIZE) begin
            scan_result = $fscanf(fd, "%h", val);
            if (scan_result == 1) begin
                golden[i] = val[7:0];
                i++;
            end
        end
        $fclose(fd);
        golden_loaded = i;
        $display("  Loaded %0d golden entries", golden_loaded);
        if (golden_loaded < POOL_OUT_SIZE)
            $display("  WARNING: only %0d entries loaded, expected %0d",
                     golden_loaded, POOL_OUT_SIZE);
        else begin
            $display("  First 4: %0d %0d %0d %0d",
                     $signed(golden[0]), $signed(golden[1]),
                     $signed(golden[2]), $signed(golden[3]));
            $display("  Last  4: %0d %0d %0d %0d",
                     $signed(golden[POOL_OUT_SIZE-4]), $signed(golden[POOL_OUT_SIZE-3]),
                     $signed(golden[POOL_OUT_SIZE-2]), $signed(golden[POOL_OUT_SIZE-1]));
        end
    endtask

    task automatic read_sram_contents(input int    start_addr,
                                      input int    count,
                                      input string filename);
        integer i, readback_file;
        logic signed [7:0] val;
        $display("\n[%0t] SRAM readback addr=%0d..%0d -> %s",
                 $time, start_addr, start_addr+count-1, filename);
        readback_file = $fopen(filename, "w");
        $fwrite(readback_file, "CONV2 SRAM Readback\n===================\n");
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

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        // Initialise all inputs
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

        // CONV2 runtime geometry
        rt_kernel_size   = $bits(rt_kernel_size)'(KERNEL_SIZE);    // 5
        rt_in_channels   = $bits(rt_in_channels)'(IN_CHANNELS);    // 6
        rt_out_channels  = $bits(rt_out_channels)'(OUT_CHANNELS);  // 16
        rt_input_height  = $bits(rt_input_height)'(INPUT_HEIGHT);  // 12
        rt_input_width   = $bits(rt_input_width)'(INPUT_WIDTH);    // 12

        // CONV2 requantization parameters
        rt_requant_scale = 32'd1177891675;
        rt_requant_shift = 6'd38;
        rt_ZP_next       = -8'sd128;

        // Layer window offsets
        weight_layer_offset = WGT_OFF_W'(WEIGHT_OFFSET);
        weight_layer_total  = WGT_TOT_W'(WEIGHT_TOTAL);
        bias_layer_offset   = BIAS_OFF_W'(BIAS_OFFSET);
        bias_layer_total    = BIAS_TOT_W'(BIAS_TOTAL);

        repeat(10) @(posedge clk);
        rst = 1'b0;
        repeat(5)  @(posedge clk);

        // Banner
        $display("========================================");
        $display("LeNet5 NPU - CONV2 Standalone Test");
        $display("========================================");
        $display("  Input : %0dx%0dx%0d = %0d pixels",
                 INPUT_HEIGHT, INPUT_WIDTH, IN_CHANNELS, INPUT_SIZE);
        $display("  Conv  : %0dx%0dx%0d = %0d outputs",
                 CONV_OUT_HEIGHT, CONV_OUT_WIDTH, OUT_CHANNELS, CONV_OUT_SIZE);
        $display("  Pool  : %0dx%0dx%0d = %0d outputs",
                 POOL_OUT_HEIGHT, POOL_OUT_WIDTH, OUT_CHANNELS, POOL_OUT_SIZE);
        $display("  Weights : offset=%0d  total=%0d", WEIGHT_OFFSET, WEIGHT_TOTAL);
        $display("  Biases  : offset=%0d  total=%0d", BIAS_OFFSET,   BIAS_TOTAL);
        $display("  Requant : scale=%0d  shift=%0d  ZP=%0d",
                 rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));
        $display("  Clock   : %0d MHz  (%0d ns period)", CLK_FREQ_MHZ, CLK_PERIOD);
        $display("  Tolerance: +/-%0d", CMP_TOLERANCE);
        $display("========================================\n");

        $fwrite(summary_file, "CONV2 Standalone Test\n");
        $fwrite(summary_file, "Input  : %0dx%0dx%0d = %0d\n",
                INPUT_HEIGHT, INPUT_WIDTH, IN_CHANNELS, INPUT_SIZE);
        $fwrite(summary_file, "Conv   : %0dx%0dx%0d = %0d\n",
                CONV_OUT_HEIGHT, CONV_OUT_WIDTH, OUT_CHANNELS, CONV_OUT_SIZE);
        $fwrite(summary_file, "Pool   : %0dx%0dx%0d = %0d\n",
                POOL_OUT_HEIGHT, POOL_OUT_WIDTH, OUT_CHANNELS, POOL_OUT_SIZE);
        $fwrite(summary_file, "Requant: scale=%0d  shift=%0d  ZP=%0d\n",
                rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));
        $fwrite(summary_file, "Tolerance: +/-%0d\n\n", CMP_TOLERANCE);

        // ---- Load data ----
        load_weights      ("all_weights.mem",          WEIGHT_OFFSET, WEIGHT_TOTAL);
        load_biases       ("all_biases_zp_fixed.mem",  BIAS_OFFSET,   BIAS_TOTAL);
        load_image_to_sram("conv1_pool1_output.mem");
        load_golden       ("conv2_pool2_output.mem");   // golden reference

        repeat(10) @(posedge clk);

        // ---- Start layer ----
        $display("\n========================================");
        $display("  Running CONV2  [CONV | ReLU=ON]");
        $display("========================================");
        $fwrite(statistics_file, "CONV2  Mode=CONV  ReLU=ON\n");
        $fwrite(statistics_file, "k=%0d  in=%0d  out=%0d  h=%0d  w=%0d\n",
                KERNEL_SIZE, IN_CHANNELS, OUT_CHANNELS, INPUT_HEIGHT, INPUT_WIDTH);

        @(posedge clk); start_layer = 1'b1;
        @(posedge clk); start_layer = 1'b0;

        $display("  Processing...");
        wait(layer_done);
        @(posedge clk);

        $display("\n  layer_done asserted at t=%0t", $time);
        $display("  Conv->pool RAM writes : %0d (expected %0d)",
                 conv_output_count, CONV_OUT_SIZE);
        $display("  NPU->SRAM writes      : %0d (expected %0d)",
                 npu_write_count,   POOL_OUT_SIZE);
        $display("  Bank conflicts        : %0d", conflict_count);

        $fwrite(statistics_file, "Conv->pool writes: %0d  (expected %0d)\n",
                conv_output_count, CONV_OUT_SIZE);
        $fwrite(statistics_file, "NPU->SRAM writes : %0d  (expected %0d)\n",
                npu_write_count,   POOL_OUT_SIZE);
        $fwrite(statistics_file, "Bank conflicts   : %0d\n", conflict_count);

        report_latency();

        repeat(20) @(posedge clk);

        // ---- SRAM readback ----
        $display("\n========================================");
        $display("SRAM Readback After CONV2");
        $display("========================================");
        read_sram_contents(0, POOL_OUT_SIZE, "conv2_sram_readback.txt");

        repeat(50) @(posedge clk);

        // ---- Summary ----
        $display("\n========================================");
        $display("CONV2 Test Complete");
        $display("========================================");

        $fwrite(summary_file, "Conv->pool : %0d (expected %0d)\n",
                conv_output_count, CONV_OUT_SIZE);
        $fwrite(summary_file, "NPU->SRAM  : %0d (expected %0d)\n",
                npu_write_count,   POOL_OUT_SIZE);
        $fwrite(summary_file, "Ext writes : %0d (expected %0d)\n",
                ext_write_count,   INPUT_SIZE);
        $fwrite(summary_file, "Conflicts  : %0d\n", conflict_count);
        $fwrite(summary_file, "Golden cmp : PASS=%0d  FAIL=%0d  (tol=+/-%0d)\n",
                cmp_pass, cmp_fail, CMP_TOLERANCE);

        if (npu_write_count == POOL_OUT_SIZE && cmp_fail == 0) begin
            $display("  RESULT: PASS  (%0d/%0d outputs, all within +/-%0d)",
                     npu_write_count, POOL_OUT_SIZE, CMP_TOLERANCE);
            $fwrite(summary_file, "RESULT: PASS\n");
        end else begin
            if (npu_write_count != POOL_OUT_SIZE)
                $display("  RESULT: FAIL  (got %0d outputs, expected %0d)",
                         npu_write_count, POOL_OUT_SIZE);
            if (cmp_fail > 0)
                $display("  RESULT: FAIL  (%0d output(s) outside tolerance +/-%0d)",
                         cmp_fail, CMP_TOLERANCE);
            $fwrite(summary_file, "RESULT: FAIL - outputs=%0d/%0d  cmp_fail=%0d\n",
                    npu_write_count, POOL_OUT_SIZE, cmp_fail);
        end

        $display("\n  Output files:");
        $display("    conv2_output_all.txt        conv2_output_hex.txt");
        $display("    conv2_output_dec.txt        conv2_statistics.txt");
        $display("    conv2_debug.txt             conv2_summary.txt");
        $display("    conv2_latency_report.txt    conv2_pool_timestamps.txt");
        $display("    conv2_sram_readback.txt     conv2_compare.txt");
        $display("========================================\n");

        $fclose(output_file);
        $fclose(output_hex_file);
        $fclose(output_dec_file);
        $fclose(statistics_file);
        $fclose(debug_file);
        $fclose(summary_file);
        $fclose(latency_file);
        $fclose(ts_file);
        $fclose(compare_file);

        $finish;
    end

    // =========================================================================
    // Timeout
    // =========================================================================
    initial begin
        #100_000_000;
        $display("[TIMEOUT] Simulation exceeded 100 ms");
        $display("  layer_done=%0b  outputs=%0d/%0d  cmp_pass=%0d  cmp_fail=%0d",
                 layer_done, output_count, POOL_OUT_SIZE, cmp_pass, cmp_fail);
        $fclose(output_file);
        $fclose(output_hex_file);
        $fclose(output_dec_file);
        $fclose(statistics_file);
        $fclose(debug_file);
        $fclose(summary_file);
        $fclose(latency_file);
        $fclose(ts_file);
        $fclose(compare_file);
        $finish;
    end

endmodule*/
`timescale 1ns/1ps

/*module tb_lenet5_conv1;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam CLK_PERIOD    = 10;      // ns  (100 MHz)
    localparam CLK_FREQ_MHZ  = 1000 / CLK_PERIOD;  // 100

    // Actual layer geometry ? driven onto runtime ports
    localparam KERNEL_SIZE   = 5;
    localparam IN_CHANNELS   = 1;
    localparam OUT_CHANNELS  = 6;
    localparam INPUT_HEIGHT  = 28;
    localparam INPUT_WIDTH   = 28;

    // MAX_* bounds ? DUT compile-time parameters
    localparam MAX_KERNEL_SIZE  = 5;
    localparam MAX_IN_CHANNELS  = 256;
    localparam MAX_OUT_CHANNELS = 120;
    localparam MAX_INPUT_HEIGHT = 28;
    localparam MAX_INPUT_WIDTH  = 28;

    // Fixed architecture params
    localparam TILE_ROWS     = 8;
    localparam ARRAY_COLS    = 8;
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

    // Port-width localparams
    localparam WGT_ADDR_W   = $clog2(TOTAL_WEIGHTS);
    localparam BIAS_ADDR_W  = $clog2(TOTAL_BIASES);
    localparam SRAM_ADDR_W  = $clog2(SRAM_TOTAL_ELEMENTS);
    localparam WGT_OFF_W    = $clog2(TOTAL_WEIGHTS+1);
    localparam WGT_TOT_W    = $clog2(MAX_WEIGHTS+1);
    localparam BIAS_OFF_W   = $clog2(TOTAL_BIASES+1);
    localparam BIAS_TOT_W   = $clog2(MAX_BIASES+1);

    // =========================================================================
    // Signals
    // =========================================================================
    logic clk, rst;
    logic start_layer, fc_mode, enable_relu, layer_done;

    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  rt_kernel_size;
    logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  rt_in_channels;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] rt_out_channels;
    logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] rt_input_height;
    logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  rt_input_width;

    logic [31:0]        rt_requant_scale;
    logic [5:0]         rt_requant_shift;
    logic signed [7:0]  rt_ZP_next;

    logic [WGT_OFF_W-1:0]  weight_layer_offset;
    logic [WGT_TOT_W-1:0]  weight_layer_total;
    logic [BIAS_OFF_W-1:0] bias_layer_offset;
    logic [BIAS_TOT_W-1:0] bias_layer_total;

    logic [WGT_ADDR_W-1:0]       weight_write_addr;
    logic signed [DATA_WIDTH-1:0] weight_write_data;
    logic                          weight_write_enable;

    logic [BIAS_ADDR_W-1:0]      bias_write_addr;
    logic signed [31:0]           bias_write_data;
    logic                          bias_write_enable;

    logic                         ext_wr_en;
    logic [SRAM_ADDR_W-1:0]      ext_wr_addr;
    logic signed [DATA_WIDTH-1:0] ext_wr_data;

    logic        sram_bank_conflict;
    // Kept as TB-side variables only ? ports removed from DUT (always 0)
    logic [31:0] sram_total_reads = 0, sram_total_writes = 0, sram_total_conflicts = 0;

    // =========================================================================
    // File handles
    // =========================================================================
    integer output_file, output_hex_file, output_dec_file;
    integer statistics_file, debug_file, summary_file;
    integer latency_file;           // latency_report.txt
    integer ts_file;                // pool_output_timestamps.txt

    // =========================================================================
    // General counters
    // =========================================================================
    integer output_count      = 0;
    integer conv_output_count = 0;
    integer ext_write_count   = 0;
    integer npu_write_count   = 0;
    integer conflict_count    = 0;

    // =========================================================================
    // LATENCY MEASUREMENT
    // =========================================================================
    // All timestamps are in simulation time units (ns for 1ns/1ps timescale).
    // We use longint (64-bit signed) so subtraction is always safe.
    //
    // Timeline (for a single layer run):
    //
    //  t_wgt_load_start
    //  |      t_wgt_load_end
    //  |      |  t_bias_load_start
    //  |      |  |    t_bias_load_end
    //  |      |  |    |  t_img_load_start
    //  |      |  |    |  |           t_img_load_end
    //  |      |  |    |  |           |  t_layer_start
    //  |      |  |    |  |           |  | t_first_conv_out
    //  |      |  |    |  |           |  | |    t_last_conv_out
    //  |      |  |    |  |           |  | |    |  t_first_pool_out
    //  |      |  |    |  |           |  | |    |  |       t_last_pool_out
    //  |      |  |    |  |           |  | |    |  |       |  t_layer_done
    //  v      v  v    v  v           v  v v    v  v       v  v
    //  ----weights----biases----------image----[LAYER RUN]----
    //
    // Derived metrics reported:
    //   img_load_cycles         = (t_img_load_end  - t_img_load_start)  / CLK_PERIOD + 1
    //   conv_start_latency      = (t_first_conv_out - t_layer_start)     / CLK_PERIOD
    //   conv_total_cycles       = (t_last_conv_out  - t_layer_start)     / CLK_PERIOD
    //   pool_start_latency      = (t_first_pool_out - t_last_conv_out)   / CLK_PERIOD
    //   pool_total_cycles       = (t_last_pool_out  - t_last_conv_out)   / CLK_PERIOD
    //   total_layer_cycles      = (t_layer_done     - t_layer_start)     / CLK_PERIOD
    //   output_stream_cycles    = (t_last_pool_out  - t_first_pool_out)  / CLK_PERIOD
    //   throughput_outputs_cyc  = POOL_OUT_SIZE / output_stream_cycles   (outputs/cycle)
    //   pipeline_efficiency     = CONV_OUT_SIZE / conv_total_cycles      (conv ops/cycle)
    //   setup_overhead_cycles   = total_layer_cycles - conv_total_cycles  (non-compute)

    // --- Weight / bias load timestamps ---
    longint t_wgt_load_start   = -1;   // first weight_write_enable posedge
    longint t_wgt_load_end     = -1;   // last  weight_write_enable posedge
    longint t_bias_load_start  = -1;   // first bias_write_enable posedge
    longint t_bias_load_end    = -1;   // last  bias_write_enable posedge

    // --- Image load timestamps ---
    longint t_img_load_start   = -1;   // first ext_wr_en posedge
    longint t_img_load_end     = -1;   // last  ext_wr_en posedge

    // --- Layer execution timestamps ---
    longint t_layer_start      = -1;   // start_layer posedge
    longint t_first_conv_out   = -1;   // first internal_fm_wr_en posedge
    longint t_last_conv_out    = -1;   // last  internal_fm_wr_en posedge
    longint t_first_pool_out   = -1;   // first npu_out_valid posedge
    longint t_last_pool_out    = -1;   // last  npu_out_valid posedge
    longint t_layer_done_time  = -1;   // layer_done posedge

    // --- Per-output timestamps (for output_stream analysis) ---
    // Stored as flat array; written to pool_output_timestamps.txt
    longint pool_out_ts [POOL_OUT_SIZE];
    integer pool_out_logged = 0;

    // --- Inter-output interval tracking ---
    longint t_prev_pool_out    = -1;
    longint max_ioi            =  0;   // max inter-output interval (ns)
    longint min_ioi            = 64'h7FFF_FFFF_FFFF_FFFF;  // min inter-output interval (ns)
    longint sum_ioi            =  0;   // sum of all intervals (for average)
    integer ioi_count          =  0;   // number of intervals measured

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT
    // =========================================================================
    lenet5_npu_sram_no_offset #(
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
        .SRAM_TOTAL_ELEMENTS (SRAM_TOTAL_ELEMENTS)
    ) dut (
        .clk                 (clk),
        .rst                 (rst),
        .start_layer         (start_layer),
        .fc_mode             (fc_mode),
        .enable_relu         (enable_relu),
        .layer_done          (layer_done),
        .kernel_size         (rt_kernel_size),
        .in_channels         (rt_in_channels),
        .out_channels        (rt_out_channels),
        .input_height        (rt_input_height),
        .input_width         (rt_input_width),
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
    );

    // =========================================================================
    // SRAM read helper
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
        output_file     = $fopen("npu_output_allxx.txt",         "w");
        output_hex_file = $fopen("npu_output_hexx.txt",          "w");
        output_dec_file = $fopen("npu_output_decx.txt",          "w");
        statistics_file = $fopen("layer_statisticsx.txt",        "w");
        debug_file      = $fopen("npu_debugx.txt",               "w");
        summary_file    = $fopen("test_summary.txt",             "w");
        latency_file    = $fopen("latency_report.txt",           "w");
        ts_file         = $fopen("pool_output_timestamps.txt",   "w");

        $fwrite(output_file,  "NPU Output Log\n==============\n\n");
        $fwrite(debug_file,   "NPU Debug Log\n=============\n\n");
        $fwrite(summary_file, "LeNet5 NPU Test Summary\n=======================\n\n");

        $fwrite(latency_file, "LeNet5 NPU Latency Report\n");
        $fwrite(latency_file, "=========================\n");
        $fwrite(latency_file, "Timescale : 1ns / 1ps\n");
        $fwrite(latency_file, "Clock     : %0d ns (%0d MHz)\n\n",
                CLK_PERIOD, CLK_FREQ_MHZ);

        $fwrite(ts_file, "Pool Output Timestamp Log\n");
        $fwrite(ts_file, "=========================\n");
        $fwrite(ts_file, "Format: #idx  addr  data  time_ns  cycle\n\n");
    end

    // =========================================================================
    // LATENCY MONITORS
    // All monitors are purely passive ? they record timestamps on signal edges
    // without interfering with simulation stimulus.
    // =========================================================================

    // --- Weight write enable: first and last active cycle ---
    always @(posedge clk) begin
        if (weight_write_enable) begin
            if (t_wgt_load_start == -1) t_wgt_load_start = $time;
            t_wgt_load_end = $time;
        end
    end

    // --- Bias write enable: first and last active cycle ---
    always @(posedge clk) begin
        if (bias_write_enable) begin
            if (t_bias_load_start == -1) t_bias_load_start = $time;
            t_bias_load_end = $time;
        end
    end

    // --- External SRAM write (image load): first and last active cycle ---
    always @(posedge clk) begin
        if (ext_wr_en) begin
            if (t_img_load_start == -1) t_img_load_start = $time;
            t_img_load_end = $time;
        end
    end

    // --- start_layer: record the cycle it goes high ---
    always @(posedge clk) begin
        if (start_layer && t_layer_start == -1)
            t_layer_start = $time;
    end

    // --- Conv outputs to pool RAM: first and last cycle ---
    always @(posedge clk) begin
        if (dut.npu.internal_fm_wr_en) begin
            if (t_first_conv_out == -1) t_first_conv_out = $time;
            t_last_conv_out = $time;
        end
    end

    // --- Pool outputs to SRAM: first, last, per-output timestamp, IOI ---
    always @(posedge clk) begin
        if (dut.npu_out_valid) begin
            automatic longint now = $time;
            // First and last
            if (t_first_pool_out == -1) t_first_pool_out = now;
            t_last_pool_out = now;
            // Per-output timestamp array and file log
            if (pool_out_logged < POOL_OUT_SIZE) begin
                pool_out_ts[pool_out_logged] = now;
                $fwrite(ts_file, "#%04d  addr=%0d  data=%0d  t=%0d ns  cycle=%0d\n",
                        pool_out_logged,
                        dut.npu_out_addr, $signed(dut.npu_out_data),
                        now, now / CLK_PERIOD);
                pool_out_logged++;
            end
            // Inter-output interval tracking
            if (t_prev_pool_out != -1) begin
                automatic longint ioi = now - t_prev_pool_out;
                if (ioi > max_ioi) max_ioi = ioi;
                if (ioi < min_ioi) min_ioi = ioi;
                sum_ioi  = sum_ioi + ioi;
                ioi_count++;
            end
            t_prev_pool_out = now;
        end
    end

    // --- layer_done: record the exact cycle ---
    always @(posedge clk) begin
        if (layer_done && t_layer_done_time == -1)
            t_layer_done_time = $time;
    end

    // =========================================================================
    // EXISTING MONITORS (unchanged)
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
    // LATENCY REPORT TASK
    // Called after layer_done. Computes all metrics and writes latency_report.txt
    // =========================================================================
    task automatic report_latency(input string layer_name);

        // Raw intervals in ns
        longint wgt_load_ns, bias_load_ns, img_load_ns;
        longint conv_start_lat_ns, conv_total_ns;
        longint pool_start_lat_ns, pool_total_ns;
        longint total_layer_ns, output_stream_ns;
        longint setup_overhead_ns;
        longint total_setup_ns;    // weight+bias+image load before start_layer

        // Cycle counts (integer division ? each CLK_PERIOD is exact)
        longint wgt_load_cyc, bias_load_cyc, img_load_cyc;
        longint conv_start_lat_cyc, conv_total_cyc;
        longint pool_start_lat_cyc, pool_total_cyc;
        longint total_layer_cyc, output_stream_cyc;
        longint setup_overhead_cyc;
        longint total_setup_cyc;

        // Throughput / efficiency
        real    output_tput;         // pool outputs / cycle
        real    conv_efficiency;     // conv outputs written / total layer cycles
        real    avg_ioi_ns;          // average inter-output interval (ns)

        // ---- Compute intervals ----
        wgt_load_ns          = (t_wgt_load_end  >= t_wgt_load_start  && t_wgt_load_start  >= 0)
                               ? t_wgt_load_end  - t_wgt_load_start  + CLK_PERIOD : 0;
        bias_load_ns         = (t_bias_load_end >= t_bias_load_start && t_bias_load_start >= 0)
                               ? t_bias_load_end - t_bias_load_start + CLK_PERIOD : 0;
        img_load_ns          = (t_img_load_end  >= t_img_load_start  && t_img_load_start  >= 0)
                               ? t_img_load_end  - t_img_load_start  + CLK_PERIOD : 0;
        conv_start_lat_ns    = (t_first_conv_out >= 0 && t_layer_start >= 0)
                               ? t_first_conv_out - t_layer_start : -1;
        conv_total_ns        = (t_last_conv_out  >= 0 && t_layer_start >= 0)
                               ? t_last_conv_out  - t_layer_start : -1;
        pool_start_lat_ns    = (t_first_pool_out >= 0 && t_last_conv_out >= 0)
                               ? t_first_pool_out - t_last_conv_out : -1;
        pool_total_ns        = (t_last_pool_out  >= 0 && t_last_conv_out >= 0)
                               ? t_last_pool_out  - t_last_conv_out : -1;
        total_layer_ns       = (t_layer_done_time >= 0 && t_layer_start >= 0)
                               ? t_layer_done_time - t_layer_start : -1;
        output_stream_ns     = (t_last_pool_out >= 0 && t_first_pool_out >= 0)
                               ? t_last_pool_out - t_first_pool_out : -1;
        setup_overhead_ns    = (total_layer_ns > 0 && conv_total_ns > 0)
                               ? total_layer_ns - conv_total_ns : -1;
        total_setup_ns       = wgt_load_ns + bias_load_ns + img_load_ns;

        // ---- Convert to cycles ----
        wgt_load_cyc         = wgt_load_ns         / CLK_PERIOD;
        bias_load_cyc        = bias_load_ns        / CLK_PERIOD;
        img_load_cyc         = img_load_ns         / CLK_PERIOD;
        conv_start_lat_cyc   = conv_start_lat_ns   / CLK_PERIOD;
        conv_total_cyc       = conv_total_ns        / CLK_PERIOD;
        pool_start_lat_cyc   = pool_start_lat_ns   / CLK_PERIOD;
        pool_total_cyc       = pool_total_ns        / CLK_PERIOD;
        total_layer_cyc      = total_layer_ns       / CLK_PERIOD;
        output_stream_cyc    = output_stream_ns     / CLK_PERIOD;
        setup_overhead_cyc   = setup_overhead_ns    / CLK_PERIOD;
        total_setup_cyc      = total_setup_ns       / CLK_PERIOD;

        // ---- Derived rates ----
        output_tput    = (output_stream_cyc > 0)
                         ? real'(POOL_OUT_SIZE) / real'(output_stream_cyc) : 0.0;
        conv_efficiency = (total_layer_cyc > 0)
                         ? real'(CONV_OUT_SIZE) / real'(total_layer_cyc) : 0.0;
        avg_ioi_ns     = (ioi_count > 0)
                         ? real'(sum_ioi) / real'(ioi_count) : 0.0;

        // ====================================================================
        // Console print
        // ====================================================================
        $display("\n????????????????????????????????????????????????????????");
        $display("?  LATENCY REPORT ? %s", layer_name);
        $display("????????????????????????????????????????????????????????");
        $display("?  Clock: %0d MHz  |  Timescale: 1ns/1ps", CLK_FREQ_MHZ);
        $display("????????????????????????????????????????????????????????");
        $display("?  SETUP PHASE (before start_layer)");
        $display("?    Weight load    : %0d ns  /  %0d cycles",  wgt_load_ns,  wgt_load_cyc);
        $display("?    Bias load      : %0d ns  /  %0d cycles",  bias_load_ns, bias_load_cyc);
        $display("?    Image load     : %0d ns  /  %0d cycles",  img_load_ns,  img_load_cyc);
        $display("?    Total setup    : %0d ns  /  %0d cycles",  total_setup_ns, total_setup_cyc);
        $display("????????????????????????????????????????????????????????");
        $display("?  CONV PHASE (from start_layer)");
        if (conv_start_lat_ns >= 0)
            $display("?    Start latency  : %0d ns  /  %0d cycles",
                     conv_start_lat_ns, conv_start_lat_cyc);
        else
            $display("?    Start latency  : N/A (no conv outputs detected)");
        if (conv_total_ns >= 0)
            $display("?    Total duration : %0d ns  /  %0d cycles",
                     conv_total_ns, conv_total_cyc);
        $display("?    Outputs written: %0d  (expected %0d)",
                 conv_output_count, CONV_OUT_SIZE);
        $display("????????????????????????????????????????????????????????");
        $display("?  POOL PHASE (from last conv output)");
        if (pool_start_lat_ns >= 0)
            $display("?    Start latency  : %0d ns  /  %0d cycles",
                     pool_start_lat_ns, pool_start_lat_cyc);
        else
            $display("?    Start latency  : N/A (no pool outputs detected)");
        if (pool_total_ns >= 0)
            $display("?    Total duration : %0d ns  /  %0d cycles",
                     pool_total_ns, pool_total_cyc);
        $display("?    Outputs written: %0d  (expected %0d)",
                 npu_write_count, POOL_OUT_SIZE);
        $display("????????????????????????????????????????????????????????");
        $display("?  TOTAL LAYER LATENCY (start_layer ? layer_done)");
        if (total_layer_ns >= 0)
            $display("?    %0d ns  /  %0d cycles  /  %.3f µs",
                     total_layer_ns, total_layer_cyc,
                     real'(total_layer_ns) / 1000.0);
        else
            $display("?    N/A (layer_done not detected)");
        $display("????????????????????????????????????????????????????????");
        $display("?  OUTPUT STREAM (first ? last pool output)");
        if (output_stream_ns >= 0) begin
            $display("?    Duration       : %0d ns  /  %0d cycles",
                     output_stream_ns, output_stream_cyc);
            $display("?    Throughput     : %.4f outputs/cycle  (%.1f outputs/µs)",
                     output_tput, output_tput * CLK_FREQ_MHZ);
        end
        $display("????????????????????????????????????????????????????????");
        $display("?  INTER-OUTPUT INTERVAL (pool outputs)");
        if (ioi_count > 0) begin
            $display("?    Samples        : %0d intervals", ioi_count);
            $display("?    Min IOI        : %0d ns  /  %0d cycles",
                     min_ioi, min_ioi / CLK_PERIOD);
            $display("?    Max IOI        : %0d ns  /  %0d cycles",
                     max_ioi, max_ioi / CLK_PERIOD);
            $display("?    Avg IOI        : %.1f ns  /  %.2f cycles",
                     avg_ioi_ns, avg_ioi_ns / CLK_PERIOD);
        end else
            $display("?    No intervals recorded (< 2 pool outputs)");
        $display("????????????????????????????????????????????????????????");
        $display("?  EFFICIENCY METRICS");
        $display("?    Conv outputs/cycle    : %.4f  (ideal = 1.0)", conv_efficiency);
        if (setup_overhead_ns >= 0)
            $display("?    Non-compute overhead : %0d cycles", setup_overhead_cyc);
        $display("?    Bank conflicts        : %0d", conflict_count);
        $display("????????????????????????????????????????????????????????");

        // ====================================================================
        // File write ? latency_report.txt
        // ====================================================================
        $fwrite(latency_file, "Layer: %s\n", layer_name);
        $fwrite(latency_file, "Geometry: kernel=%0d in_ch=%0d out_ch=%0d h=%0d w=%0d\n\n",
                KERNEL_SIZE, IN_CHANNELS, OUT_CHANNELS, INPUT_HEIGHT, INPUT_WIDTH);

        $fwrite(latency_file, "--- TIMESTAMPS (absolute simulation time, ns) ---\n");
        $fwrite(latency_file, "  t_wgt_load_start   = %0d ns\n", t_wgt_load_start);
        $fwrite(latency_file, "  t_wgt_load_end     = %0d ns\n", t_wgt_load_end);
        $fwrite(latency_file, "  t_bias_load_start  = %0d ns\n", t_bias_load_start);
        $fwrite(latency_file, "  t_bias_load_end    = %0d ns\n", t_bias_load_end);
        $fwrite(latency_file, "  t_img_load_start   = %0d ns\n", t_img_load_start);
        $fwrite(latency_file, "  t_img_load_end     = %0d ns\n", t_img_load_end);
        $fwrite(latency_file, "  t_layer_start      = %0d ns\n", t_layer_start);
        $fwrite(latency_file, "  t_first_conv_out   = %0d ns\n", t_first_conv_out);
        $fwrite(latency_file, "  t_last_conv_out    = %0d ns\n", t_last_conv_out);
        $fwrite(latency_file, "  t_first_pool_out   = %0d ns\n", t_first_pool_out);
        $fwrite(latency_file, "  t_last_pool_out    = %0d ns\n", t_last_pool_out);
        $fwrite(latency_file, "  t_layer_done       = %0d ns\n\n", t_layer_done_time);

        $fwrite(latency_file, "--- SETUP PHASE ---\n");
        $fwrite(latency_file, "  Weight load        : %0d ns  /  %0d cycles\n",
                wgt_load_ns, wgt_load_cyc);
        $fwrite(latency_file, "  Bias load          : %0d ns  /  %0d cycles\n",
                bias_load_ns, bias_load_cyc);
        $fwrite(latency_file, "  Image load         : %0d ns  /  %0d cycles\n",
                img_load_ns, img_load_cyc);
        $fwrite(latency_file, "  Total setup        : %0d ns  /  %0d cycles\n\n",
                total_setup_ns, total_setup_cyc);

        $fwrite(latency_file, "--- CONV PHASE (from start_layer) ---\n");
        $fwrite(latency_file, "  Start latency      : %0d ns  /  %0d cycles\n",
                conv_start_lat_ns, conv_start_lat_cyc);
        $fwrite(latency_file, "  Total duration     : %0d ns  /  %0d cycles\n",
                conv_total_ns, conv_total_cyc);
        $fwrite(latency_file, "  Outputs written    : %0d  (expected %0d)\n\n",
                conv_output_count, CONV_OUT_SIZE);

        $fwrite(latency_file, "--- POOL PHASE (from last conv output) ---\n");
        $fwrite(latency_file, "  Start latency      : %0d ns  /  %0d cycles\n",
                pool_start_lat_ns, pool_start_lat_cyc);
        $fwrite(latency_file, "  Total duration     : %0d ns  /  %0d cycles\n",
                pool_total_ns, pool_total_cyc);
        $fwrite(latency_file, "  Outputs written    : %0d  (expected %0d)\n\n",
                npu_write_count, POOL_OUT_SIZE);

        $fwrite(latency_file, "--- TOTAL LAYER LATENCY ---\n");
        $fwrite(latency_file, "  start_layer -> layer_done\n");
        $fwrite(latency_file, "  %0d ns  /  %0d cycles  /  %.3f µs\n\n",
                total_layer_ns, total_layer_cyc,
                real'(total_layer_ns) / 1000.0);

        $fwrite(latency_file, "--- OUTPUT STREAM (first -> last pool output) ---\n");
        $fwrite(latency_file, "  Duration           : %0d ns  /  %0d cycles\n",
                output_stream_ns, output_stream_cyc);
        $fwrite(latency_file, "  Throughput         : %.4f outputs/cycle\n",
                output_tput);
        $fwrite(latency_file, "  Throughput         : %.2f outputs/µs  @ %0d MHz\n\n",
                output_tput * CLK_FREQ_MHZ, CLK_FREQ_MHZ);

        $fwrite(latency_file, "--- INTER-OUTPUT INTERVAL ---\n");
        if (ioi_count > 0) begin
            $fwrite(latency_file, "  Samples            : %0d intervals\n", ioi_count);
            $fwrite(latency_file, "  Min                : %0d ns  /  %0d cycles\n",
                    min_ioi, min_ioi / CLK_PERIOD);
            $fwrite(latency_file, "  Max                : %0d ns  /  %0d cycles\n",
                    max_ioi, max_ioi / CLK_PERIOD);
            $fwrite(latency_file, "  Average            : %.1f ns  /  %.2f cycles\n\n",
                    avg_ioi_ns, avg_ioi_ns / CLK_PERIOD);
        end else
            $fwrite(latency_file, "  No intervals recorded\n\n");

        $fwrite(latency_file, "--- EFFICIENCY ---\n");
        $fwrite(latency_file, "  Conv outputs/cycle : %.4f\n",  conv_efficiency);
        $fwrite(latency_file, "  Non-compute cycles : %0d\n",   setup_overhead_cyc);
        $fwrite(latency_file, "  Bank conflicts     : %0d\n\n", conflict_count);

        // Write first-output and last-output timestamps from the array
        $fwrite(latency_file, "--- FIRST/LAST POOL OUTPUT TIMESTAMPS ---\n");
        if (pool_out_logged >= 1)
            $fwrite(latency_file, "  pool[0]   at %0d ns  (cycle %0d)\n",
                    pool_out_ts[0], pool_out_ts[0] / CLK_PERIOD);
        if (pool_out_logged >= 2)
            $fwrite(latency_file, "  pool[1]   at %0d ns  (cycle %0d)\n",
                    pool_out_ts[1], pool_out_ts[1] / CLK_PERIOD);
        if (pool_out_logged > 4)
            $fwrite(latency_file, "  ...\n");
        if (pool_out_logged >= 2) begin
            $fwrite(latency_file, "  pool[%0d] at %0d ns  (cycle %0d)\n",
                    pool_out_logged-2, pool_out_ts[pool_out_logged-2],
                    pool_out_ts[pool_out_logged-2] / CLK_PERIOD);
            $fwrite(latency_file, "  pool[%0d] at %0d ns  (cycle %0d)\n",
                    pool_out_logged-1, pool_out_ts[pool_out_logged-1],
                    pool_out_ts[pool_out_logged-1] / CLK_PERIOD);
        end

        $fwrite(latency_file, "\n(Full timestamp log: pool_output_timestamps.txt)\n");
    endtask

    // =========================================================================
    // Tasks: load_weights, load_biases, load_image_to_sram, configure_layer,
    //        read_sram_contents, run_layer
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
        if (scan_result != 1) break;
        @(posedge clk);
        bias_write_addr = BIAS_ADDR_W'(offset + i);
        bias_write_data  = $signed(bias_value);
        if (i < 4)
            $display("  Bias[%0d] = %0d (0x%08h)", offset+i, $signed(bias_value), bias_value);
    end
    @(posedge clk); bias_write_enable = 1'b0;
    $fclose(fd);
    $display("  Loaded %0d biases", i);
endtask

task automatic load_image_to_sram(input string filename);
    int fd, i, pixel_value, scan_result;
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

    // ---- hex-only read (matches $readmemh and image_hex.mem format) ----
    i = 0;
    ext_wr_en = 1'b1;
    while (!$feof(fd) && i < INPUT_SIZE) begin
        scan_result = $fscanf(fd, "%h", pixel_value);   // hex only
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
        $display("  ERROR: no pixels loaded - falling back to test pattern");
        ext_wr_en = 1'b1;
        for (i = 0; i < INPUT_SIZE; i++) begin
            @(posedge clk);
            ext_wr_addr = SRAM_ADDR_W'(i);
            ext_wr_data = $signed((i % 256) - 128);
        end
        @(posedge clk); ext_wr_en = 1'b0;
        i = INPUT_SIZE;
    end

    $display("  Loaded %0d pixels  (last: Pixel[%0d] = %0d)",
             i, i-1, $signed(ext_wr_data));
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

        $fwrite(statistics_file, "Cycles:              %0d\n",
                (end_time-start_time)/CLK_PERIOD);
        $fwrite(statistics_file, "Conv->pool writes:   %0d  (expected %0d)\n",
                conv_output_count - start_conv, CONV_OUT_SIZE);
        $fwrite(statistics_file, "NPU->SRAM writes:    %0d  (expected %0d)\n",
                npu_write_count - start_npu, POOL_OUT_SIZE);
        $fwrite(statistics_file, "Bank conflicts:      %0d\n",
                conflict_count - start_conflicts);

        // Call latency report after layer completes
        report_latency(layer_name);
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

        rt_kernel_size  = $bits(rt_kernel_size)'(KERNEL_SIZE);
        rt_in_channels  = $bits(rt_in_channels)'(IN_CHANNELS);
        rt_out_channels = $bits(rt_out_channels)'(OUT_CHANNELS);
        rt_input_height = $bits(rt_input_height)'(INPUT_HEIGHT);
        rt_input_width  = $bits(rt_input_width)'(INPUT_WIDTH);

        // Q16 identity requantization: (x*65536 + 32768) >> 16 = x
        rt_requant_scale = 32'd2133656752;
        rt_requant_shift = 6'd40;
        rt_ZP_next       = -128;

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
        $display("  Clock:  %0d MHz  (%0d ns period)",
                 CLK_FREQ_MHZ, CLK_PERIOD);
        $display("  Requant: scale=%0d  shift=%0d  ZP=%0d  (Q16 identity)",
                 rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));
        $display("========================================\n");

        $fwrite(summary_file, "Input:  %0dx%0dx%0d = %0d\n",
                INPUT_HEIGHT, INPUT_WIDTH, IN_CHANNELS, INPUT_SIZE);
        $fwrite(summary_file, "Conv:   %0dx%0dx%0d = %0d\n",
                CONV_OUT_HEIGHT, CONV_OUT_WIDTH, OUT_CHANNELS, CONV_OUT_SIZE);
        $fwrite(summary_file, "Pool:   %0dx%0dx%0d = %0d\n",
                POOL_OUT_HEIGHT, POOL_OUT_WIDTH, OUT_CHANNELS, POOL_OUT_SIZE);
        $fwrite(summary_file, "Clock:  %0d MHz\n", CLK_FREQ_MHZ);
        $fwrite(summary_file, "Requant: scale=%0d shift=%0d ZP=%0d\n",
                rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));

        // ---- Load weights, biases, image ----
        load_weights("all_weights.mem", 0, 150);
        load_biases ("all_biases_zp_fixed.mem",   0, 6);
        load_image_to_sram("image_hex.mem");

        repeat(10) @(posedge clk);

        // ---- Configure and run CONV1 (includes report_latency at end) ----
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
        $fwrite(summary_file, "  Ext writes: %0d\n",   ext_write_count);
        $fwrite(summary_file, "  Conflicts:  %0d\n",   conflict_count);

        if (npu_write_count == POOL_OUT_SIZE)
            $fwrite(summary_file, "  RESULT: PASS\n");
        else
            $fwrite(summary_file, "  RESULT: FAIL ? expected %0d outputs, got %0d\n",
                    POOL_OUT_SIZE, npu_write_count);

        $fclose(output_file);
        $fclose(output_hex_file);
        $fclose(output_dec_file);
        $fclose(statistics_file);
        $fclose(debug_file);
        $fclose(summary_file);
        $fclose(latency_file);
        $fclose(ts_file);

        $display("\n  Output files:");
        $display("    npu_output_allxx1.txt          npu_output_hexx.txt");
        $display("    npu_output_decx.txt           layer_statisticsx.txt");
        $display("    npu_debugx.txt                test_summary.txt");
        $display("    sram_output_readback.txt");
        $display("    latency_report.txt            pool_output_timestamps.txt");
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

  

endmodule*/
