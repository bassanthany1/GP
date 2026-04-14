// =============================================================================
// cnn_top_synth.sv  —  Production-ready IP wrapper  (fully fixed)
//
// Fixes applied vs previous version:
//   FIX 1 — npu_ready output added so host knows when safe to send an image
//   FIX 2 — Multi-shot handled inside uart_image_loader (loops back automatically)
//   FIX 3 — result_valid is LATCHED here and held until next inference starts
//            Host can read it at any speed — no need to catch a 10 ns pulse
//   FIX 4 — npu_error output from uart_image_loader exposed to host
//   FIX 5 — predicted_digit / result_valid driven ONLY by cnn_top
//            uart_image_loader receives them as inputs — no multiple-driver conflict
//
// Boot sequence (fully automatic after rst deasserts):
//   ① weight_rom_loader writes 44,190 weights    (~0.44 ms  at 100 MHz)
//   ② bias_rom_loader   writes 236 biases        (  ~2.4 µs at 100 MHz)
//      ① and ② run in PARALLEL — total boot time ≈ 0.44 ms
//   ③ npu_ready goes HIGH — host may now send an image
//   ④ Host sends 784 bytes over UART
//   ⑤ image_loaded pulses HIGH 1 cycle → cnn_top.start triggered
//   ⑥ NPU runs all 5 LeNet-5 layers
//   ⑦ cnn_top asserts result_valid for 1 cycle → latched here as result_valid_lat
//   ⑧ uart_image_loader detects result_valid_lat → sends 1 byte back to host
//   ⑨ tx_done fires → uart_image_loader resets → ready for next image (go to ④)
//
// Host interface summary:
//   INPUTS  from host: clk, rst, uart_rx
//   OUTPUTS to  host : uart_tx, npu_ready, npu_error,
//                      predicted_digit, result_valid_lat,
//                      inference_done, current_layer, sram_bank_conflict
//
// Arty A7 pin map:
//   clk                  → E3   (100 MHz oscillator)
//   rst                  → D9   (BTN0, active-high)
//   uart_rx              → D10  (USB-UART RX via FT2232)
//   uart_tx              → A9   (USB-UART TX via FT2232)
//   predicted_digit[3:0] → H5 J5 T9 T10  (LD3–LD0)
//   result_valid_lat     → F6   (LD4 green — stays ON until next image)
//   inference_done       → J2   (LD5 green)
//   npu_ready            → G6   (LD4 blue  — ON once weights are loaded)
//   npu_error            → H6   (LD5 blue  — flashes on UART timeout)
//   current_layer[2:0]   → K1 R2 T1  (LD6–LD7 blue + spare)
//   sram_bank_conflict   → R3   (LD7)
// =============================================================================

