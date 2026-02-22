module tb_lenet5_fc_verify;

    // =========================================================================
    // Actual layer geometry (driven onto runtime ports)
    // =========================================================================
    localparam KERNEL_SIZE  = 1;
    localparam IN_CHANNELS  = 16;
    localparam OUT_CHANNELS = 8;
    localparam INPUT_HEIGHT = 1;
    localparam INPUT_WIDTH  = 1;

    // MAX bounds — DUT compile-time parameter sizing only
    localparam MAX_KERNEL_SIZE  = 5;
    localparam MAX_IN_CHANNELS  = 256;
    localparam MAX_OUT_CHANNELS = 120;
    localparam MAX_INPUT_HEIGHT = 28;
    localparam MAX_INPUT_WIDTH  = 28;

    // Fixed architecture params
    localparam TILE_ROWS     = 3;
    localparam ARRAY_COLS    = 8;
    localparam DATA_WIDTH    = 8;
    localparam NUM_IMG_PORTS = 5;
    localparam MAX_BURST_LEN = 32;

    localparam WINDOW_SIZE   = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS; // 16
    localparam MAX_WEIGHTS   = OUT_CHANNELS * WINDOW_SIZE;              // 128
    localparam TOTAL_WEIGHTS = MAX_WEIGHTS;
    localparam MAX_BIASES    = OUT_CHANNELS;                            // 8
    localparam TOTAL_BIASES  = MAX_BIASES;
    localparam SRAM_TOTAL_ELEMENTS = 256;
    localparam NUM_OUTPUTS   = OUT_CHANNELS;

    // =========================================================================
    // Clock
    // =========================================================================
    logic clk, rst;
    initial clk = 0;
    always #5 clk = ~clk;

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
    // SRAM read helper  (bank = addr%5, baddr = addr/5)
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

    // Monitor: NPU output writes
    always_ff @(posedge clk) begin
        if (dut.npu_out_valid)
            $display("# [FC_OUTPUT] addr=%0d  data=%0d",
                     dut.npu_out_addr, $signed(dut.npu_out_data));
    end

    // =========================================================================
    // Test data
    // =========================================================================
    logic signed [DATA_WIDTH-1:0] input_data  [IN_CHANNELS];
    logic signed [DATA_WIDTH-1:0] weight_data [OUT_CHANNELS][WINDOW_SIZE];
    logic signed [31:0]           bias_data   [OUT_CHANNELS];

    // Expected (identity requant: output = clamp(dot_product + bias,-128,127))
    //   n0: sum(+1 * [1..8,-1..-8]) = 0 + bias10  =  10
    //   n1: sum(-1 * [1..8,-1..-8]) = 0 + bias-10 = -10
    //   n2: 1*1 + 0*rest = 1 + bias5 = 6
    //   n3: sum(+1 * [1..8]) = 36 + bias0 = 36
    //   n4: sum(+1 * [-1..-8]) = -36 + bias0 = -36
    //   n5: alt +1/-1: (1-2+3-4+5-6+7-8)+(-1+2-3+4-5+6-7+8) = 0 + bias3 = 3
    //   n6: sum(+2 * [1..8,-1..-8]) = 0 + bias20 = 20
    //   n7: all-zero weights: 0 + bias100 = 100
    logic signed [7:0] expected [NUM_OUTPUTS];

    int pass_count, fail_count, output_count;

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        // ---- Build input vector ----
        for (int c = 0; c < 8; c++) input_data[c]   =  c + 1;
        for (int c = 0; c < 8; c++) input_data[c+8] = -(c + 1);

        // ---- Build weight matrix ----
        for (int e = 0; e < WINDOW_SIZE; e++) weight_data[0][e] =  1;  // n0: all +1
        for (int e = 0; e < WINDOW_SIZE; e++) weight_data[1][e] = -1;  // n1: all -1
        for (int e = 0; e < WINDOW_SIZE; e++) weight_data[2][e] =  0;  // n2: [1,0..]
        weight_data[2][0] = 1;
        for (int e = 0; e < WINDOW_SIZE; e++)                           // n3: first8=1
            weight_data[3][e] = (e < 8) ? 8'sd1 : 8'sd0;
        for (int e = 0; e < WINDOW_SIZE; e++)                           // n4: last8=1
            weight_data[4][e] = (e >= 8) ? 8'sd1 : 8'sd0;
        for (int e = 0; e < WINDOW_SIZE; e++)                           // n5: alternating
            weight_data[5][e] = (e % 2 == 0) ? 8'sd1 : -8'sd1;
        for (int e = 0; e < WINDOW_SIZE; e++) weight_data[6][e] =  2;  // n6: all +2
        for (int e = 0; e < WINDOW_SIZE; e++) weight_data[7][e] =  0;  // n7: all 0

        // ---- Biases ----
        bias_data[0]=32'sd10;  bias_data[1]=-32'sd10; bias_data[2]=32'sd5;
        bias_data[3]=32'sd0;   bias_data[4]=32'sd0;   bias_data[5]=32'sd3;
        bias_data[6]=32'sd20;  bias_data[7]=32'sd100;

        // ---- Expected ----
        expected[0]=8'sd10;  expected[1]=-8'sd10; expected[2]=8'sd6;
        expected[3]=8'sd36;  expected[4]=-8'sd36; expected[5]=8'sd3;
        expected[6]=8'sd20;  expected[7]=8'sd100;

        pass_count=0; fail_count=0; output_count=0;

        // ---- Static defaults ----
        rst                 = 1'b1;
        start_layer         = 1'b0;
        fc_mode             = 1'b0;
        enable_relu         = 1'b0;
        ext_wr_en           = 1'b0;
        ext_wr_addr         = '0;
        ext_wr_data         = '0;
        weight_write_enable = 1'b0;
        weight_write_addr   = '0;
        weight_write_data   = '0;
        bias_write_enable   = 1'b0;
        bias_write_addr     = '0;
        bias_write_data     = '0;

        rt_kernel_size  = $bits(rt_kernel_size)'(KERNEL_SIZE);
        rt_in_channels  = $bits(rt_in_channels)'(IN_CHANNELS);
        rt_out_channels = $bits(rt_out_channels)'(OUT_CHANNELS);
        rt_input_height = $bits(rt_input_height)'(INPUT_HEIGHT);
        rt_input_width  = $bits(rt_input_width)'(INPUT_WIDTH);

        // FIX 1: Q16 identity — was scale=1,shift=0 which caused 1<<(shift-1)=1<<31
        rt_requant_scale = 32'd65536;   // was 32'd1
        rt_requant_shift = 5'd16;       // was 5'd0
        rt_ZP_next       = 8'sd0;

        weight_layer_offset = 0;
        weight_layer_total  = MAX_WEIGHTS;   // 128
        bias_layer_offset   = 0;
        bias_layer_total    = MAX_BIASES;    // 8

        repeat(4) @(posedge clk);
        rst = 1'b0;
        repeat(2) @(posedge clk);

        // ---- Load input ----
        $display("# [SETUP] Loading input: ch0..7=1..8, ch8..15=-1..-8");
        ext_wr_en = 1'b1;
        for (int c = 0; c < IN_CHANNELS; c++) begin
            ext_wr_addr = c;
            ext_wr_data = input_data[c];
            @(posedge clk);
        end
        ext_wr_en = 1'b0;
        @(posedge clk);

        // ---- Load weights ----
        $display("# [SETUP] Loading weights (%0d neurons x %0d inputs)",
                 OUT_CHANNELS, WINDOW_SIZE);
        weight_write_enable = 1'b1;
        for (int oc = 0; oc < OUT_CHANNELS; oc++) begin
            for (int e = 0; e < WINDOW_SIZE; e++) begin
                weight_write_addr = oc * WINDOW_SIZE + e;
                weight_write_data = weight_data[oc][e];
                @(posedge clk);
            end
        end
        weight_write_enable = 1'b0;
        @(posedge clk);

        // ---- Load biases ----
        $display("# [SETUP] Loading biases: [10,-10,5,0,0,3,20,100]");
        bias_write_enable = 1'b1;
        for (int i = 0; i < OUT_CHANNELS; i++) begin
            bias_write_addr = i;
            bias_write_data = bias_data[i];
            @(posedge clk);
        end
        bias_write_enable = 1'b0;
        @(posedge clk);

        $display("# ================================================");
        $display("#   TEST: FC layer");
        $display("#   kernel=%0d  in_ch=%0d  out_ch=%0d  h=%0d  w=%0d",
                 rt_kernel_size, rt_in_channels, rt_out_channels,
                 rt_input_height, rt_input_width);
        $display("#   requant: scale=%0d  shift=%0d  ZP=%0d  (identity)",
                 rt_requant_scale, rt_requant_shift, $signed(rt_ZP_next));
        $display("#   Expected: [10,-10,6,36,-36,3,20,100]");
        $display("# ================================================");

        // ---- Start FC layer ----
        @(posedge clk);
        start_layer = 1'b1;
        fc_mode     = 1'b1;
        enable_relu = 1'b0;
        @(posedge clk);
        start_layer = 1'b0;

        // ---- Wait for completion ----
        fork
            begin
                @(posedge layer_done);
                $display("# [INFO] layer_done asserted at %0t", $time);
            end
            begin
                repeat(100000) @(posedge clk);
                $display("# [TIMEOUT] layer_done never asserted!");
                $finish;
            end
        join_any
        disable fork;

        repeat(10) @(posedge clk);

        // ---- Check outputs ----
        $display("# ");
        for (int i = 0; i < NUM_OUTPUTS; i++) begin
            automatic logic signed [7:0] got = read_sram(i);
            output_count++;
            if (got === expected[i]) begin
                $display("# [PASS] #%0d  neuron=%0d  got=%4d  expected=%4d",
                         output_count, i, $signed(got), $signed(expected[i]));
                pass_count++;
            end else begin
                $display("# [FAIL] #%0d  neuron=%0d  got=%4d  expected=%4d  <<<",
                         output_count, i, $signed(got), $signed(expected[i]));
                fail_count++;
            end
        end

        $display("# ");
        $display("#   PASS: %0d  FAIL: %0d", pass_count, fail_count);
        if (fail_count == 0)
            $display("#   *** ALL PASSED ***");
        else
            $display("#   *** FAILED ***");

        $display("# ");
        $display("#   SRAM dump [0..%0d]:", NUM_OUTPUTS-1);
        for (int i = 0; i < NUM_OUTPUTS; i++)
            $display("#     sram[%0d]=%4d  (bank=%0d baddr=%0d)",
                     i, $signed(read_sram(i)), i%NUM_IMG_PORTS, i/NUM_IMG_PORTS);
        $display("# =============================================");
        $finish;
    end

    initial begin
        repeat(200000) @(posedge clk);
        $display("# [WATCHDOG] Timed out after 200000 cycles");
        $finish;
    end

    // FIX 2: waveform capture — was missing in document 10
    initial begin
        $dumpfile("tb_lenet5_fc.vcd");
        $dumpvars(0, tb_lenet5_fc_verify);
    end

endmodule
