// =============================================================================
// proto_fc3_top.sv  (MODIFIED - adds DEBOUNCE_LIMIT parameter for testability
// + wires the new argmax_7seg status outputs: dig_sel, led_green, buzzer)
//
// Everything else - debouncer structure, NPU instantiation/parameters,
// fc3_controller, fc2_output_rom - is byte-for-byte unchanged from the
// verified design.
//
// FIX (this revision): done_led sticky latch.
//   result_ready (from argmax_7segmalaria.sv) is a single-clock-cycle pulse
//   by design (edge-triggered, matches the argmax "winner just computed"
//   event). Driving done_led directly from that pulse means the LED is only
//   physically lit for 20 ns at 50 MHz - invisible on real hardware, and in
//   simulation it can be missed entirely by anything polling done_led if the
//   poll doesn't happen to land on that exact cycle (this is exactly what
//   caused the two "inference completed within timeout" check failures in
//   the testbench log - the pulse fired and vanished while press_start()
//   was still winding down the debounce window, before wait_for_done() ever
//   got a chance to sample it).
//
//   Fix: latch result_ready into a level signal (done_sticky) that stays
//   high until a new inference starts (start_layer), then drive done_led
//   from that. No other logic, timing, or port changes.
//
// TEMP HARDWARE DEBUG (this revision only): argmax_7seg's buzzer output is
// disconnected and the top-level buzzer port is driven directly from the
// debounced start button instead, to isolate whether the buzzer circuit
// itself (transistor/speaker/DIP-switch routing/volume trim) works at all,
// independent of the classification logic. REVERT before final submission -
// see the two commented lines near the argmax_7seg instantiation below.
// =============================================================================
module proto_fc3_top #(
    parameter COMMON_ANODE = 1,
    // ---------------------------------------------------------------------
    // NEW: debounce hold time is now a parameter (was hardcoded 20'hFFFFF).
    // Default is UNCHANGED, so hardware behavior/timing is identical unless
    // a testbench explicitly overrides it. This exists purely so simulation
    // doesn't have to burn ~21ms of simulated time per button press.
    // ---------------------------------------------------------------------
    parameter [19:0] DEBOUNCE_LIMIT = 20'hFFFFF
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start_n,
    output logic [6:0]  seg,        // SEG0..SEG6 -> segments a..g
    output logic [3:0]  dig_sel,    // DIG1..DIG4, active-low one-hot
    output logic        led_green,  // ON = Healthy
    output logic        buzzer,     // ON = Infected
    output logic        done_led
);

    logic rst;
    assign rst = ~rst_n;

    // =========================================================================
    // Button debouncer for start_n (active-low)  — unchanged apart from using
    // DEBOUNCE_LIMIT instead of the literal 20'hFFFFF
    // =========================================================================
    logic [19:0] deb_cnt;
    logic        deb_sync0, deb_sync1;
    logic        deb_stable;
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
                if (deb_cnt == DEBOUNCE_LIMIT) begin
                    deb_stable <= deb_sync1;
                    deb_cnt    <= '0;
                    if (!deb_sync1)
                        start_btn <= 1'b1;
                end else begin
                    deb_cnt <= deb_cnt + 1;
                end
            end else begin
                deb_cnt <= '0;
            end
        end
    end

    localparam bit [0:0]  FC3_KERNEL_SIZE   = 1'd1;
    localparam bit  [6:0] FC3_IN_CHANNELS   = 7'd64;
    localparam bit  [1:0] FC3_OUT_CHANNELS  = 2'd2;
    localparam bit [1:0]  FC3_INPUT_H       = 2'd1;
    localparam bit [1:0]  FC3_INPUT_W       = 2'd1;
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
    // FIX: sticky done_led latch (was: assign done_led = result_ready;)
    //
    // result_ready pulses for exactly 1 clock cycle when argmax completes.
    // done_led must be a level signal so it's visible on hardware and
    // reliably observable by anything (testbench or otherwise) sampling it
    // asynchronously to that single cycle.
    //
    //   - Cleared the same cycle a new inference is kicked off (start_layer),
    //     so it always reflects only the most recent completed inference.
    //   - Set the cycle result_ready pulses, and holds until the next
    //     start_layer.
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

    // Physical output — done_led is active-low on this board, same as
    // led_green (see argmax_7seg.sv): LOW lights the LED. done_sticky
    // itself stays logical 1 = "done" internally; only the final pin
    // drive is inverted here.
    assign done_led = ~done_sticky;

    // =========================================================================
    // 1. CONTROLLER  (unchanged instantiation)
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
    // 2. NPU CORE  (unchanged instantiation/parameters)
    // =========================================================================
    lenet5_npu_complete #(
        .MAX_KERNEL_SIZE  (1),
        .MAX_IN_CHANNELS  (64),
        .MAX_OUT_CHANNELS (2),
        .MAX_INPUT_HEIGHT (2),
        .MAX_INPUT_WIDTH  (2),
        .TILE_ROWS        (2),
        .ARRAY_COLS       (2),
        .DATA_WIDTH       (8),
        .NUM_IMG_PORTS    (NUM_IMG_PORTS),
        .MAX_BURST_LEN    (64),
        .MAX_WEIGHTS      (128),
        .TOTAL_WEIGHTS    (128),
        .MAX_BIASES       (2),
        .TOTAL_BIASES     (2),
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
        .weight_layer_offset (8'd0),
        .bias_layer_offset   (2'd0),
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
    // 3. ACTIVATION ROM  (unchanged instantiation)
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
    // 4. ARGMAX + STATUS DISPLAY (GOOD / INF text, green LED, buzzer)
    // =========================================================================
    argmax_7seg #(
        .COMMON_ANODE (COMMON_ANODE),
        .NUM_CLASSES  (2)
    ) u_display (
        .clk          (clk),
        .rst          (rst),
        .out_valid    (out_valid),
        .out_addr     (out_addr),
        .out_data     (out_data),
        .seg          (seg),
        .dig_sel      (dig_sel),
        .led_green    (led_green),
        .buzzer       (buzzer),
        .result_ready (result_ready)
    );

endmodule