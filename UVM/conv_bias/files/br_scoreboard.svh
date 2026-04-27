    // =========================================================================
    // 5. SCOREBOARD
    // =========================================================================
    // Receives items from monitor.
    // For each item:
    //   1. Runs ref model to compute expected outputs.
    //   2. Compares DUT output_data vs expected for every [r][c].
    //   3. Checks output_channel_start / output_window_idx_start passthrough.
    // =========================================================================
    class br_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(br_scoreboard)

        uvm_analysis_imp #(br_seq_item, br_scoreboard) analysis_export;

        br_ref_model ref_model;

        int unsigned checks_passed = 0;
        int unsigned checks_failed = 0;
        int unsigned items_checked = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            analysis_export = new("analysis_export", this);
            ref_model       = br_ref_model::type_id::create("ref_model");
        endfunction

        function void write(br_seq_item item);
            // Run reference model
            ref_model.predict(item);
            check_item(item);
        endfunction

        function void check_item(br_seq_item item);
            items_checked++;

            // ---- 1. Check every output pixel ----
            foreach (item.output_data[r,c]) begin
                if (item.output_data[r][c] !== item.exp_output_data[r][c]) begin
                    `uvm_error("BR_SB", $sformatf(
                        "output_data[%0d][%0d] mismatch: got=%0d exp=%0d | %s",
                        r, c,
                        $signed(item.output_data[r][c]),
                        $signed(item.exp_output_data[r][c]),
                        item.convert2string()))
                    checks_failed++;
                end else begin
                    checks_passed++;
                end
            end

            // ---- 2. Check channel_start passthrough ----
            if (item.output_channel_start !== item.conv_channel_start) begin
                `uvm_error("BR_SB", $sformatf(
                    "output_channel_start mismatch: got=%0d exp=%0d",
                    item.output_channel_start, item.conv_channel_start))
                checks_failed++;
            end else checks_passed++;

            // ---- 3. Check window_idx_start passthrough ----
            if (item.output_window_idx_start !== item.conv_window_idx_start) begin
                `uvm_error("BR_SB", $sformatf(
                    "output_window_idx_start mismatch: got=%0d exp=%0d",
                    item.output_window_idx_start, item.conv_window_idx_start))
                checks_failed++;
            end else checks_passed++;

            `uvm_info("BR_SB", $sformatf(
                "Item %0d done - passed=%0d failed=%0d | %s",
                items_checked, checks_passed, checks_failed,
                item.convert2string()), UVM_LOW)
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("BR_SB", "=============================================", UVM_NONE)
            `uvm_info("BR_SB", $sformatf("  TRANSACTIONS : %0d", items_checked),  UVM_NONE)
            `uvm_info("BR_SB", $sformatf("  CHECKS PASSED: %0d", checks_passed),  UVM_NONE)
            `uvm_info("BR_SB", $sformatf("  CHECKS FAILED: %0d", checks_failed),  UVM_NONE)
            `uvm_info("BR_SB", "=============================================", UVM_NONE)
            if (checks_failed > 0)
                `uvm_error("BR_SB", "*** TEST FAILED ***")
            else
                `uvm_info("BR_SB",  "*** TEST PASSED ***", UVM_NONE)
        endfunction

    endclass