module cnn_top_synth (
    input  logic        clk,                    // 100 MHz
    input  logic        rst,                    // active-high synchronous reset

    // ── UART (USB-UART bridge, no extra hardware needed on Arty A7) ──────────
    input  logic        uart_rx,                // D10
    output logic        uart_tx,                // A9

    // ── Host status outputs ──────────────────────────────────────────────────
    output logic        npu_ready,              // FIX 1: HIGH when safe to send image
    output logic        npu_error,              // FIX 4: pulses on UART watchdog timeout

    // ── Inference results ────────────────────────────────────────────────────
    output logic [3:0]  predicted_digit,        // 0–9 binary encoded
    output logic        result_valid_lat,       // FIX 3: latched HIGH, stays until next image
    output logic        inference_done,         // HIGH after all 5 layers complete
    output logic [2:0]  current_layer,          // which layer is running (0–4)
    output logic        sram_bank_conflict      // debug: SRAM bank collision flag
);

    // =========================================================================
    // Internal wires
    // =========================================================================

    // Weight ROM loader → cnn_top
    logic [15:0] w_addr;
    logic [7:0]  w_data;
    logic        w_en;
    logic        w_done;

    // Bias ROM loader → cnn_top
    logic [7:0]  b_addr;
    logic [31:0] b_data;
    logic        b_en;
    logic        b_done;

    // UART image loader → cnn_top
    logic [9:0]  i_addr;
    logic [7:0]  i_data;
    logic        i_en;
    logic        image_loaded;      // 1-cycle pulse → cnn_top.start

    // cnn_top → result (raw 1-cycle pulse from NPU)
    logic        result_valid_pulse;
    logic [3:0]  digit_raw;

    // =========================================================================
    // FIX 1 — npu_ready: both ROM loaders must be done before accepting images
    // =========================================================================
    assign npu_ready = w_done & b_done;

    // =========================================================================
    // FIX 3 — Latch result_valid
    // result_valid_pulse from cnn_top lasts exactly 1 clock cycle (10 ns at
    // 100 MHz) — far too short for any host to reliably read.
    // We latch it here so it stays HIGH until the next inference starts.
    // Cleared by: rst OR image_loaded (new inference beginning)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst || image_loaded) begin
            result_valid_lat <= 1'b0;       // clear at reset or new inference
        end else if (result_valid_pulse) begin
            result_valid_lat <= 1'b1;       // latch and hold
        end
    end

    // =========================================================================
    // 1. Weight ROM Loader
    //    Auto-runs after reset. Reads weights.mem ($readmemh at synthesis).
    //    Writes 44,190 INT8 weights into cnn_top's weight SRAM.
    //    Takes ~44,190 clock cycles = ~0.44 ms at 100 MHz.
    // =========================================================================
    weight_rom_loader #(
        .TOTAL_WEIGHTS  (44190),
        .ADDR_WIDTH     (16),
        .DATA_WIDTH     (8)
    ) u_weight_rom (
        .clk                 (clk),
        .rst                 (rst),
        .weight_write_addr   (w_addr),
        .weight_write_data   (w_data),
        .weight_write_enable (w_en),
        .loading_done        (w_done)
    );

    // =========================================================================
    // 2. Bias ROM Loader
    //    Auto-runs after reset in parallel with weight loader.
    //    Reads biases.mem. Writes 236 INT32 biases.
    //    Takes ~236 clock cycles = ~2.4 µs — finishes long before weights.
    // =========================================================================
    bias_rom_loader #(
        .TOTAL_BIASES   (236),
        .ADDR_WIDTH     (8),
        .DATA_WIDTH     (32)
    ) u_bias_rom (
        .clk               (clk),
        .rst               (rst),
        .bias_write_addr   (b_addr),
        .bias_write_data   (b_data),
        .bias_write_enable (b_en),
        .loading_done      (b_done)
    );

    // =========================================================================
    // 3. UART Image Loader  (fully fixed)
    //    - Waits for npu_ready before accepting any bytes
    //    - Receives 784 bytes, writes to SRAM, pulses image_loaded
    //    - Sends predicted_digit back to host as 1 UART byte
    //    - Automatically resets for next image after TX completes (FIX 2)
    //    - Watchdog fires npu_error if UART stalls mid-transfer (FIX 4)
    //    - Reads result as INPUT — never drives predicted_digit (FIX 5)
    // =========================================================================
    uart_image_loader #(
        .CLK_FREQ        (100_000_000),
        .BAUD_RATE       ( 1_000_000),
        .IMAGE_PIXELS    (784),
        .ADDR_WIDTH      (10),
        .DATA_WIDTH      (8),
        .TIMEOUT_CYCLES  (10_000_000)   // 100 ms watchdog
    ) u_uart (
        .clk                  (clk),
        .rst                  (rst),
        .uart_rx              (uart_rx),
        .uart_tx              (uart_tx),
        .ready                (npu_ready ),
        .ext_wr_en            (i_en),
        .ext_wr_addr          (i_addr),
        .ext_wr_data          (i_data),
        .image_loaded         (image_loaded),
        .npu_error            (npu_error),
        // FIX 5: pass latched result IN — uart_image_loader reads, never drives
        .result_valid_in      (result_valid_lat),
        .predicted_digit_in   (digit_raw)
    );

    // =========================================================================
    // 4. LeNet-5 NPU core  —  cnn_top is COMPLETELY UNCHANGED
    //    All fixes are in the wrapper — the IP core itself is never touched
    // =========================================================================
    cnn_top u_cnn (
        .clk                  (clk),
        .rst                  (rst),
        .start                (image_loaded),       // auto-triggered after image load

        // Weights (driven by ROM loader)
        .weight_write_addr    (w_addr),
        .weight_write_data    (w_data),
        .weight_write_enable  (w_en),

        // Biases (driven by ROM loader)
        .bias_write_addr      (b_addr),
        .bias_write_data      (b_data),
        .bias_write_enable    (b_en),

        // Image pixels (driven by UART loader)
        .ext_wr_en            (i_en),
        .ext_wr_addr          (i_addr),
        .ext_wr_data          (i_data),

        // FIX 5: ONLY cnn_top drives these — no other module touches them
        .predicted_digit      (digit_raw),
        .result_valid         (result_valid_pulse),
        .inference_done       (inference_done),
        .current_layer        (current_layer),
        .sram_bank_conflict   (sram_bank_conflict)
    );

    // Expose the digit directly (latching is handled for result_valid above)
    assign predicted_digit = digit_raw;

endmodule
