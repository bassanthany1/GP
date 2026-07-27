module proto_fc3_top #(
    parameter COMMON_ANODE = 1
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start_n,
    output logic [6:0]  seg,
    output logic        seg_en,
    output logic        done_led
);

    logic rst;
    assign rst = ~rst_n;

   // =========================================================================
// Button debouncer for start_n (active-low)  — CORRECTED
// =========================================================================
logic [19:0] deb_cnt;
logic        deb_sync0, deb_sync1;
logic        deb_stable;   // last confirmed debounced level
logic        start_btn;

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        deb_sync0  <= 1'b1;
        deb_sync1  <= 1'b1;
        deb_stable <= 1'b1;
        deb_cnt    <= '0;
        start_btn  <= 1'b0;
    end else begin
        deb_sync0 <= start_n;
        deb_sync1 <= deb_sync0;

        start_btn <= 1'b0;

        if (deb_sync1 != deb_stable) begin
            // Input differs from confirmed stable — count up
            if (deb_cnt == 20'hFFFFF) begin
                // Held long enough — confirm new stable level
                deb_stable <= deb_sync1;
                deb_cnt    <= '0;
                // Fire one-cycle pulse on button PRESS (falling edge: 1→0)
                if (!deb_sync1)
                    start_btn <= 1'b1;
            end else begin
                deb_cnt <= deb_cnt + 1;
            end
        end else begin
            // Input matches stable — reset counter
            deb_cnt <= '0;
        end
    end
end
    // =========================================================================
    // FIX 1: All localparam widths matched to the NPU's shrunken parameters.
    //   NPU params: MAX_KERNEL_SIZE=1, MAX_IN_CHANNELS=64, MAX_OUT_CHANNELS=2
    //   MAX_INPUT_HEIGHT=2, MAX_INPUT_WIDTH=2
    //   Port widths inside NPU:
    //     kernel_size       = $clog2(1+1)  = 1 bit
    //     in_channels       = $clog2(64+1) = 7 bits
    //     out_channels      = $clog2(2+1)  = 2 bits
    //     weight_layer_offset = $clog2(128+1) = 8 bits
    //     bias_layer_offset   = $clog2(2+1)   = 2 bits
    // =========================================================================
    localparam bit [2:0]  FC3_KERNEL_SIZE   = 3'd1;   // FIX: was [2:0] 3'd1   _ [0:0] 1'd1
    localparam bit  [8:0] FC3_IN_CHANNELS   = 9'd84;  // FIX: was [8:0] 9'd84 — new model [6:0] 7'd64
    localparam bit  [6:0] FC3_OUT_CHANNELS  = 7'd10;   // FIX: was [6:0] 7'd10 — new model [1:0] 2'd2
    localparam bit [0:0]  FC3_INPUT_H = 1'd1;  // was [1:0] 2'd1
    localparam bit [0:0]  FC3_INPUT_W = 1'd1;  // was [1:0] 2'd1
    localparam bit        FC3_FC_MODE       = 1'b1;
    localparam bit        FC3_ENABLE_RELU   = 1'b0;
    localparam bit [31:0] FC3_REQUANT_SCALE = 32'd1539601606;
    localparam bit [5:0]  FC3_REQUANT_SHIFT = 6'd38;
    localparam bit signed [7:0] FC3_ZP_NEXT = 8'd26;

    localparam NUM_IMG_PORTS = 1;

    logic start_layer, layer_done;
    logic [9:0]        img_addr  [NUM_IMG_PORTS];
    logic              img_req   [NUM_IMG_PORTS];
    logic signed [7:0] img_data  [NUM_IMG_PORTS];
    logic              img_valid [NUM_IMG_PORTS];
    logic              out_valid;
    logic [15:0]       out_addr;
    logic signed [7:0] out_data;
    logic              result_ready;

    // =========================================================================
    // done_led — FIXED
    //
    // Was: assign done_led = result_ready;
    //   result_ready is a single-clock-cycle pulse (fires for 20ns @ 50MHz)
    //   -- invisible on real hardware, and appeared to be "on immediately at
    //   burn" because this board's LED is active-low (confirmed on the
    //   other prototype): logic 0 (the idle/reset value of result_ready)
    //   physically lights an active-low LED.
    //
    // Fix: latch result_ready into a sticky level (done_sticky) that:
    //   - clears on rst (LED off after reset/burn)
    //   - clears the moment a new inference starts (start_layer), so a
    //     stale "done" from a previous run doesn't linger
    //   - sets when result_ready pulses (inference just completed)
    // Then invert only at the final output assignment for the board's
    // active-low LED wiring.
    // =========================================================================
    logic done_sticky;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            done_sticky <= 1'b0;
        else if (start_layer)
            done_sticky <= 1'b0;
        else if (result_ready)
            done_sticky <= 1'b1;
    end

    assign seg_en   = 1'b0;
    assign done_led = ~done_sticky;   // active-low LED: 0=ON, so invert here

    // =========================================================================
    // 1. CONTROLLER
    // =========================================================================
    fc3_controller u_ctrl (
        .clk        (clk),
        .rst        (rst),
        .start_btn  (start_btn),
        .layer_done (layer_done),
        .start_layer(start_layer),
        .done_led   ()
    );

    // =========================================================================
    // 2. NPU CORE
    //    FIX 1: All MAX_* parameters match new model dimensions.
    //    MAX_WEIGHTS = 64*2 = 128, MAX_BIASES = 2
    // =========================================================================
    lenet5_npu_complete #(
        .MAX_KERNEL_SIZE  (1),
        .MAX_IN_CHANNELS  (84),  //64....84
        .MAX_OUT_CHANNELS (10),   //10 ....2
        .MAX_INPUT_HEIGHT (1),    //2......1
        .MAX_INPUT_WIDTH  (1),    //2......1
        .TILE_ROWS        (2),
        .ARRAY_COLS       (2),
        .DATA_WIDTH       (8),
        .NUM_IMG_PORTS    (NUM_IMG_PORTS),
        .MAX_BURST_LEN    (84),     //  64.....84
        .MAX_WEIGHTS      (840),   // FIX: 64*2=128, was 840
        .TOTAL_WEIGHTS    (840),   // FIX: same
        .MAX_BIASES       (10),     // FIX: was 10  ...2
        .TOTAL_BIASES     (10),     // FIX: was 10  ...2
        .TOTAL_ELEMENTS   (128)
    ) u_npu (
        .clk                 (clk),
        .rst                 (rst),
        .start_layer         (start_layer),
        .fc_mode             (FC3_FC_MODE),
        .enable_relu         (FC3_ENABLE_RELU),
        .layer_done          (layer_done),
        .kernel_size         (FC3_KERNEL_SIZE),
        .in_channels         (FC3_IN_CHANNELS),
        .out_channels        (FC3_OUT_CHANNELS),
        .input_height        (FC3_INPUT_H),
        .input_width         (FC3_INPUT_W),
        .requant_scale       (FC3_REQUANT_SCALE),
        .requant_shift       (FC3_REQUANT_SHIFT),
        .ZP_next             (FC3_ZP_NEXT),
        // FIX 1: widths now match $clog2(TOTAL_WEIGHTS+1) and $clog2(TOTAL_BIASES+1)
        // inside NPU = $clog2(129)=8 bits and $clog2(3)=2 bits respectively
        .weight_layer_offset (10'd0),   // FIX: was 10'd0   ...8'd0
        .bias_layer_offset   (4'd0),   // FIX: was 4'd0   ...2'd0
        .weight_write_addr   ('0),
        .weight_write_data   ('0),
        .weight_write_enable (1'b0),
        .bias_write_addr     ('0),
        .bias_write_data     ('0),
        .bias_write_enable   (1'b0),
        .img_sram_addr       (img_addr),
        .img_sram_read_req   (img_req),
        .img_sram_data       (img_data),
        .img_sram_valid      (img_valid),
        .output_valid        (out_valid),
        .output_addr         (out_addr),
        .output_data         (out_data)
    );

    // =========================================================================
    // 3. ACTIVATION ROM
    //    FIX 2: reads fc2_golden_reference_mal.mem to match the testbench SW model
    // =========================================================================
    fc2_output_rom #(
        .DATA_WIDTH (8)
    ) u_img_rom (
        .clk          (clk),
        .sram_addr    (img_addr [0]),
        .sram_read_req(img_req  [0]),
        .sram_data    (img_data [0]),
        .sram_valid   (img_valid[0])
    );
    // NOTE: fc2_output_rom must be updated to read "fc2_golden_reference_mal.mem"
    // See fc2_output_rom fix below.

    // =========================================================================
    // 4. ARGMAX + 7-SEGMENT
    //    FIX 3: NUM_CLASSES=2 so result_ready fires after class 1, not class 9
    // =========================================================================
    argmax_7seg #(
        .COMMON_ANODE (COMMON_ANODE),
        .NUM_CLASSES  (10)    // FIX: was missing (defaulted to 10) → never fired ...2
    ) u_display (
        .clk          (clk),
        .rst          (rst),
        .out_valid    (out_valid),
        .out_addr     (out_addr),
        .out_data     (out_data),
        .seg          (seg),
        .result_ready (result_ready)
    );

endmodule