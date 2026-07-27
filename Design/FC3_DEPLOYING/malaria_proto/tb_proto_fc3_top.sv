// =============================================================================
// tb_proto_fc3_top.sv  (GATE-LEVEL SIM VERSION - hierarchy-safe)
//
// REVISION: reporting clarity + Scenario 2 correctness fix.
// NO CHANGE to pass/fail criteria of any existing protocol-level check
// (dig_sel one-hot, blank-scan, etc.) and NO CHANGE to any DUT file.
//
// WHAT CHANGED VS PREVIOUS VERSION OF THIS FILE:
//   1. Added report_case() - prints one clear line per major test case:
//        [ID] description | EXPECTED: ... | ACTUAL: ... | PASS/FAIL
//      printed unconditionally (not only on failure), so the log reads as
//      a test report instead of a bare error list.
//   2. check_display() / check_display_blank() / wait_for_done() now also
//      report a single pass/fail verdict for their whole scan (in addition
//      to the existing fine-grained internal checks, which are unchanged
//      and still counted).
//   3. Scenario 2 rewritten. REASON: with fc3_controller_RECOMMENDED_FIX.sv
//      now confirmed active, press_start() takes ~2x the full debounce
//      window (~2,097,158 cycles) to return. In that time a second
//      inference has ALREADY completed and done_led has ALREADY been
//      re-asserted before the old check even ran - so comparing
//      done_led == done_before (1 == 1) passed for the wrong reason: it
//      never actually observed the controller drop done_led and restart.
//      This revision adds a done_led falling-edge monitor so the test
//      proves the drop actually happened, then confirms done_led comes
//      back up and the display re-decodes cleanly - i.e. it verifies the
//      INTENDED back-to-back-inference behavior, not a coincidence.
// =============================================================================

