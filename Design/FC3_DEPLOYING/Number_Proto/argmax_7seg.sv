
// =============================================================================
// argmax_7seg.sv  (FIXED)
//
// Fixes applied:
//   1. display_digit resets to 4'd15 (blank) instead of 4'd0.
//      This prevents "0" from appearing on the display during reset.
//      On reset the display is blank; after inference completes the
//      correct predicted digit appears and stays.
// =============================================================================

/*module argmax_7seg #(
    parameter COMMON_ANODE = 0    // Set to 1 for common-anode display (EasyFPGA A2.2)
)(
    input  logic clk,
    input  logic rst,

    // From lenet5_npu_complete output port
    input  logic        out_valid,
    input  logic [15:0] out_addr,
    input  logic signed [7:0] out_data,

    output logic [6:0]  seg,           // 7-segment segments
    output logic        result_ready   // pulses 1 cycle when argmax is done
);
    logic signed [7:0] best_val;
    logic [3:0]        best_idx;
    logic [3:0]        display_digit;

    // =========================================================================
    // Argmax logic
    // =========================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            best_val      <= 8'sh80;   // -128: most-negative signed INT8
            best_idx      <= 4'd0;
            display_digit <= 4'd15;    // FIX: was 4'd0 → showed "0" on reset
                                       // 4'd15 → blank (falls to default case)
            result_ready  <= 1'b0;
        end else begin
            result_ready <= 1'b0;      // default: deasserted

            if (out_valid && out_addr < 16'd10) begin
                // Update running argmax
                if (out_data > best_val) begin
                    best_val <= out_data;
                    best_idx <= out_addr[3:0];
                end

                // Last score (class 9) has arrived
                if (out_addr == 16'd9) begin
                    // Final check: does score 9 beat current best?
                    if (out_data > best_val)
                        display_digit <= 4'd9;
                    else
                        display_digit <= best_idx;

                    result_ready <= 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // 7-segment decoder
    // Encoding: seg = {g, f, e, d, c, b, a}  (seg[0]=a, seg[6]=g)
    // Common cathode: 1 = segment ON
    // =========================================================================
    logic [6:0] seg_cc;   // common-cathode value

    always_comb begin
        case (display_digit)
            //                gfedcba
            4'd0: seg_cc = 7'b0111111;
            4'd1: seg_cc = 7'b0000110;
            4'd2: seg_cc = 7'b1011011;
            4'd3: seg_cc = 7'b1001111;
            4'd4: seg_cc = 7'b1100110;
            4'd5: seg_cc = 7'b1101101;
            4'd6: seg_cc = 7'b1111101;
            4'd7: seg_cc = 7'b0000111;
            4'd8: seg_cc = 7'b1111111;
            4'd9: seg_cc = 7'b1101111;
            default: seg_cc = 7'b0000000; // blank - catches 4'd15 on reset
        endcase
    end

    // Invert for common-anode boards
    assign seg = COMMON_ANODE ? ~seg_cc : seg_cc;

endmodule*/
// =============================================================================
// argmax_7seg.sv  (FIXED for parameterized NUM_CLASSES)
//
// Change vs original:
//   - Added parameter NUM_CLASSES (default 10, set to 2 for new model).
//   - result_ready fires when out_addr == NUM_CLASSES-1, not hardcoded 9.
//   - display_digit reset value changed to 4'd15 (blank) so display is
//     blank after reset rather than showing "0" prematurely.
//   - argmax_7seg still shows the winning class index on the 7-segment
//     display, so digits 0-9 remain valid even with only 2 classes.
// =============================================================================

module argmax_7seg #(
    parameter COMMON_ANODE = 0,
    parameter NUM_CLASSES  = 10    // set to 10 for original 10-class model
)(
    input  logic clk,
    input  logic rst,

    input  logic        out_valid,
    input  logic [15:0] out_addr,
    input  logic signed [7:0] out_data,

    output logic [6:0]  seg,
    output logic        result_ready
);
    logic signed [7:0] best_val;
    logic [3:0]        best_idx;
    logic [3:0]        display_digit;

    // =========================================================================
    // Argmax logic
    // =========================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            best_val     <= 8'sh80;
            best_idx     <= 4'd0;
            display_digit<= 4'd15;   // blank on reset
            result_ready <= 1'b0;
        end else begin
            result_ready <= 1'b0;    // default: deasserted

            if (out_valid && out_addr < 16'(NUM_CLASSES)) begin
                // Update running argmax
                if (out_data > best_val) begin
                    best_val <= out_data;
                    best_idx <= out_addr[3:0];
                end

                // Last class has arrived — FIXED: was hardcoded 9
                if (out_addr == 16'(NUM_CLASSES - 1)) begin
                    if (out_data > best_val)
                        display_digit <= out_addr[3:0];
                    else
                        display_digit <= best_idx;

                    result_ready <= 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // 7-segment decoder
    // Encoding: seg = {g, f, e, d, c, b, a}
    // Common cathode: 1 = segment ON
    // =========================================================================
    logic [6:0] seg_cc;

    always_comb begin
        case (display_digit)
            4'd0:    seg_cc = 7'b0111111;
            4'd1:    seg_cc = 7'b0000110;
            4'd2:    seg_cc = 7'b1011011;
            4'd3:    seg_cc = 7'b1001111;
            4'd4:    seg_cc = 7'b1100110;
            4'd5:    seg_cc = 7'b1101101;
            4'd6:    seg_cc = 7'b1111101;
            4'd7:    seg_cc = 7'b0000111;
            4'd8:    seg_cc = 7'b1111111;
            4'd9:    seg_cc = 7'b1101111;
            default: seg_cc = 7'b0000000;  // blank (reset or invalid)
        endcase
    end

    assign seg = COMMON_ANODE ? ~seg_cc : seg_cc;

endmodule
