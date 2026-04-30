    // =========================================================================
    // 5. SCOREBOARD
    // =========================================================================
    // Receives ALL items from the monitor via a single plain analysis_imp.
    //
    // Write items  -> update internal shadow memory.
    // Read  items  -> run ref model and compare:
    //                  a) rd_valid per port
    //                  b) rd_data  per port (only when rd_valid expected)
    //                  c) bank_conflict flag
    // =========================================================================
    class fm_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(fm_scoreboard)

        uvm_analysis_imp #(fm_seq_item, fm_scoreboard) analysis_export;

        fm_ref_model ref_model;

        int unsigned checks_passed  = 0;
        int unsigned checks_failed  = 0;
        int unsigned reads_checked  = 0;
        int unsigned writes_tracked = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            analysis_export = new("analysis_export", this);
            ref_model       = fm_ref_model::type_id::create("ref_model");
        endfunction

        function void write(fm_seq_item item);
    if (item.is_write) begin
        ref_model.write(int'(item.wr_addr), item.wr_data);
        writes_tracked++;
    end else begin
        check_read(item);
    end
endfunction 


function void check_read(fm_seq_item item);
    reads_checked++;

    // Scoreboard predicts from its own shadow (NOT relying on driver's exp_* fields)
    ref_model.predict_read(item);

    for (int p = 0; p < PKG_NUM_PORTS; p++) begin
        // rd_valid
        if (item.obs_rd_valid[p] !== logic'(item.exp_rd_valid[p])) begin
            `uvm_error("FM_SB", $sformatf("[Rd#%0d] rd_valid[%0d] mismatch: got=%0b exp=%0b | %s",
    reads_checked, p, item.obs_rd_valid[p], item.exp_rd_valid[p],
    item.convert2string()))
            checks_failed++;
        end else checks_passed++;

        // rd_data
        if (item.rd_req[p]) begin
            bit port_conflict = 0;
            if (item.wr_en_during_read) begin
                int unsigned wr_bank = int'(item.wr_addr_during_read) % 3;
                int unsigned rd_bank = int'(item.rd_addr[p]) % 3;
                port_conflict = (wr_bank == rd_bank);
            end
            if (!port_conflict) begin
                if (item.obs_rd_data[p] !== item.exp_rd_data[p]) begin
                    `uvm_error("FM_SB", $sformatf("[Rd#%0d] rd_data[%0d] mismatch: got=%0d exp=%0d addr=%0d | %s",
    reads_checked, p, $signed(item.obs_rd_data[p]),
    $signed(item.exp_rd_data[p]), item.rd_addr[p],
    item.convert2string()))
                    checks_failed++;
                end else checks_passed++;
            end
        end
    end

    // bank_conflict
    if (item.obs_bank_conflict !== logic'(item.exp_bank_conflict)) begin

        `uvm_error("FM_SB", $sformatf("[Rd#%0d] bank_conflict mismatch: got=%0b exp=%0b | %s",
    reads_checked, item.obs_bank_conflict, item.exp_bank_conflict,
    item.convert2string()))
        checks_failed++;
    end else checks_passed++;

    // Apply concurrent write to shadow AFTER the read check
    if (item.wr_en_during_read)
        ref_model.write(int'(item.wr_addr_during_read), item.wr_data_during_read);

    `uvm_info("FM_SB", $sformatf("Read %0d done - passed=%0d failed=%0d",
              reads_checked, checks_passed, checks_failed), UVM_LOW)
endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("FM_SB", "=============================================", UVM_NONE)
            `uvm_info("FM_SB", $sformatf("  WRITES TRACKED : %0d", writes_tracked), UVM_NONE)
            `uvm_info("FM_SB", $sformatf("  READS  CHECKED : %0d", reads_checked),  UVM_NONE)
            `uvm_info("FM_SB", $sformatf("  CHECKS PASSED  : %0d", checks_passed),  UVM_NONE)
            `uvm_info("FM_SB", $sformatf("  CHECKS FAILED  : %0d", checks_failed),  UVM_NONE)
            `uvm_info("FM_SB", "=============================================", UVM_NONE)
            if (checks_failed > 0)
                `uvm_error("FM_SB", "*** TEST FAILED ***")
            else
                `uvm_info("FM_SB",  "*** TEST PASSED ***", UVM_NONE)
        endfunction

    endclass