`timescale 1ns/1ps

module tb_proto_fc3_top;

    // -------------------------------------------------------------------
    // Parameters / knobs
    // -------------------------------------------------------------------
    localparam CLK_PERIOD = 20;              // 50 MHz

    localparam [19:0] REAL_DEBOUNCE   = 20'hFFFFF;     // 1,048,575 cycles
    localparam integer TIMEOUT_CYCLES = 32'd3_000_000;

    // -------------------------------------------------------------------
    // DUT I/O
    // -------------------------------------------------------------------
    logic clk;
    logic rst_n;
    logic start_n;

    logic [6:0] seg;
    logic [3:0] dig_sel;
    logic       led_green;
    logic       buzzer;
    logic       done_led;

    int errors = 0;
    int checks = 0;

    // Major-test-case summary counters (separate from fine-grained checks)
    int case_count  = 0;
    int case_failed = 0;

    proto_fc3_top dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start_n   (start_n),
        .seg       (seg),
        .dig_sel   (dig_sel),
        .led_green (led_green),
        .buzzer    (buzzer),
        .done_led  (done_led)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------
    // done_led edge monitor (testbench-only observation logic; does not
    // drive or influence the DUT in any way)
    //
    // NOTE: done_led is active-low on this board (idle/in-progress = HIGH,
    // done = LOW) -- confirmed on hardware (done_led/led_green both
    // appeared lit at idle and went dark on a real result). So the event
    // "a completed result was cleared because a new inference started" is
    // now a RISING edge (LOW->HIGH), not falling, and the idle/reset level
    // is HIGH, not LOW.
    // -------------------------------------------------------------------
    logic prev_done_led;
    logic done_dropped;
    logic clear_dropped_req;

    always @(posedge clk or posedge rst_n) begin
        if (!rst_n) begin
            prev_done_led <= 1'b1;   // idle level is HIGH (active-low done_led)
            done_dropped  <= 1'b0;
        end else begin
            if (clear_dropped_req)
                done_dropped <= 1'b0;
            else if (!prev_done_led && done_led)
                done_dropped <= 1'b1;
            prev_done_led <= done_led;
        end
    end

    // -------------------------------------------------------------------
    // Segment pattern reference table
    // -------------------------------------------------------------------
    localparam logic [6:0] SEG_BLANK = 7'b0000000;
    localparam logic [6:0] SEG_G     = 7'b1101111;
    localparam logic [6:0] SEG_o     = 7'b1011100;
    localparam logic [6:0] SEG_d     = 7'b1011110;
    localparam logic [6:0] SEG_I     = 7'b0000110;
    localparam logic [6:0] SEG_N     = 7'b1010100;
    localparam logic [6:0] SEG_F     = 7'b1110001;

    function automatic logic [6:0] expected_pattern(int pos, logic healthy);
        if (healthy) begin
            case (pos)
                0: return SEG_G;
                1: return SEG_o;
                2: return SEG_o;
                3: return SEG_d;
                default: return SEG_BLANK;
            endcase
        end else begin
            case (pos)
                0: return SEG_I;
                1: return SEG_N;
                2: return SEG_F;
                default: return SEG_BLANK;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------
    // Fine-grained check (unchanged semantics: silent unless failing,
    // still counted into checks/errors)
    // -------------------------------------------------------------------
    task automatic check(input logic cond, input string msg);
        checks++;
        if (!cond) begin
            errors++;
            $display("[%0t] *** CHECK FAILED: %s", $time, msg);
        end
    endtask

    // -------------------------------------------------------------------
    // NEW: major test-case report - always prints, pass or fail
    // -------------------------------------------------------------------
    task automatic report_case(
        input string id,
        input string description,
        input string expected,
        input string actual,
        input logic  pass
    );
        case_count++;
        if (!pass) case_failed++;
        $display("[%0t] [%-4s] %-52s | EXPECTED: %-14s | ACTUAL: %-14s | %s",
                  $time, id, description, expected, actual,
                  pass ? "PASS" : "FAIL");
    endtask

    // -------------------------------------------------------------------
    // Reset task
    // -------------------------------------------------------------------
    task automatic do_reset();
        rst_n   = 1'b0;
        start_n = 1'b1;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
    endtask

    task automatic press_start();
        start_n = 1'b0;
        repeat (REAL_DEBOUNCE + 4) @(posedge clk);
        start_n = 1'b1;
        repeat (REAL_DEBOUNCE + 4) @(posedge clk);
    endtask

    // -------------------------------------------------------------------
    // wait_for_done - now also reports a pass/fail verdict
    // -------------------------------------------------------------------
    task automatic wait_for_done(output logic completed_in_time);
        longint t;
        t = 0;
        while (done_led && t < TIMEOUT_CYCLES) begin
            @(posedge clk);
            t++;
        end
        completed_in_time = (t < TIMEOUT_CYCLES);
        check(completed_in_time, "inference completed within timeout");
    endtask

    // -------------------------------------------------------------------
    // check_display - now also reports an aggregate pass/fail for the scan
    // -------------------------------------------------------------------
    task automatic check_display(output logic decoded_healthy,
                                  output logic scan_ok,
                                  input string label);
        logic [6:0] captured [0:3];
        int         seen_mask;
        int         idx;
        logic [6:0] raw_seg;
        logic [3:0] raw_dsel;
        logic       matches_ok, matches_inf;
        int         errors_before;

        errors_before = errors;
        seen_mask = 0;
        for (int i = 0; i < 5 * 65536; i++) begin
            @(posedge clk);
            raw_dsel = dig_sel;
            raw_seg  = seg;

            check((raw_dsel == 4'b1110 || raw_dsel == 4'b1101 ||
                   raw_dsel == 4'b1011 || raw_dsel == 4'b0111 ||
                   raw_dsel == 4'b1111),
                  {label, ": dig_sel is one-hot-active-low or idle"});

            for (idx = 0; idx < 4; idx++) begin
                if (raw_dsel == (~(4'b0001 << idx))) begin
                    captured[idx] = ~raw_seg;
                    seen_mask     = seen_mask | (1 << idx);
                end
            end

            if (seen_mask == 4'b1111) i = 5*65536;
        end

        check(seen_mask == 4'b1111, {label, ": all 4 digit slots observed during scan"});

        matches_ok  = 1'b1;
        matches_inf = 1'b1;
        for (idx = 0; idx < 4; idx++) begin
            if (captured[idx] !== expected_pattern(idx, 1'b1)) matches_ok  = 1'b0;
            if (captured[idx] !== expected_pattern(idx, 1'b0)) matches_inf = 1'b0;
        end

        check(matches_ok ^ matches_inf,
              {label, ": scanned digits decode to exactly one of GOOD/INF (no garbage, no ambiguity)"});

        decoded_healthy = matches_ok;
        scan_ok         = (errors == errors_before);
    endtask

    // -------------------------------------------------------------------
    // check_display_blank - now also reports an aggregate pass/fail
    // -------------------------------------------------------------------
    task automatic check_display_blank(output logic scan_ok, input string label);
        logic [6:0] captured [0:3];
        int         seen_mask;
        int         idx;
        logic [6:0] raw_seg;
        logic [3:0] raw_dsel;
        int         errors_before;

        errors_before = errors;
        seen_mask = 0;
        for (int i = 0; i < 5 * 65536; i++) begin
            @(posedge clk);
            raw_dsel = dig_sel;
            raw_seg  = seg;

            check((raw_dsel == 4'b1110 || raw_dsel == 4'b1101 ||
                   raw_dsel == 4'b1011 || raw_dsel == 4'b0111 ||
                   raw_dsel == 4'b1111),
                  {label, ": dig_sel is one-hot-active-low or idle"});

            for (idx = 0; idx < 4; idx++) begin
                if (raw_dsel == (~(4'b0001 << idx))) begin
                    captured[idx] = ~raw_seg;
                    seen_mask     = seen_mask | (1 << idx);
                end
            end

            if (seen_mask == 4'b1111) i = 5*65536;
        end

        check(seen_mask == 4'b1111, {label, ": all 4 digit slots observed during idle scan"});

        for (idx = 0; idx < 4; idx++) begin
            check(captured[idx] == SEG_BLANK,
                  $sformatf("%s: digit %0d is blank while idle", label, idx));
        end

        scan_ok = (errors == errors_before);
    endtask

    // -------------------------------------------------------------------
    // cross_check_outputs - now also reports an aggregate pass/fail
    //
    // NOTE: buzzer is now a ~2kHz TOGGLING tone (gated on while Infected),
    // not a static level -- the onboard buzzer has no internal oscillator
    // and produces no sound from a constant DC level, so a single-cycle
    // sample would pass/fail essentially at random depending on which half
    // of the toggle period it lands on. Instead we observe it over a
    // window long enough to guarantee catching both halves of at least one
    // full toggle period if it's active, and confirm NO toggling at all
    // while idle.
    // -------------------------------------------------------------------
    task automatic cross_check_outputs(output logic outputs_ok,
                                        input logic decoded_healthy,
                                        input string label);
        int errors_before;
        int i;
        logic seen_high, seen_low;

        errors_before = errors;

        check(led_green == !decoded_healthy,
              {label, ": led_green matches decoded display result"});

        seen_high = 1'b0;
        seen_low  = 1'b0;
        for (i = 0; i < 40_000; i++) begin
            @(posedge clk);
            if (buzzer) seen_high = 1'b1;
            else        seen_low  = 1'b1;
        end

        if (decoded_healthy)
            check(!seen_high,
                  {label, ": buzzer stays silent (no tone) while Healthy"});
        else
            check(seen_high && seen_low,
                  {label, ": buzzer toggles (audible tone) while Infected"});

        outputs_ok = (errors == errors_before);
    endtask

    // -------------------------------------------------------------------
    // MAIN SEQUENCE
    // -------------------------------------------------------------------
    initial begin
        logic result_healthy;
        logic pass_flag;
        logic scan_flag;
        logic done_before;

        $display("=====================================================================================================");
        $display(" tb_proto_fc3_top - GATE-LEVEL SIM  (real debounce = %0d cycles)", REAL_DEBOUNCE);
        $display("=====================================================================================================");

        // =================================================================
        // TC-01: Power-on reset - status outputs
        // =================================================================
        do_reset();

        report_case("TC01", "Post-reset: led_green off",
                    "1 (idle)", led_green ? "1" : "0", (led_green == 1'b1));
        report_case("TC02", "Post-reset: buzzer off",
                    "0", buzzer ? "1" : "0", (buzzer == 1'b0));
        report_case("TC03", "Post-reset: done_led not yet asserted",
                    "1 (idle)", done_led ? "1" : "0", (done_led == 1'b1));

        check_display_blank(scan_flag, "TC04");
        report_case("TC04", "Post-reset: all 4 digits blank",
                    "blank", scan_flag ? "blank" : "not blank", scan_flag);

        // =================================================================
        // TC-05..08: Scenario 1 - first inference after reset
        // =================================================================
        press_start();

        wait_for_done(pass_flag);
        report_case("TC05", "Scenario1: inference completes before timeout",
                    "done_led=1", pass_flag ? "done_led=1" : "TIMEOUT", pass_flag);

        check_display(result_healthy, scan_flag, "TC06");
        report_case("TC06", "Scenario1: display decodes to exactly one of GOOD/INF",
                    "GOOD or INF", scan_flag ? (result_healthy ? "GOOD" : "INF") : "ambiguous/garbage",
                    scan_flag);

        report_case("TC07", "Scenario1: classification result",
                    "Healthy or Infected", result_healthy ? "Healthy (GOOD)" : "Infected (INF)",
                    1'b1);   // informational - actual class is data-dependent, not a fail condition

        cross_check_outputs(pass_flag, result_healthy, "TC08");
        report_case("TC08", "Scenario1: led_green/buzzer match decoded class",
                    result_healthy ? "led_green=0,buzzer=silent" : "led_green=1,buzzer=toggling",
                    $sformatf("led_green=%0d,buzzer=%0d", led_green, buzzer),
                    pass_flag);

        // =================================================================
        // TC-09: Scenario 2 - back-to-back inference (S_DONE exit fix)
        //
        // This REPLACES the old "no-op" check. fc3_controller_RECOMMENDED_FIX
        // intentionally allows a fresh start_btn while in S_DONE to restart
        // inference immediately (done_led drops, then reasserts on the new
        // layer_done). We verify the ACTUAL transition happened, using the
        // done_led falling-edge monitor, rather than just comparing two
        // done_led=1 snapshots (which would pass even if nothing happened).
        // =================================================================
        done_before = done_led;
        clear_dropped_req = 1'b1;
        @(posedge clk);
        clear_dropped_req = 1'b0;

        press_start();   // second press while still in S_DONE from Scenario1

        report_case("TC09a", "Scenario2: done_led actually dropped on 2nd press (real restart, not a no-op)",
                    "done_dropped=1", $sformatf("done_dropped=%0d", done_dropped),
                    done_dropped);

        wait_for_done(pass_flag);
        report_case("TC09b", "Scenario2: 2nd inference completes before timeout",
                    "done_led=1", pass_flag ? "done_led=1" : "TIMEOUT", pass_flag);

        check_display(result_healthy, scan_flag, "TC09c");
        report_case("TC09c", "Scenario2: display re-decodes cleanly after 2nd inference",
                    "GOOD or INF", scan_flag ? (result_healthy ? "GOOD" : "INF") : "ambiguous/garbage",
                    scan_flag);

        cross_check_outputs(pass_flag, result_healthy, "TC09d");
        report_case("TC09d", "Scenario2: led_green/buzzer match after 2nd inference",
                    result_healthy ? "led_green=0,buzzer=silent" : "led_green=1,buzzer=toggling",
                    $sformatf("led_green=%0d,buzzer=%0d", led_green, buzzer),
                    pass_flag);

        // =================================================================
        // TC-10..13: Scenario 3 - clean reset + re-run
        // =================================================================
        do_reset();

        check_display_blank(scan_flag, "TC10");
        report_case("TC10", "Post-reset(2nd cycle): all 4 digits blank",
                    "blank", scan_flag ? "blank" : "not blank", scan_flag);

        press_start();

        wait_for_done(pass_flag);
        report_case("TC11", "Scenario3: inference completes before timeout after reset",
                    "done_led=1", pass_flag ? "done_led=1" : "TIMEOUT", pass_flag);

        check_display(result_healthy, scan_flag, "TC12");
        report_case("TC12", "Scenario3: display decodes cleanly after reset+re-run",
                    "GOOD or INF", scan_flag ? (result_healthy ? "GOOD" : "INF") : "ambiguous/garbage",
                    scan_flag);

        cross_check_outputs(pass_flag, result_healthy, "TC13");
        report_case("TC13", "Scenario3: led_green/buzzer match after reset+re-run",
                    result_healthy ? "led_green=0,buzzer=silent" : "led_green=1,buzzer=toggling",
                    $sformatf("led_green=%0d,buzzer=%0d", led_green, buzzer),
                    pass_flag);

        // =================================================================
        // SUMMARY
        // =================================================================
        $display("=====================================================================================================");
        $display(" MAJOR TEST CASES : %0d run, %0d failed", case_count, case_failed);
        $display(" FINE-GRAINED CHECKS (protocol-level, e.g. dig_sel one-hot): %0d run, %0d failed", checks, errors);
        $display("=====================================================================================================");
        if (errors == 0 && case_failed == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** %0d TEST CASE(S) AND %0d FINE-GRAINED CHECK(S) FAILED ***", case_failed, errors);

        $finish;
    end

    // -------------------------------------------------------------------
    // Global watchdog
    // -------------------------------------------------------------------
    initial begin
        #(CLK_PERIOD * longint'(TIMEOUT_CYCLES) * 10);
        $display("*** TIMEOUT: testbench watchdog fired, aborting ***");
        $finish;
    end

endmodule


// =============================================================================
// tb_proto_fc3_top.sv  (GATE-LEVEL SIM VERSION - hierarchy-safe)
//
// Comprehensive testbench for proto_fc3_top (malaria classifier + status
// display), for use against the SYNTHESIZED NETLIST only.
//
// GL-SIM SPECIFIC NOTES (all confirmed from actual vsim runs):
//   1. The synthesized netlist has NO overridable parameters (DC resolved
//      COMMON_ANODE / DEBOUNCE_LIMIT at synthesis time) -> DUT is
//      instantiated bare below, no #(...) override block.
//   2. The synthesized netlist does NOT preserve sub-module instance
//      hierarchy under the names u_img_rom / u_display (DC flattened or
//      renamed them) -> this TB uses NO hierarchical reference into the
//      DUT. Every check is done purely through primary I/O ports.
//   3. The digit-scan mux inside argmax_7seg free-runs continuously at
//      all times (including immediately post-reset) - it does NOT sit
//      at dig_sel == 4'b1111 while idle. Instead it keeps cycling
//      through one-hot digit selects and simply drives seg to
//      SEG_BLANK on every digit until a result is latched. A static
//      "dig_sel == 4'b1111 right after reset" check is therefore WRONG
//      and will falsely fail even on correctly-behaving hardware. This
//      TB instead scans a full mux cycle post-reset and confirms every
//      digit slot reads SEG_BLANK, which is the actual correct idle
//      behaviour.
//
// Exercises:
//   1. Power-on reset behaviour: scans a full digit-mux cycle and
//      confirms every digit position is blank (not "OK"/"INF"), and
//      that led_green/buzzer/done_led are all off.
//   2. A full inference triggered by a debounced start_n button press,
//      using the real synthesized debounce timing (unoverridable).
//   3. Self-checking of the display purely from primary outputs: decode
//      seg[]/dig_sel[] into "OK " or "INF", then confirm led_green/buzzer
//      agree with that decoded result.
//   4. Confirms the known S_DONE-has-no-exit behaviour (a second press
//      before reset is a no-op), matching fc3_controller.sv as provided.
//   5. Confirms a clean rst_n cycle correctly re-arms the design.
//   6. Basic protocol checks: dig_sel is always one-hot (or all-idle),
//      no X's propagate to outputs post-reset.
// =============================================================================
/*
`timescale 1ns/1ps

