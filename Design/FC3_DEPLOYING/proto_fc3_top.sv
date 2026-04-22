/*// =============================================================================
// proto_fc3_top.sv
//
// Top-level for FC3 prototype on Cyclone IV EP4CE6.
//
// What this does:
//   1. On power-up/reset, starts FC3 inference automatically
//   2. Input: 84 INT8 activations loaded from fc2_golden_reference.mem (ROM)
//   3. Weights: 840 INT8 values from fc3_weights.mem (ROM)
//   4. Biases:  10  INT32 values from fc3_biases.mem (ROM)
//   5. Computes FC3 (84->10), requantizes, finds argmax
//   6. Displays predicted digit (0-9) on 7-segment display
//   7. Lights done_led when complete
//
// PIN ASSIGNMENTS (adjust to match your specific board in Quartus):
//   clk      -> 50 MHz oscillator pin
//   rst_n    -> active-low pushbutton (KEY0 or similar)
//   seg[6:0] -> 7-segment display segments a-g
//   seg_en   -> 7-segment digit enable (active-low common cathode)
//   done_led -> any LED
//
// Layer 4 (FC3) constants from cnn_controller.sv:
//   kernel_size   = 1
//   in_channels   = 84
//   out_channels  = 10
//   input_height  = 1
//   input_width   = 1
//   fc_mode       = 1
//   enable_relu   = 0   (no ReLU on output layer)
//   requant_scale = 32'd1539601606
//   requant_shift = 6'd38
//   ZP_next       = 8'd26
//   weight_offset = 0   (ROM starts at 0)
//   bias_offset   = 0   (ROM starts at 0)
// =============================================================================

module proto_fc3_top #(
    // Set to 1 if your board has common-anode 7-segment display
    parameter COMMON_ANODE = 1
)(
    input  logic        clk,       // 50 MHz board clock
    input  logic        rst_n,     // Active-low reset (pushbutton)

    output logic [6:0]  seg,       // 7-segment segments {g,f,e,d,c,b,a}
    output logic        seg_en,    // Digit enable (tie low to enable digit)
    output logic        done_led   // Lights when inference is complete
);

    // =========================================================================
    // Active-high internal reset
    // =========================================================================
    logic rst;
    assign rst = ~rst_n;

    // =========================================================================
    // Hardwired FC3 layer configuration (Layer 4 from cnn_controller.sv)
    // =========================================================================
    localparam bit [2:0]  FC3_KERNEL_SIZE   = 3'd1;
    localparam bit [8:0]  FC3_IN_CHANNELS   = 9'd84;
    localparam bit [6:0]  FC3_OUT_CHANNELS  = 7'd10;
    localparam bit [0:0]  FC3_INPUT_H       = 1'd1;
    localparam bit [0:0]  FC3_INPUT_W       = 1'd1;
    localparam bit        FC3_FC_MODE       = 1'b1;
    localparam bit        FC3_ENABLE_RELU   = 1'b0;
    localparam bit [31:0] FC3_REQUANT_SCALE = 32'd1539601606;
    localparam bit [5:0]  FC3_REQUANT_SHIFT = 6'd38;
    localparam bit signed [7:0] FC3_ZP_NEXT = 8'd26;

    // =========================================================================
    // lenet5_npu_complete uses NUM_IMG_PORTS = 3 unpacked arrays.
    // fc2_output_rom is single-port and is wired to port 0 only.
    // Ports 1 and 2 are tied off (read_req = 0 → data = 0, valid = 0).
    // =========================================================================
    localparam NUM_IMG_PORTS = 1;

    // Controller <-> NPU
    logic start_layer;
    logic layer_done;

    // Full 3-element arrays that lenet5_npu_complete drives
    logic [9:0]          img_addr  [NUM_IMG_PORTS];
    logic                img_req   [NUM_IMG_PORTS];
    logic signed [7:0]   img_data  [NUM_IMG_PORTS];
    logic                img_valid [NUM_IMG_PORTS];

    // NPU output
    logic                out_valid;
    logic [15:0]         out_addr;
    logic signed [7:0]   out_data;

    // =========================================================================
    // Segment enable: tie low to keep the single digit always on
    // =========================================================================
    assign seg_en = 1'b0;

    // =========================================================================
    // 1. MINI CONTROLLER
    // =========================================================================
    fc3_controller u_ctrl (
        .clk        (clk),
        .rst        (rst),
        .layer_done (layer_done),
        .start_layer(start_layer),
        .done_led   (done_led)
    );

    // =========================================================================
    // 2. NPU CORE
    //    Parameters shrunk to exact FC3 dimensions to save LUTs
    // =========================================================================
    lenet5_npu_complete #(
        .MAX_KERNEL_SIZE  (1),
        .MAX_IN_CHANNELS  (84),
        .MAX_OUT_CHANNELS (10),
        .MAX_INPUT_HEIGHT (1),
        .MAX_INPUT_WIDTH  (1),
        .TILE_ROWS        (2),
        .ARRAY_COLS       (2),
        .DATA_WIDTH       (8),
        .NUM_IMG_PORTS    (NUM_IMG_PORTS),
        .MAX_BURST_LEN    (84),
        .MAX_WEIGHTS      (840),
        .TOTAL_WEIGHTS    (840),
        .MAX_BIASES       (10),
        .TOTAL_BIASES     (10),
        .TOTAL_ELEMENTS   (128)
    ) u_npu (
        .clk                 (clk),
        .rst                 (rst),

        // Control
        .start_layer         (start_layer),
        .fc_mode             (FC3_FC_MODE),
        .enable_relu         (FC3_ENABLE_RELU),
        .layer_done          (layer_done),

        // Layer geometry
        .kernel_size         (FC3_KERNEL_SIZE),
        .in_channels         (FC3_IN_CHANNELS),
        .out_channels        (FC3_OUT_CHANNELS),
        .input_height        (FC3_INPUT_H),
        .input_width         (FC3_INPUT_W),

        // Requantization
        .requant_scale       (FC3_REQUANT_SCALE),
        .requant_shift       (FC3_REQUANT_SHIFT),
        .ZP_next             (FC3_ZP_NEXT),

        // Memory offsets - both 0 because our ROMs start at 0
        .weight_layer_offset (10'd0),
        .bias_layer_offset   (4'd0),

        // Weight/bias write ports - DISABLED
        .weight_write_addr   ('0),
        .weight_write_data   ('0),
        .weight_write_enable (1'b0),
        .bias_write_addr     ('0),
        .bias_write_data     ('0),
        .bias_write_enable   (1'b0),

        // Image SRAM interface (3-port arrays)
        .img_sram_addr       (img_addr),
        .img_sram_read_req   (img_req),
        .img_sram_data       (img_data),
        .img_sram_valid      (img_valid),

        // Output
        .output_valid        (out_valid),
        .output_addr         (out_addr),
        .output_data         (out_data)
    );

    // =========================================================================
    // 3. FC2 ACTIVATION ROM  — single-port, wired to img port 0 only
    //
    //    Port 0: driven by ROM
    //    Ports 1, 2: img_req tied to 0, img_data/img_valid held at 0
    //
    //    In FC mode im2col only ever issues requests on port 0 because
    //    in_channels=84, kernel=1x1, so window_size=84 and the streaming
    //    loop fetches one activation per cycle through port 0.
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

  

    // =========================================================================
    // 4. ARGMAX + 7-SEGMENT DISPLAY
    // =========================================================================
    argmax_7seg #(
        .COMMON_ANODE (COMMON_ANODE)
    ) u_display (
        .clk          (clk),
        .rst          (rst),
        .out_valid    (out_valid),
        .out_addr     (out_addr),
        .out_data     (out_data),
        .seg          (seg),
        .result_ready ()
    );

endmodule*/
// =============================================================================
// proto_fc3_top.sv  (FIXED)
//
// Fixes applied:
//   1. COMMON_ANODE = 1  (EasyFPGA A2.2 uses common-anode display)
//   2. MAX_INPUT_HEIGHT / MAX_INPUT_WIDTH changed from 1 to 2.
//      With 1, $clog2(1*1)=0 produces zero-width signals throughout the
//      hierarchy (processor_window_idx_start, tile_win_start, etc.) which
//      prevents the NPU from ever asserting layer_done.
//      Using 2 gives 1-bit signals everywhere and is still correct at
//      runtime because the actual geometry is passed as 1 at runtime.
//   3. display_digit reset value changed to 4'd15 (blank) so that pressing
//      reset shows a blank display instead of "0".
//   4. result_ready connected to done_led instead of fc3_controller so that
//      done_led lights exactly when the argmax result is valid.
// =============================================================================

