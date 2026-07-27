// =============================================================================
// argmax_7seg.sv  (MODIFIED for malaria 2-class status display)
//
// SCOPE OF CHANGE (per project constraints):
//   - The argmax accumulation logic (best_val / best_idx tracking, the
//     out_addr==NUM_CLASSES-1 winner comparison, and result_ready timing)
//     is REUSED VERBATIM from the verified 10-class version. Nothing about
//     how the winning class is computed has changed.
//   - Everything downstream of "we now know the winning class" is new:
//       * digit decoder -> 4-digit multiplexed OK / INF text
//       * added led_green output (healthy indicator)
//       * added buzzer output (infection indicator)
//   - FC3 datapath, weight/bias ROMs, systolic array, requantization,
//     layer_processor, lenet5_npu_complete are NOT touched by this file.
//
// NUM_CLASSES=2 for the malaria model: class 0 = Healthy, class 1 = Infected.
//
// OPEN ASSUMPTIONS - please verify on hardware before relying on this:
//   [A1] DIG1..DIG4 (digit-select/common lines) are assumed ACTIVE-LOW.
//        This mirrors the original design's `assign seg_en = 1'b0;` which
//        enabled the single digit by driving it low.
//   [A2] SEG0..SEG6 are assumed to map to segments a..g in that order
//        (SEG0=a, SEG1=b, ... SEG6=g). The pin table only gives pin
//        numbers, not segment letters, so this is inferred, not confirmed.
//   [A3] Buzzer (`beep`, PIN_110) is assumed ACTIVE-HIGH (same open flag
//        as previously noted for the LCD/buzzer design).
//   [A4] led_green is wired to led1 (PIN_87). The pin sheet does not label
//        LED colors - confirm led1 is actually the green LED on your board.
// =============================================================================