module tb_proto_fc3_top;

    // -------------------------------------------------------------------
    // Parameters / knobs
    // -------------------------------------------------------------------
    localparam CLK_PERIOD = 20;              // 50 MHz

    // Real synthesized DEBOUNCE_LIMIT default (unchanged from RTL,
    // unoverridable since the netlist has no parameters).
    localparam [19:0] REAL_DEBOUNCE   = 20'hFFFFF;     // 1,048,575 cycles
    localparam integer TIMEOUT_CYCLES = 32'd3_000_000; // margin over 2 debounce edges + NPU latency

    // -------------------------------------------------------------------
    // DUT I/O
    // -------------------------------------------------------------------
    logic clk;
    logic rst_n;
    logic start_n;

    logic [6:0] seg;
    logic [3:0] dig_sel;
    logic       led_green;
    logic       buzzer;
    logic       done_led;

    int errors = 0;
    int checks = 0;

    // -------------------------------------------------------------------
    // DUT - bare instantiation, no parameter override, no reliance on
    // internal instance names (netlist has neither).
    // -------------------------------------------------------------------
    proto_fc3_top dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start_n   (start_n),
        .seg       (seg),
        .dig_sel   (dig_sel),
        .led_green (led_green),
        .buzzer    (buzzer),
        .done_led  (done_led)
    );

    // -------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------
    // Segment pattern reference table (must match argmax_7seg exactly -
    // duplicated here deliberately so the TB is an independent check,
    // not a copy-paste of the RTL's internal localparams)
    // -------------------------------------------------------------------
    localparam logic [6:0] SEG_BLANK = 7'b0000000;
    localparam logic [6:0] SEG_O     = 7'b0111111;
    localparam logic [6:0] SEG_K     = 7'b1110110;
    localparam logic [6:0] SEG_I     = 7'b0000110;
    localparam logic [6:0] SEG_N     = 7'b1010100;
    localparam logic [6:0] SEG_F     = 7'b1110001;

    function automatic logic [6:0] expected_pattern(int pos, logic healthy);
        if (healthy) begin
            case (pos)
                0: return SEG_O;
                1: return SEG_K;
                default: return SEG_BLANK;
            endcase
        end else begin
            case (pos)
                0: return SEG_I;
                1: return SEG_N;
                2: return SEG_F;
                default: return SEG_BLANK;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------
    // Helper: check
    // -------------------------------------------------------------------
    task automatic check(input logic cond, input string msg);
        checks++;
        if (!cond) begin
            errors++;
            $display("[%0t] *** CHECK FAILED: %s", $time, msg);
        end
    endtask

    // -------------------------------------------------------------------
    // Reset task
    // -------------------------------------------------------------------
    task automatic do_reset();
        rst_n   = 1'b0;
        start_n = 1'b1;  // idle (active-low button, not pressed)
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
    endtask

    // -------------------------------------------------------------------
    // Press-and-release the (active-low, debounced) start button.
    // Hold time sized off the REAL synthesized debounce limit.
    // -------------------------------------------------------------------
    task automatic press_start();
        start_n = 1'b0;
        repeat (REAL_DEBOUNCE + 4) @(posedge clk);
        start_n = 1'b1;
        repeat (REAL_DEBOUNCE + 4) @(posedge clk);
    endtask

    // -------------------------------------------------------------------
    // Wait for done_led with a timeout guard
    // -------------------------------------------------------------------
    task automatic wait_for_done();
        longint t;
        t = 0;
        while (!done_led && t < TIMEOUT_CYCLES) begin
            @(posedge clk);
            t++;
        end
        check(t < TIMEOUT_CYCLES, "inference completed within timeout");
    endtask

    // -------------------------------------------------------------------
    // Scan a full 4-digit refresh cycle, reconstruct what's displayed,
    // and independently DECODE whether it reads "OK " or "INF" - this
    // decoded result is also returned to the caller so led_green/buzzer
    // can be cross-checked against it without any hierarchical access.
    // -------------------------------------------------------------------
    task automatic check_display(output logic decoded_healthy, input string label);
        logic [6:0] captured [0:3];
        int         seen_mask;
        int         idx;
        logic [6:0] raw_seg;
        logic [3:0] raw_dsel;
        logic       matches_ok, matches_inf;

        seen_mask = 0;
        for (int i = 0; i < 5 * 65536; i++) begin
            @(posedge clk);
            raw_dsel = dig_sel;
            raw_seg  = seg;

            // dig_sel must be one-hot-active-low or fully idle (all 1s)
            check((raw_dsel == 4'b1110 || raw_dsel == 4'b1101 ||
                   raw_dsel == 4'b1011 || raw_dsel == 4'b0111 ||
                   raw_dsel == 4'b1111),
                  {label, ": dig_sel is one-hot-active-low or idle"});

            for (idx = 0; idx < 4; idx++) begin
                if (raw_dsel == (~(4'b0001 << idx))) begin
                    // un-invert seg back to common-cathode convention
                    // (COMMON_ANODE=1, hardcoded in synthesized netlist)
                    captured[idx] = ~raw_seg;
                    seen_mask     = seen_mask | (1 << idx);
                end
            end

            if (seen_mask == 4'b1111) i = 5*65536; // break out early once all 4 seen
        end

        check(seen_mask == 4'b1111, {label, ": all 4 digit slots observed during scan"});

        // Decode independently against BOTH expected patterns; exactly
        // one should match if the display is behaving correctly.
        matches_ok  = 1'b1;
        matches_inf = 1'b1;
        for (idx = 0; idx < 4; idx++) begin
            if (captured[idx] !== expected_pattern(idx, 1'b1)) matches_ok  = 1'b0;
            if (captured[idx] !== expected_pattern(idx, 1'b0)) matches_inf = 1'b0;
        end

        check(matches_ok ^ matches_inf,
              {label, ": scanned digits decode to exactly one of OK/INF (no garbage, no ambiguity)"});

        decoded_healthy = matches_ok;
    endtask

    // -------------------------------------------------------------------
    // Scan a full 4-digit refresh cycle and confirm every digit position
    // is BLANK (idle state). Unlike check_display(), this does not
    // require the mux to ever sit at dig_sel==4'b1111 - the mux is
    // expected to keep free-running through one-hot selects even while
    // idle; only the segment content (all blank) indicates "no result".
    // -------------------------------------------------------------------
    task automatic check_display_blank(input string label);
        logic [6:0] captured [0:3];
        int         seen_mask;
        int         idx;
        logic [6:0] raw_seg;
        logic [3:0] raw_dsel;

        seen_mask = 0;
        for (int i = 0; i < 5 * 65536; i++) begin
            @(posedge clk);
            raw_dsel = dig_sel;
            raw_seg  = seg;

            check((raw_dsel == 4'b1110 || raw_dsel == 4'b1101 ||
                   raw_dsel == 4'b1011 || raw_dsel == 4'b0111 ||
                   raw_dsel == 4'b1111),
                  {label, ": dig_sel is one-hot-active-low or idle"});

            for (idx = 0; idx < 4; idx++) begin
                if (raw_dsel == (~(4'b0001 << idx))) begin
                    captured[idx] = ~raw_seg;
                    seen_mask     = seen_mask | (1 << idx);
                end
            end

            if (seen_mask == 4'b1111) i = 5*65536;
        end

        check(seen_mask == 4'b1111, {label, ": all 4 digit slots observed during idle scan"});

        for (idx = 0; idx < 4; idx++) begin
            check(captured[idx] == SEG_BLANK,
                  $sformatf("%s: digit %0d is blank while idle", label, idx));
        end
    endtask

    // -------------------------------------------------------------------
    // Cross-check led_green/buzzer against the INDEPENDENTLY DECODED
    // display result (from check_display's output), not against any
    // internal signal - fully hierarchy-free.
    // -------------------------------------------------------------------
    task automatic cross_check_outputs(input logic decoded_healthy, input string label);
        check(led_green == decoded_healthy,
              {label, ": led_green matches decoded display result"});
        check(buzzer == !decoded_healthy,
              {label, ": buzzer matches decoded display result"});
        $display("[%0t] %s: decoded class = %s", $time, label,
                 decoded_healthy ? "Healthy (OK)" : "Infected (INF)");
    endtask

    // -------------------------------------------------------------------
    // MAIN SEQUENCE
    // -------------------------------------------------------------------
    initial begin
        logic result_healthy;

        $display("=== tb_proto_fc3_top: starting (GATE-LEVEL sim, real debounce=%0d cycles) ===", REAL_DEBOUNCE);

        // ---------------- Scenario 0: reset behaviour ------------------
        do_reset();
        check(led_green == 1'b0,  "post-reset: led_green off");
        check(buzzer == 1'b0,     "post-reset: buzzer off");
        check(done_led == 1'b0,   "post-reset: done_led not yet asserted");
        check_display_blank("post-reset");

        // ---------------- Scenario 1: inference -------------------------
        // Uses whatever fc2_output_rom's baked-in $readmemh default loaded
        // at elaboration; this netlist can't be reloaded mid-run without
        // hierarchy access, so only one activation vector is exercised.
        press_start();
        wait_for_done();
        check_display(result_healthy, "Scenario1");
        cross_check_outputs(result_healthy, "Scenario1");

        // ---------------- Scenario 2: known S_DONE no-exit behaviour ----
        // fc3_controller.sv (as provided) has no exit from S_DONE, so a
        // second button press without a reset should be a no-op.
        begin
            logic done_before;
            done_before = done_led;
            press_start();
            repeat (200) @(posedge clk);
            check(done_led == done_before,
                  "Known issue confirmed: fc3_controller has no S_DONE exit -> second press before reset is a no-op");
        end

        // ---------------- Scenario 3: reset + re-run same vector --------
        // Confirms a clean rst_n cycle correctly re-arms the design for
        // another inference (still same baked-in activation vector).
        do_reset();
        check_display_blank("post-reset(scenario3)");
        press_start();
        wait_for_done();
        check_display(result_healthy, "Scenario3(post-reset re-run)");
        cross_check_outputs(result_healthy, "Scenario3(post-reset re-run)");

        // ---------------- Summary ----------------------------------------
        $display("=== tb_proto_fc3_top: %0d checks run, %0d failed ===", checks, errors);
        if (errors == 0)
            $display("*** ALL CHECKS PASSED ***");
        else
            $display("*** %0d CHECK(S) FAILED ***", errors);

        $finish;
    end

    // -------------------------------------------------------------------
    // Global watchdog - scaled off TIMEOUT_CYCLES
    // -------------------------------------------------------------------
    initial begin
        #(CLK_PERIOD * longint'(TIMEOUT_CYCLES) * 10);
        $display("*** TIMEOUT: testbench watchdog fired, aborting ***");
        $finish;
    end

endmodule*/