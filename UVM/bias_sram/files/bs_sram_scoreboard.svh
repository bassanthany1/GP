    // =========================================================================
    // 5. SCOREBOARD
    // =========================================================================
    class bs_sram_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(bs_sram_scoreboard)

        uvm_analysis_imp #(bs_sram_seq_item, bs_sram_scoreboard) analysis_export;

        bs_sram_ref_model ref_model;

        int unsigned checks_passed  = 0;
        int unsigned checks_failed  = 0;
        int unsigned bursts_checked = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            analysis_export = new("analysis_export", this);
            ref_model = bs_sram_ref_model::type_id::create("ref_model");
        endfunction

        function void write(bs_sram_seq_item item);
            if (item.is_write) begin
                ref_model.write_beat(int'(item.write_addr), item.write_data);
                `uvm_info("BS_SB", $sformatf("REF update: %s", item.convert2string()), UVM_HIGH)
            end else begin
                check_burst(item);
            end
        endfunction

        function void check_burst(bs_sram_seq_item item);
            int unsigned exp_len       = int'(item.burst_length);
            int unsigned got_len       = item.read_beats.size();
            int unsigned exp_beats_len = item.expected_beats.size();

            bursts_checked++;

            // 1. Beat count
            if (got_len !== exp_len) begin
                `uvm_error("BS_SB", $sformatf(
                    "Beat count mismatch: exp=%0d got=%0d | %s",
                    exp_len, got_len, item.convert2string()))
                checks_failed++;
            end else checks_passed++;

            // 2. Data values (compare against driver's snapshot)
            begin
                int unsigned check_len = (got_len < exp_beats_len) ? got_len : exp_beats_len;
                for (int i = 0; i < int'(check_len); i++) begin
                    if (item.read_beats[i] !== item.expected_beats[i]) begin
                        `uvm_error("BS_SB", $sformatf(
                            "Data mismatch beat[%0d]: got=%0d exp=%0d | %s",
                            i, $signed(item.read_beats[i]),
                            $signed(item.expected_beats[i]),
                            item.convert2string()))
                        checks_failed++;
                    end else checks_passed++;
                end
            end

            // 3. burst_complete
            if (!item.burst_complete_seen) begin
                `uvm_error("BS_SB", $sformatf(
                    "burst_complete never seen for len=%0d", exp_len))
                checks_failed++;
            end else checks_passed++;

            `uvm_info("BS_SB", $sformatf(
                "Burst %0d done - passed=%0d failed=%0d",
                bursts_checked, checks_passed, checks_failed), UVM_LOW)
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("BS_SB", "=============================================", UVM_NONE)
            `uvm_info("BS_SB", $sformatf("  BURSTS  : %0d", bursts_checked), UVM_NONE)
            `uvm_info("BS_SB", $sformatf("  PASSED  : %0d", checks_passed),  UVM_NONE)
            `uvm_info("BS_SB", $sformatf("  FAILED  : %0d", checks_failed),  UVM_NONE)
            `uvm_info("BS_SB", "=============================================", UVM_NONE)
            if (checks_failed > 0)
                `uvm_error("BS_SB", "*** TEST FAILED ***")
            else
                `uvm_info("BS_SB", "*** TEST PASSED ***", UVM_NONE)
        endfunction

    endclass