module proto_fc3_top #(
    parameter COMMON_ANODE = 1    // EasyFPGA A2.2 is COMMON ANODE
)(
    input  logic        clk,       // 50 MHz board clock  (PIN_23)
    input  logic        rst_n,     // Active-low reset    (PIN_25)

    output logic [6:0]  seg,       // 7-segment {g,f,e,d,c,b,a}
    output logic        seg_en,    // Digit enable active-low (PIN_133 = DIG1)
    output logic        done_led   // Lights when inference result is ready (PIN_87)
);

    // =========================================================================
    // Active-high internal reset
    // =========================================================================
    logic rst;
    assign rst = ~rst_n;

    // =========================================================================
    // Hardwired FC3 layer configuration
    // =========================================================================
    localparam bit [2:0]  FC3_KERNEL_SIZE   = 3'd1;
    localparam bit [8:0]  FC3_IN_CHANNELS   = 9'd84;
    localparam bit [6:0]  FC3_OUT_CHANNELS  = 7'd10;
    localparam bit [1:0]  FC3_INPUT_H       = 2'd1;   // FIX: 2 bits (was 1 bit)
    localparam bit [1:0]  FC3_INPUT_W       = 2'd1;   // FIX: 2 bits (was 1 bit)
    localparam bit        FC3_FC_MODE       = 1'b1;
    localparam bit        FC3_ENABLE_RELU   = 1'b0;
    localparam bit [31:0] FC3_REQUANT_SCALE = 32'd1539601606;
    localparam bit [5:0]  FC3_REQUANT_SHIFT = 6'd38;
    localparam bit signed [7:0] FC3_ZP_NEXT = 8'd26;

    localparam NUM_IMG_PORTS = 1;

    // Controller <-> NPU
    logic start_layer;
    logic layer_done;

    // Image SRAM arrays
    logic [9:0]          img_addr  [NUM_IMG_PORTS];
    logic                img_req   [NUM_IMG_PORTS];
    logic signed [7:0]   img_data  [NUM_IMG_PORTS];
    logic                img_valid [NUM_IMG_PORTS];

    // NPU output
    logic                out_valid;
    logic [15:0]         out_addr;
    logic signed [7:0]   out_data;

    // result_ready from argmax - used to drive done_led
    logic result_ready;

    // =========================================================================
    // Segment enable: tie low to keep digit 1 always on (common anode: 0=ON)
    // =========================================================================
    assign seg_en  = 1'b0;

    // done_led is driven by result_ready from argmax (not fc3_controller)
    // so it lights exactly when the inference result appears on the display
    assign done_led = result_ready;

    // =========================================================================
    // 1. MINI CONTROLLER
    // =========================================================================
    fc3_controller u_ctrl (
        .clk        (clk),
        .rst        (rst),
        .layer_done (layer_done),
        .start_layer(start_layer),
        .done_led   ()             // FIX: disconnected - we use result_ready instead
    );

    // =========================================================================
    // 2. NPU CORE
    //    FIX: MAX_INPUT_HEIGHT and MAX_INPUT_WIDTH set to 2 (not 1).
    //    With value 1: $clog2(1*1)=0 → zero-width signals → NPU hangs forever.
    //    With value 2: $clog2(2*2)=2 → valid signal widths at compile time,
    //    while runtime geometry inputs still receive the correct value of 1.
    // =========================================================================
    lenet5_npu_complete #(
        .MAX_KERNEL_SIZE  (1),
        .MAX_IN_CHANNELS  (84),
        .MAX_OUT_CHANNELS (10),
        .MAX_INPUT_HEIGHT (2),    // FIX: was 1, causes $clog2(1)=0 zero-width bug
        .MAX_INPUT_WIDTH  (2),    // FIX: was 1, causes $clog2(1)=0 zero-width bug
        .TILE_ROWS        (2),
        .ARRAY_COLS       (2),
        .DATA_WIDTH       (8),
        .NUM_IMG_PORTS    (NUM_IMG_PORTS),
        .MAX_BURST_LEN    (84),
        .MAX_WEIGHTS      (840),
        .TOTAL_WEIGHTS    (840),
        .MAX_BIASES       (10),
        .TOTAL_BIASES     (10),
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

        .weight_layer_offset (10'd0),
        .bias_layer_offset   (4'd0),

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
    // 3. FC2 ACTIVATION ROM — single-port, wired to img port 0 only
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

    // =========================================================================
    // 4. ARGMAX + 7-SEGMENT DISPLAY
    //    result_ready drives done_led so LED lights exactly when result appears
    // =========================================================================
    argmax_7seg #(
        .COMMON_ANODE (COMMON_ANODE)
    ) u_display (
        .clk          (clk),
        .rst          (rst),
        .out_valid    (out_valid),
        .out_addr     (out_addr),
        .out_data     (out_data),
        .seg          (seg),
        .result_ready (result_ready)  // FIX: was unconnected
    );

endmodule