module argmax_7seg #(
    parameter COMMON_ANODE = 1,    // EasyFPGA A2.2 digit tube: common anode
    parameter NUM_CLASSES  = 2     // malaria model: 0 = Healthy, 1 = Infected
)(
    input  logic clk,
    input  logic rst,

    // ---- UNCHANGED interface from lenet5_npu_complete output port --------
    input  logic        out_valid,
    input  logic [15:0] out_addr,
    input  logic signed [7:0] out_data,

    // ---- NEW outputs -------------------------------------------------------
    output logic [6:0]  seg,        // segments, packed {g,f,e,d,c,b,a} (same
                                     // convention as the original decoder)
    output logic [3:0]  dig_sel,    // DIG1..DIG4, one-hot, active-low (A1)
    output logic        led_green,  // ON = Healthy
    output logic        buzzer,     // ON = Infected  (A3)
    output logic        result_ready // unchanged: pulses 1 cycle when argmax is done
);

    // =========================================================================
    // ARGMAX LOGIC -- REUSED VERBATIM (structure/timing unchanged)
    // =========================================================================
    logic signed [7:0] best_val;
    logic [3:0]         best_idx;

    // Latched final classification. Only bit 0 is meaningful for 2 classes,
    // kept as a 1-bit reg for clarity; NUM_CLASSES stays general in the
    // comparison logic in case this is ever reused for >2 classes.
    logic class_reg;     // 0 = Healthy, 1 = Infected
    logic have_result;   // 0 until the first inference completes

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            best_val     <= 8'sh80;   // -128: most-negative signed INT8
            best_idx     <= 4'd0;
            class_reg    <= 1'b0;
            have_result  <= 1'b0;
            result_ready <= 1'b0;
        end else begin
            result_ready <= 1'b0;     // default: deasserted

            if (out_valid && out_addr < 16'(NUM_CLASSES)) begin
                // Update running argmax -- unchanged
                if (out_data > best_val) begin
                    best_val <= out_data;
                    best_idx <= out_addr[3:0];
                end

                // Last class has arrived -- unchanged comparison, new action
                if (out_addr == 16'(NUM_CLASSES - 1)) begin
                    if (out_data > best_val)
                        class_reg <= out_addr[0];   // last class wins
                    else
                        class_reg <= best_idx[0];   // earlier class wins

                    have_result  <= 1'b1;
                    result_ready <= 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // STATUS OUTPUTS -- new, purely combinational from the latched result
    // =========================================================================
    // Internal logical result (1 = Healthy, matches classification meaning).
    logic led_green_active;
    assign led_green_active = have_result & ~class_reg;

    // Physical output — this board's indicator LEDs are active-low
    // (same style as the buzzer's transistor stage): LOW lights the LED.
    // Confirmed on hardware: both led_green/done_led appeared lit
    // immediately at idle (logic 0) and went dark once a real result
    // asserted logic 1.
    assign led_green = ~led_green_active;

    // =========================================================================
    // BUZZER — this board's onboard buzzer has no internal oscillator, so a
    // static DC level (confirmed on hardware) produces NO sound regardless
    // of polarity. It only sounds when the drive pin actively toggles at an
    // audible rate. This generates a continuous ~2 kHz square wave, gated on
    // only while the result is Infected (buzz_enable), and held low/idle
    // otherwise.
    // =========================================================================
    logic buzz_enable;
    assign buzz_enable = have_result & class_reg;   // Infected -> tone enabled

    logic [13:0] tone_cnt;
    logic        tone_toggle;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            tone_cnt    <= '0;
            tone_toggle <= 1'b0;
        end else if (buzz_enable) begin
            if (tone_cnt == 14'd12_499) begin   // 50MHz / 12500 ≈ 2kHz toggle rate
                tone_cnt    <= '0;
                tone_toggle <= ~tone_toggle;
            end else begin
                tone_cnt <= tone_cnt + 1'b1;
            end
        end else begin
            tone_cnt    <= '0;
            tone_toggle <= 1'b0;
        end
    end

    assign buzzer = buzz_enable & tone_toggle;

    // =========================================================================
    // CHARACTER PATTERNS (packed {g,f,e,d,c,b,a}, 1 = segment on,
    // common-cathode convention -- same style as the original decoder)
    // =========================================================================
    localparam logic [6:0] SEG_BLANK = 7'b0000000;
    localparam logic [6:0] SEG_G     = 7'b1101111;  // lowercase 'g' (digit-9 shape)
    localparam logic [6:0] SEG_o     = 7'b1011100;  // lowercase 'o'
    localparam logic [6:0] SEG_d     = 7'b1011110;  // lowercase 'd'
    localparam logic [6:0] SEG_I     = 7'b0000110;  // same shape as digit '1'
    localparam logic [6:0] SEG_N     = 7'b1010100;  // lowercase 'n' approximation
    localparam logic [6:0] SEG_F     = 7'b1110001;

    // 4-character message buffer, left-justified: pos0 pos1 pos2 pos3
    logic [6:0] char_pattern [0:3];

    always_comb begin
        if (!have_result) begin
            char_pattern[0] = SEG_BLANK;
            char_pattern[1] = SEG_BLANK;
            char_pattern[2] = SEG_BLANK;
            char_pattern[3] = SEG_BLANK;
        end else if (!class_reg) begin
            // Healthy -> "GOOD"
            char_pattern[0] = SEG_G;
            char_pattern[1] = SEG_o;
            char_pattern[2] = SEG_o;
            char_pattern[3] = SEG_d;
        end else begin
            // Infected -> "INF "
            char_pattern[0] = SEG_I;
            char_pattern[1] = SEG_N;
            char_pattern[2] = SEG_F;
            char_pattern[3] = SEG_BLANK;
        end
    end

    // =========================================================================
    // 4-DIGIT MULTIPLEX SCANNER
    // 50 MHz / 2^14 ~= 3.05 kHz digit switch rate -> ~763 Hz full-cycle
    // refresh, well above flicker threshold.
    // =========================================================================
    logic [15:0] scan_cnt;
    logic [1:0]  digit_idx;

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            scan_cnt <= '0;
        else
            scan_cnt <= scan_cnt + 1'b1;
    end

    assign digit_idx = scan_cnt[15:14];

    // Registered mux output -> avoids combinational glitching on the
    // segment/digit-select lines as digit_idx changes.
    logic [6:0] seg_cc;
    logic [3:0] dig_sel_r;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            seg_cc    <= SEG_BLANK;
            dig_sel_r <= 4'b1111;   // all digits off (active-low assumption, A1)
        end else begin
            // Logical position mapping: dig_sel bit position N always shows
            // char_pattern[N] (message position N). This is the contract
            // the testbench/spec verifies. Do NOT reverse this index --
            // any visual left/right mismatch on a given board is a PIN
            // ASSIGNMENT issue (swap which physical digit pin dig_sel[0..3]
            // connects to), not an RTL issue. See dig_sel pin assignment.
            seg_cc    <= char_pattern[digit_idx];
            dig_sel_r <= ~(4'b0001 << digit_idx);  // one-hot, active-low (A1)
        end
    end

    assign dig_sel = dig_sel_r;

    // Invert for common-anode segments (same as original)
    assign seg = COMMON_ANODE ? ~seg_cc : seg_cc;

endmodule
