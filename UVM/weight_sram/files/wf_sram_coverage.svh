   // =========================================================================
    // 6. COVERAGE
    // =========================================================================
    class wf_sram_coverage extends uvm_subscriber #(wf_sram_seq_item);
        `uvm_component_utils(wf_sram_coverage)

        wf_sram_seq_item curr;

        covergroup cg_burst_length;
            cp_len: coverpoint curr.burst_length {
                bins len_1       = {1};
                bins len_small   = {[2:15]};
                bins len_medium  = {[16:63]};
                bins len_large   = {[64:255]};
                bins len_max_ish = {[256:512]};
            }
        endgroup

        covergroup cg_layer_offset;
            cp_offset: coverpoint curr.layer_offset {
                bins offset_zero  = {0};
                bins offset_small = {[1:1000]};
                bins offset_med   = {[1001:10000]};
                bins offset_large = {[10001:44190]};
            }
        endgroup

        covergroup cg_burst_complete;
            cp_done: coverpoint curr.burst_complete_seen {
                bins seen = {1};
            }
        endgroup

        covergroup cg_addr_cross;
            cp_off: coverpoint curr.layer_offset {
                bins off_0    = {0};
                bins off_mid  = {[1:22095]};
                bins off_high = {[22096:44190]};
            }
            cp_len: coverpoint curr.burst_length {
                bins len_short = {[1:15]};
                bins len_med   = {[16:127]};
                bins len_long  = {[128:512]};
            }
            cross cp_off, cp_len;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_burst_length  = new();
            cg_layer_offset  = new();
            cg_burst_complete = new();
            cg_addr_cross    = new();
        endfunction

        // uvm_subscriber provides analysis_export and calls write() automatically
        function void write(wf_sram_seq_item t);
            // m_resp = t ;
            curr = t;
            // if (!item.is_write) begin
                cg_burst_length.sample();
                cg_layer_offset.sample();
                cg_burst_complete.sample();
                cg_addr_cross.sample();
            // end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("WF_COV", "---- Coverage Summary ----", UVM_NONE)
            `uvm_info("WF_COV", $sformatf("  Burst length : %.1f%%",
                cg_burst_length.get_coverage()),  UVM_NONE)
            `uvm_info("WF_COV", $sformatf("  Layer offset : %.1f%%",
                cg_layer_offset.get_coverage()),  UVM_NONE)
            `uvm_info("WF_COV", $sformatf("  Burst done   : %.1f%%",
                cg_burst_complete.get_coverage()), UVM_NONE)
            `uvm_info("WF_COV", $sformatf("  Addr cross   : %.1f%%",
                cg_addr_cross.get_coverage()),    UVM_NONE)
            `uvm_info("WF_COV", "--------------------------", UVM_NONE)
        endfunction

    endclass 