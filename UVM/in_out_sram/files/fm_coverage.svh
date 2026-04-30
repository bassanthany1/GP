   // =========================================================================
    // 6. COVERAGE
    // =========================================================================
    class fm_coverage extends uvm_subscriber #(fm_seq_item);
        `uvm_component_utils(fm_coverage)

        fm_seq_item curr;

        // ---- Write address distribution ----
        covergroup cg_wr_addr;
            cp_wa: coverpoint curr.wr_addr {
                bins addr_lo  = {[0:287]};    // bank0 region
                bins addr_mid = {[288:575]};  // bank1 region
                bins addr_hi  = {[576:863]};  // bank2 region
            }
        endgroup

        // ---- Read address per port ----
        covergroup cg_rd_addr;
            cp_p0: coverpoint curr.rd_addr[0] {
                bins a_lo={[0:287]}; bins a_mid={[288:575]}; bins a_hi={[576:863]};
            }
            cp_p1: coverpoint curr.rd_addr[1] {
                bins a_lo={[0:287]}; bins a_mid={[288:575]}; bins a_hi={[576:863]};
            }
            cp_p2: coverpoint curr.rd_addr[2] {
                bins a_lo={[0:287]}; bins a_mid={[288:575]}; bins a_hi={[576:863]};
            }
        endgroup

        // ---- Port activity combinations ----
        covergroup cg_port_req;
            cp_req: coverpoint {curr.rd_req[2], curr.rd_req[1], curr.rd_req[0]} {
                // bins none   = {3'b000};
                bins p0     = {3'b001};
                bins p1     = {3'b010};
                bins p2     = {3'b100};
                bins p01    = {3'b011};
                bins p02    = {3'b101};
                bins p12    = {3'b110};
                bins all3   = {3'b111};
            }
        endgroup

        // ---- Bank conflict ----
        covergroup cg_conflict;
            cp_cf: coverpoint curr.obs_bank_conflict {
                bins no_conflict = {0};
                bins conflict    = {1};
            }
        endgroup

        covergroup cg_bank_pattern;
    // Which bank does each active port access?
    cp_b0: coverpoint (curr.rd_req[0] ? int'(curr.rd_addr[0]) % 3 : 3) {
        bins bank0={0}; bins bank1={1}; bins bank2={2}; bins inactive={3};
    }
    cp_b1: coverpoint (curr.rd_req[1] ? int'(curr.rd_addr[1]) % 3 : 3) {
        bins bank0={0}; bins bank1={1}; bins bank2={2}; bins inactive={3};
    }
    cp_b2: coverpoint (curr.rd_req[2] ? int'(curr.rd_addr[2]) % 3 : 3) {
        bins bank0={0}; bins bank1={1}; bins bank2={2}; bins inactive={3};
    }
    cross cp_b0, cp_b1, cp_b2 {
        // Ignore: all three inactive (impossible — monitor requires at least one active)
        ignore_bins all_inactive = binsof(cp_b0.inactive)
                                && binsof(cp_b1.inactive)
                                && binsof(cp_b2.inactive);
    }
endgroup

        // ---- Write-during-read conflict injection ----
        covergroup cg_wr_during_rd;
            cp_wdr: coverpoint curr.wr_en_during_read {
                bins normal    = {0};
                bins wr_during = {1};
            }
        endgroup

        // ---- Address extremes ----
        covergroup cg_addr_extremes;
            cp_wr: coverpoint curr.wr_addr {
                bins addr_zero = {0};
                bins addr_max  = {PKG_TOTAL_ELEMENTS-1};
                bins addr_mid  = {[1:PKG_TOTAL_ELEMENTS-2]};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_wr_addr      = new();
            cg_rd_addr      = new();
            cg_port_req     = new();
            cg_conflict     = new();
            cg_bank_pattern = new();
            cg_wr_during_rd = new();
            cg_addr_extremes = new();
        endfunction

        function void write(fm_seq_item t);
            curr = t;
            if (t.is_write) begin
                cg_wr_addr.sample();
                cg_addr_extremes.sample();
            end else begin
                cg_rd_addr.sample();
                cg_port_req.sample();
                cg_conflict.sample();
                cg_bank_pattern.sample();
                cg_wr_during_rd.sample();
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("FM_COV", "---- Coverage Summary ----", UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Wr addr zones   : %.1f%%",
                cg_wr_addr.get_coverage()),       UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Rd addr zones   : %.1f%%",
                cg_rd_addr.get_coverage()),       UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Port req combos : %.1f%%",
                cg_port_req.get_coverage()),      UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Bank conflict   : %.1f%%",
                cg_conflict.get_coverage()),      UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Bank pattern    : %.1f%%",
                cg_bank_pattern.get_coverage()),  UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Wr during rd    : %.1f%%",
                cg_wr_during_rd.get_coverage()),  UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Addr extremes   : %.1f%%",
                cg_addr_extremes.get_coverage()), UVM_NONE)
            `uvm_info("FM_COV", "--------------------------", UVM_NONE)
        endfunction

    endclass