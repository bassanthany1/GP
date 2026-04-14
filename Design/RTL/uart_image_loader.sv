// =============================================================================
// uart_image_loader.sv  —  FIXED & PRODUCTION-READY
//
// Fixes applied vs previous version:
//   FIX 2 — Multi-shot: after each inference result is sent back, the loader
//            automatically returns to IMG_WAIT — host can send next image
//            immediately with no reset needed
//   FIX 4 — Watchdog timeout: if UART goes silent for TIMEOUT_CYCLES clocks
//            mid-transfer, npu_error pulses HIGH for 1 cycle and the loader
//            resets itself cleanly back to IMG_WAIT
//   FIX 5 — result_valid_in / predicted_digit_in are now INPUTS — this module
//            only READS the result to transmit it back; it never drives those
//            signals, eliminating the multiple-driver conflict
//
// Normal operating sequence (repeatable, no reset needed between images):
//   1. Host waits for npu_ready HIGH  (asserted by cnn_top_synth)
//   2. Host sends exactly 784 bytes over UART (28×28, INT8, row-major)
//   3. image_loaded pulses HIGH 1 cycle → NPU starts inference
//   4. NPU finishes → result_valid_in goes HIGH (latched in cnn_top_synth)
//   5. UART TX sends back 1 byte: 0x00–0x09 = predicted digit
//   6. tx_done fires → loader returns to IMG_WAIT → ready for next image
//
// UART settings: 115200 baud, 8 data bits, no parity, 1 stop bit (8N1)
// Target clock : 100 MHz  →  CLKS_PER_BIT = 868
// =============================================================================

