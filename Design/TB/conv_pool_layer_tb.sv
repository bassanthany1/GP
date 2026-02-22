module tb_lenet5_verify;

    localparam CLK_PERIOD     = 10;
    localparam KERNEL_SIZE    = 2;
    localparam IN_CHANNELS    = 1;
    localparam OUT_CHANNELS   = 3;
    localparam INPUT_HEIGHT   = 5;
    localparam INPUT_WIDTH    = 5;

    localparam MAX_KERNEL_SIZE  = 5;
    localparam MAX_IN_CHANNELS  = 16;
    localparam MAX_OUT_CHANNELS = 16;
    localparam MAX_INPUT_HEIGHT = 28;
    localparam MAX_INPUT_WIDTH  = 28;

    localparam TILE_ROWS           = 8;
    localparam ARRAY_COLS          = 2;
    localparam DATA_WIDTH          = 8;
    localparam NUM_IMG_PORTS       = 5;
    localparam MAX_BURST_LEN       = 16;
    localparam MAX_WEIGHTS         = 512;
    localparam TOTAL_WEIGHTS       = 512;
    localparam MAX_BIASES          = 16;
    localparam TOTAL_BIASES        = 16;
    localparam SRAM_TOTAL_ELEMENTS = 1024;

    localparam CONV_OUT_H         = INPUT_HEIGHT - KERNEL_SIZE + 1;  // 4
    localparam CONV_OUT_W         = INPUT_WIDTH  - KERNEL_SIZE + 1;  // 4
    localparam POOL_OUT_H         = CONV_OUT_H / 2;                  // 2
    localparam POOL_OUT_W         = CONV_OUT_W / 2;                  // 2
    localparam TOTAL_POOL_OUTPUTS = POOL_OUT_H * POOL_OUT_W * OUT_CHANNELS; // 12
    localparam WEIGHTS_PER_FILTER = KERNEL_SIZE * KERNEL_SIZE;              // 4

    // =========================================================================
    // Image: 5x5
    // =========================================================================
    logic signed [7:0] image_data [0:24];
    initial begin
        image_data[0]=-3;  image_data[1]=-2;  image_data[2]=-2;
        image_data[3]=0;   image_data[4]=1;
        image_data[5]=2;   image_data[6]=3;   image_data[7]=4;
        image_data[8]=5;   image_data[9]=6;
        image_data[10]=-7; image_data[11]=-8; image_data[12]=9;
        image_data[13]=10; image_data[14]=11;
        image_data[15]=12; image_data[16]=13; image_data[17]=-14;
        image_data[18]=-15; image_data[19]=-16;
        image_data[20]=20; image_data[21]=21; image_data[22]=22;
        image_data[23]=23; image_data[24]=24;
    end

    // =========================================================================
    // Clock
    // =========================================================================
    logic clk, rst;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT ports
    // =========================================================================
    logic start_layer, fc_mode, enable_relu, layer_done;

    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  rt_kernel_size;
    logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  rt_in_channels;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] rt_out_channels;
    logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] rt_input_height;
    logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  rt_input_width;

    logic [31:0]       rt_requant_scale;
    logic [4:0]        rt_requant_shift;
    logic signed [7:0] rt_ZP_next;

    logic [$clog2(TOTAL_WEIGHTS+1)-1:0] weight_layer_offset;
    logic [$clog2(MAX_WEIGHTS+1)-1:0]   weight_layer_total;
    logic [$clog2(TOTAL_BIASES+1)-1:0]  bias_layer_offset;
    logic [$clog2(MAX_BIASES+1)-1:0]    bias_layer_total;

    logic [$clog2(TOTAL_WEIGHTS)-1:0] weight_write_addr;
    logic signed [DATA_WIDTH-1:0]     weight_write_data;
    logic                             weight_write_enable;
    logic [$clog2(TOTAL_BIASES)-1:0]  bias_write_addr;
    logic signed [31:0]               bias_write_data;
    logic                             bias_write_enable;

    logic                                   ext_wr_en;
    logic [$clog2(SRAM_TOTAL_ELEMENTS)-1:0] ext_wr_addr;
    logic signed [DATA_WIDTH-1:0]           ext_wr_data;

    logic sram_bank_conflict;
    integer output_count   = 0;
    integer conflict_count = 0;

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
    // Monitors
    // =========================================================================
    always @(posedge clk) begin
        if (dut.npu.internal_fm_wr_en)
            $display("[CONV->POOL_RAM] addr=%0d  data=%0d",
                     dut.npu.internal_fm_wr_addr,
                     $signed(dut.npu.internal_fm_wr_data));
    end

    always @(posedge clk) begin
        if (dut.sram_wr_en && !dut.ext_wr_en)
            $display("[SRAM_WRITE] addr=%0d  bank=%0d  baddr=%0d  data=%0d",
                     dut.sram_wr_addr, dut.sram_wr_addr % 5,
                     dut.sram_wr_addr / 5, $signed(dut.sram_wr_data));
    end

    always @(posedge clk) begin
        if (sram_bank_conflict) begin
            conflict_count++;
            $display("[CONFLICT] #%0d at time %0t", conflict_count, $time);
        end
    end

    // =========================================================================
    // Expected outputs [channel][row][col]
    // (See expected_math.txt for full derivation)
    //
    // Conv sum (2x2 patch sums):
    //   (0,0)=0  (0,1)=3  (0,2)=7   (0,3)=12
    //   (1,0)=-10 (1,1)=8 (1,2)=28  (1,3)=32
    //   (2,0)=10 (2,1)=0  (2,2)=-10 (2,3)=-10
    //   (3,0)=66 (3,1)=42 (3,2)=16  (3,3)=16
    //
    // F0 (x1, bias=+10): post_bias=[[10,13,17,22],[0,18,38,42],[20,10,0,0],[76,52,26,26]]
    //   pool: (0,0)=10 (0,1)=29 (1,0)=39 (1,1)=13
    //
    // F1 (x2, bias=+20): conv*2 clips at 127 for 66*2=132
    //   post_bias=[[20,26,34,44],[0,36,76,84],[40,20,0,0],[127,104,52,52]]
    //   pool: (0,0)=20 (0,1)=59 (1,0)=72 (1,1)=26
    //
    // F2 (x-1, bias=-10): post_bias=[[-10,-13,-17,-22],[0,-18,-38,-42],[-20,-10,0,0],[-76,-52,-26,-26]]
    //   pool: (0,0)=-11 (0,1)=-30 (1,0)=-40 (1,1)=-13
    // =========================================================================
    logic signed [7:0] expected [0:2][0:1][0:1];
    initial begin
        expected[0][0][0] =  10;  expected[0][0][1] =  29;
        expected[0][1][0] =  39;  expected[0][1][1] =  13;
        expected[1][0][0] =  20;  expected[1][0][1] =  59;
        expected[1][1][0] =  72;  expected[1][1][1] =  26;
        expected[2][0][0] = -11;  expected[2][0][1] = -30;
        expected[2][1][0] = -40;  expected[2][1][1] = -13;
    end

    integer pass_count = 0;
    integer fail_count = 0;

    always @(posedge clk) begin
        if (dut.npu_out_valid) begin
            automatic logic [15:0]       addr = dut.npu_out_addr;
            automatic logic signed [7:0] got  = dut.npu_out_data;
            automatic integer ch  = addr / (POOL_OUT_H * POOL_OUT_W);
            automatic integer rem = addr % (POOL_OUT_H * POOL_OUT_W);
            automatic integer row = rem  / POOL_OUT_W;
            automatic integer col = rem  % POOL_OUT_W;
            output_count++;
            if ($signed(got) === expected[ch][row][col]) begin
                $display("[PASS] #%02d  ch=%0d row=%0d col=%0d  got=%4d  expected=%4d",
                         output_count, ch, row, col,
                         $signed(got), $signed(expected[ch][row][col]));
                pass_count++;
            end else begin
                $display("[FAIL] #%02d  ch=%0d row=%0d col=%0d  got=%4d  expected=%4d  <<<",
                         output_count, ch, row, col,
                         $signed(got), $signed(expected[ch][row][col]));
                fail_count++;
            end
        end
    end

    // =========================================================================
    // Tasks
    // =========================================================================
    task automatic do_reset();
        rst = 1'b1; conflict_count = 0;
        repeat(10) @(posedge clk);
        rst = 1'b0;
        repeat(5)  @(posedge clk);
    endtask

    task automatic load_weights();
        $display("[SETUP] Loading weights: f0=all+1, f1=all+2, f2=all-1");
        weight_write_enable = 1'b1;
        for (int i = 0; i < OUT_CHANNELS * WEIGHTS_PER_FILTER; i++) begin
            automatic integer ch = i / WEIGHTS_PER_FILTER;
            weight_write_addr = i;
            case (ch)
                0: weight_write_data =  8'sd1;
                1: weight_write_data =  8'sd2;
                2: weight_write_data = -8'sd1;
                default: weight_write_data = 8'sd0;
            endcase
            @(posedge clk);
        end
        weight_write_enable = 1'b0;
        repeat(2) @(posedge clk);
    endtask

    task automatic load_biases();
        $display("[SETUP] Loading biases: [10, 20, -10]");
        bias_write_enable = 1'b1;
        @(posedge clk); bias_write_addr = 0; bias_write_data =  32'sd10;
        @(posedge clk); bias_write_addr = 1; bias_write_data =  32'sd20;
        @(posedge clk); bias_write_addr = 2; bias_write_data = -32'sd10;
        @(posedge clk);
        bias_write_enable = 1'b0;
        repeat(2) @(posedge clk);
    endtask

    task automatic load_image();
        $display("[SETUP] Loading 5x5 image:");
        $display("  row0: -3 -2 -2  0  1");
        $display("  row1:  2  3  4  5  6");
        $display("  row2: -7 -8  9 10 11");
        $display("  row3: 12 13 -14 -15 -16");
        $display("  row4: 20 21  22  23  24");
        ext_wr_en = 1'b1;
        for (int i = 0; i < INPUT_HEIGHT * INPUT_WIDTH; i++) begin
            ext_wr_addr = i;
            ext_wr_data = image_data[i];
            @(posedge clk);
        end
        ext_wr_en = 1'b0;
        repeat(5) @(posedge clk);
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        start_layer         = 1'b0;
        fc_mode             = 1'b0;
        enable_relu         = 1'b0;
        weight_write_enable = 1'b0;
        bias_write_enable   = 1'b0;
        ext_wr_en           = 1'b0;
        weight_write_addr   = '0;
        weight_write_data   = '0;
        bias_write_addr     = '0;
        bias_write_data     = '0;
        ext_wr_addr         = '0;
        ext_wr_data         = '0;

        rt_kernel_size  = $bits(rt_kernel_size)'(KERNEL_SIZE);
        rt_in_channels  = $bits(rt_in_channels)'(IN_CHANNELS);
        rt_out_channels = $bits(rt_out_channels)'(OUT_CHANNELS);
        rt_input_height = $bits(rt_input_height)'(INPUT_HEIGHT);
        rt_input_width  = $bits(rt_input_width)'(INPUT_WIDTH);

        // FIX: use Q16 scale/shift for portable identity requantization
        rt_requant_scale = 32'd65536;   // was 32'd1  — shift=0 caused 1<<(shift-1) = 1<<(-1)
        rt_requant_shift = 5'd16;       // was 5'd0
        rt_ZP_next       = 8'sd0;

        weight_layer_offset = 0;
        weight_layer_total  = OUT_CHANNELS * WEIGHTS_PER_FILTER;  // 12
        bias_layer_offset   = 0;
        bias_layer_total    = OUT_CHANNELS;                        // 3

        do_reset();
        load_weights();
        load_biases();
        load_image();

        $display("\n================================================");
        $display("  TEST: Conv + Pool");
        $display("  Image: 5x5 | Kernel: 2x2 | Filters: %0d", OUT_CHANNELS);
        $display("  kernel=%0d  in_ch=%0d  out_ch=%0d  h=%0d  w=%0d",
                 rt_kernel_size, rt_in_channels, rt_out_channels,
                 rt_input_height, rt_input_width);
        $display("  Requant: scale=%0d shift=%0d ZP=%0d (identity)",
                 rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));
        $display("  Expected pool outputs:");
        $display("    f0: (0,0)=10  (0,1)=29  (1,0)=39  (1,1)=13");
        $display("    f1: (0,0)=20  (0,1)=59  (1,0)=72  (1,1)=26");
        $display("    f2: (0,0)=-11 (0,1)=-30 (1,0)=-40 (1,1)=-13");
        $display("================================================");

        @(posedge clk); start_layer = 1'b1;
        @(posedge clk); start_layer = 1'b0;

        wait(layer_done);
        repeat(20) @(posedge clk);

        $display("\n------------------------------------------------");
        $display("  Outputs   : %0d / %0d", output_count, TOTAL_POOL_OUTPUTS);
        $display("  PASS: %0d  FAIL: %0d", pass_count, fail_count);
        if (fail_count == 0 && output_count == TOTAL_POOL_OUTPUTS)
            $display("  *** ALL PASSED ***");
        else
            $display("  *** FAILED ***");
        $display("  Conflicts : %0d", conflict_count);

        $display("\n  SRAM dump [0..%0d]:", TOTAL_POOL_OUTPUTS-1);
        for (int i = 0; i < TOTAL_POOL_OUTPUTS; i++)
            $display("    sram[%2d] = %4d  (bank=%0d baddr=%0d)",
                     i, $signed(read_sram(i)), i%5, i/5);
        $display("================================================");
        $finish;
    end

    initial begin
        #30_000_000;
        $display("[TIMEOUT] layer_done=%0b  outputs=%0d", layer_done, output_count);
        $finish;
    end

    initial begin
        $dumpfile("tb_lenet5_conv_pool.vcd");
        $dumpvars(0, tb_lenet5_verify);
    end

endmodule