module uart_image_loader #(
    parameter CLK_FREQ      = 100_000_000,
    parameter BAUD_RATE     =  1_000_000,
    parameter IMAGE_PIXELS  = 784,
    parameter ADDR_WIDTH    = 10,
    parameter DATA_WIDTH    = 8,
    // Watchdog timeout: ~100 ms at 100 MHz
    // Long enough for any host, short enough to recover fast
    parameter TIMEOUT_CYCLES = 10_000_000
)(
    input  logic                   clk,
    input  logic                   rst,         // active-high synchronous

    // ── UART physical pins ──────────────────────────────────────────────────
    input  logic                   uart_rx,     // Arty A7 pin D10
    output logic                   uart_tx,     // Arty A7 pin A9

    // ── Handshake ───────────────────────────────────────────────────────────
    // Do not accept an image until both ROM loaders have finished
    input  logic                   ready,       // = w_done & b_done

    // ── Image write port → cnn_top ──────────────────────────────────────────
    output logic                   ext_wr_en,
    output logic [ADDR_WIDTH-1:0]  ext_wr_addr,
    output logic [DATA_WIDTH-1:0]  ext_wr_data,

    // Pulses HIGH for exactly 1 clock cycle after the 784th pixel is written
    // Connect directly to cnn_top.start in the wrapper
    output logic                   image_loaded,

    // FIX 4 — error flag: pulses HIGH 1 cycle on watchdog timeout
    output logic                   npu_error,

    // FIX 5 — result signals come IN from cnn_top (never driven by this module)
    input  logic                   result_valid_in,
    input  logic [3:0]             predicted_digit_in
);

    // =========================================================================
    // Derived constants
    // =========================================================================
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;    // 868

    // =========================================================================
    // ── UART RX ──────────────────────────────────────────────────────────────
    // Standard 8N1 receiver with 2-stage metastability synchronizer
    // Outputs: rx_valid (1-cycle pulse) + rx_byte
    // =========================================================================

    // Synchronizer
    logic rx_sync0, rx_sync1;
    always_ff @(posedge clk) begin
        rx_sync0 <= uart_rx;
        rx_sync1 <= rx_sync0;
    end

    typedef enum logic [1:0] {
        RX_IDLE  = 2'd0,
        RX_START = 2'd1,
        RX_DATA  = 2'd2,
        RX_STOP  = 2'd3
    } rx_state_t;

    rx_state_t             rx_state;
    logic [15:0]           rx_clk_cnt;
    logic [2:0]            rx_bit_idx;
    logic [DATA_WIDTH-1:0] rx_shift;
    logic                  rx_valid;
    logic [DATA_WIDTH-1:0] rx_byte;
 logic                  tx_done;
    always_ff @(posedge clk) begin
        if (rst) begin
            rx_state   <= RX_IDLE;
            rx_clk_cnt <= '0;
            rx_bit_idx <= '0;
            rx_shift   <= '0;
            rx_valid   <= 1'b0;
            rx_byte    <= '0;
        end else begin
            rx_valid <= 1'b0;                           // default: no new byte

            case (rx_state)

                RX_IDLE: begin
                    // Detect falling edge = UART start bit
                    if (!rx_sync1) begin
                        rx_state   <= RX_START;
                        rx_clk_cnt <= 16'(CLKS_PER_BIT / 2);   // skip to mid-bit
                    end
                end

                RX_START: begin
                    if (rx_clk_cnt == 0) begin
                        if (!rx_sync1) begin             // confirmed valid start bit
                            rx_state   <= RX_DATA;
                            rx_clk_cnt <= 16'(CLKS_PER_BIT - 1);
                            rx_bit_idx <= '0;
                        end else begin
                            rx_state   <= RX_IDLE;       // glitch, ignore
                        end
                    end else begin
                        rx_clk_cnt <= rx_clk_cnt - 1'b1;
                    end
                end

                RX_DATA: begin
                    if (rx_clk_cnt == 0) begin
                        rx_clk_cnt           <= 16'(CLKS_PER_BIT - 1);
                        rx_shift[rx_bit_idx] <= rx_sync1;       // sample LSB first
                        if (rx_bit_idx == 3'd7) begin
                            rx_state   <= RX_STOP;
                            rx_bit_idx <= '0;
                        end else begin
                            rx_bit_idx <= rx_bit_idx + 1'b1;
                        end
                    end else begin
                        rx_clk_cnt <= rx_clk_cnt - 1'b1;
                    end
                end

                RX_STOP: begin
                    if (rx_clk_cnt == 0) begin
                        rx_state <= RX_IDLE;
                        if (rx_sync1) begin              // valid stop bit
                            rx_valid <= 1'b1;
                            rx_byte  <= rx_shift;
                        end
                        // Stop bit = 0 → framing error: byte silently dropped
                        // Watchdog in image FSM will catch the resulting stall
                    end else begin
                        rx_clk_cnt <= rx_clk_cnt - 1'b1;
                    end
                end

            endcase
        end
    end

    // =========================================================================
    // ── Image Write FSM ───────────────────────────────────────────────────────
    // FIX 2: loops back to IMG_WAIT after TX completes — multi-shot
    // FIX 4: watchdog resets loader if UART stalls mid-transfer
    // =========================================================================

    typedef enum logic [1:0] {
        IMG_WAIT    = 2'd0,     // idle — waiting for ready + first UART byte
        IMG_RECEIVE = 2'd1,     // actively writing pixels to SRAM
        IMG_DONE    = 2'd2      // all pixels written, inference running, TX pending
    } img_state_t;

    img_state_t  img_state;
    logic [9:0]  pixel_cnt;
    logic [23:0] watchdog_cnt;

    always_ff @(posedge clk) begin
        if (rst) begin
            img_state    <= IMG_WAIT;
            pixel_cnt    <= '0;
            ext_wr_en    <= 1'b0;
            ext_wr_addr  <= '0;
            ext_wr_data  <= '0;
            image_loaded <= 1'b0;
            npu_error    <= 1'b0;
            watchdog_cnt <= '0;
        end else begin
            // Safe defaults — only overridden when needed
            ext_wr_en    <= 1'b0;
            image_loaded <= 1'b0;
            npu_error    <= 1'b0;

            case (img_state)

                // ── Idle: wait for NPU ready and first incoming byte ──────
                IMG_WAIT: begin
                    watchdog_cnt <= '0;
                    pixel_cnt    <= '0;
                    if (ready && rx_valid) begin
                        // Write pixel 0 immediately
                        ext_wr_en   <= 1'b1;
                        ext_wr_addr <= '0;
                        ext_wr_data <= rx_byte;
                        pixel_cnt   <= 10'd1;
                        img_state   <= IMG_RECEIVE;
                    end
                end

                // ── Collect pixels 1..783 ────────────────────────────────
                IMG_RECEIVE: begin
                    if (rx_valid) begin
                        // New byte arrived — reset watchdog and write to SRAM
                        watchdog_cnt <= '0;
                        ext_wr_en    <= 1'b1;
                        ext_wr_addr  <= pixel_cnt;
                        ext_wr_data  <= rx_byte;

                        if (pixel_cnt == 10'(IMAGE_PIXELS - 1)) begin
                            // Last pixel — trigger inference
                            image_loaded <= 1'b1;
                            img_state    <= IMG_DONE;
                        end else begin
                            pixel_cnt <= pixel_cnt + 1'b1;
                        end

                    end else begin
                        // No byte yet — tick watchdog
                        // FIX 4: fire error and self-reset on timeout
                        if (watchdog_cnt == 24'(TIMEOUT_CYCLES - 1)) begin
                            npu_error    <= 1'b1;   // 1-cycle error pulse
                            img_state    <= IMG_WAIT;
                            watchdog_cnt <= '0;
                            pixel_cnt    <= '0;
                        end else begin
                            watchdog_cnt <= watchdog_cnt + 1'b1;
                        end
                    end
                end

                // ── Inference in progress — wait for TX FSM to send result ─
                // FIX 2: tx_done brings us back here for next image
                IMG_DONE: begin
                    watchdog_cnt <= '0;
                    if (tx_done) begin
                        img_state <= IMG_WAIT;      // FIX 2: loop back — no reset needed
                    end
                end

            endcase
        end
    end

    // =========================================================================
    // ── UART TX ───────────────────────────────────────────────────────────────
    // Sends predicted_digit_in back to host as a single byte (0x00–0x09)
    // Triggered when result_valid_in is HIGH and we are in IMG_DONE state
    // FIX 5: only READS predicted_digit_in — never drives it
    // =========================================================================

    typedef enum logic [1:0] {
        TX_IDLE  = 2'd0,
        TX_START = 2'd1,
        TX_DATA  = 2'd2,
        TX_STOP  = 2'd3
    } tx_state_t;

    tx_state_t             tx_state;
    logic [15:0]           tx_clk_cnt;
    logic [2:0]            tx_bit_idx;
    logic [DATA_WIDTH-1:0] tx_shift;
       // pulses HIGH 1 cycle when stop bit done
                                       // received by IMG FSM to loop back

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_state   <= TX_IDLE;
            tx_clk_cnt <= '0;
            tx_bit_idx <= '0;
            tx_shift   <= '0;
            tx_done    <= 1'b0;
            uart_tx    <= 1'b1;        // UART bus idles HIGH
        end else begin
            tx_done <= 1'b0;           // default

            case (tx_state)

                TX_IDLE: begin
                    uart_tx <= 1'b1;
                    // Only transmit when result is ready AND inference is done
                    if (result_valid_in && (img_state == IMG_DONE)) begin
                        tx_shift   <= {4'b0000, predicted_digit_in};    // pad to 8 bits
                        tx_clk_cnt <= 16'(CLKS_PER_BIT - 1);
                        uart_tx    <= 1'b0;     // start bit = LOW
                        tx_state   <= TX_START;
                    end
                end

                TX_START: begin
                    if (tx_clk_cnt == 0) begin
                        tx_state   <= TX_DATA;
                        tx_clk_cnt <= 16'(CLKS_PER_BIT - 1);
                        tx_bit_idx <= '0;
                        uart_tx    <= tx_shift[0];      // first data bit (LSB)
                    end else begin
                        tx_clk_cnt <= tx_clk_cnt - 1'b1;
                    end
                end

                TX_DATA: begin
                    if (tx_clk_cnt == 0) begin
                        tx_clk_cnt <= 16'(CLKS_PER_BIT - 1);
                        if (tx_bit_idx == 3'd7) begin
                            uart_tx  <= 1'b1;           // stop bit = HIGH
                            tx_state <= TX_STOP;
                        end else begin
                            tx_bit_idx <= tx_bit_idx + 1'b1;
                            uart_tx    <= tx_shift[tx_bit_idx + 1];
                        end
                    end else begin
                        tx_clk_cnt <= tx_clk_cnt - 1'b1;
                    end
                end

                TX_STOP: begin
                    if (tx_clk_cnt == 0) begin
                        tx_done  <= 1'b1;   // tell IMG FSM: result sent, loop back
                        tx_state <= TX_IDLE;
                        uart_tx  <= 1'b1;
                    end else begin
                        tx_clk_cnt <= tx_clk_cnt - 1'b1;
                    end
                end

            endcase
        end
    end

endmodule
