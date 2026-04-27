   // =========================================================================
    // 6. COVERAGE
    // =========================================================================
    class bs_sram_coverage extends uvm_subscriber #(bs_sram_seq_item);
        `uvm_component_utils(bs_sram_coverage)

        bs_sram_seq_item curr;

        covergroup cg_burst_length;
            cp_len: coverpoint curr.burst_length {
                bins len_1       = {1};
                bins len_small   = {[2:7]};
                bins len_medium  = {[8:12]};
                bins len_large   = {[13:15]};
                bins len_max     = {16};
            }
        endgroup

        covergroup cg_layer_offset;
            cp_offset: coverpoint curr.layer_offset {
                bins offset_zero  = {0};
                bins offset_small = {[1:59]};
                bins offset_mid   = {[60:118]};
                bins offset_large = {[119:236]};
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
                bins off_mid  = {[1:118]};
                bins off_high = {[119:236]};
            }
            cp_len: coverpoint curr.burst_length {
                bins len_short = {[1:4]};
                bins len_med   = {[5:12]};
                bins len_long  = {[13:16]};
            }
            cross cp_off, cp_len;
        endgroup

        // LeNet-5 specific: cover the 6 bias layers
        // C1=6, S2=6, C3=16, S4=16, C5=120, F6=84
        // stored as offsets: 0,6,12,28,44,164 (cumulative)
        covergroup cg_lenet_layers;
            cp_layer: coverpoint curr.layer_offset {
                bins c1_offset  = {0};
                bins s2_offset  = {6};
                bins c3_offset  = {12};
                bins s4_offset  = {28};
                bins c5_offset  = {44};
                bins f6_offset  = {164};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_burst_length  = new();
            cg_layer_offset  = new();
            cg_burst_complete = new();
            cg_addr_cross    = new();
            cg_lenet_layers  = new();
        endfunction

        function void write(bs_sram_seq_item t);
            curr = t;
            cg_burst_length.sample();
            cg_layer_offset.sample();
            cg_burst_complete.sample();
            cg_addr_cross.sample();
            cg_lenet_layers.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("BS_COV", "---- Coverage Summary ----", UVM_NONE)
            `uvm_info("BS_COV", $sformatf("  Burst length  : %.1f%%",
                cg_burst_length.get_coverage()),   UVM_NONE)
            `uvm_info("BS_COV", $sformatf("  Layer offset  : %.1f%%",
                cg_layer_offset.get_coverage()),   UVM_NONE)
            `uvm_info("BS_COV", $sformatf("  Burst done    : %.1f%%",
                cg_burst_complete.get_coverage()), UVM_NONE)
            `uvm_info("BS_COV", $sformatf("  Addr cross    : %.1f%%",
                cg_addr_cross.get_coverage()),     UVM_NONE)
            `uvm_info("BS_COV", $sformatf("  LeNet layers  : %.1f%%",
                cg_lenet_layers.get_coverage()),   UVM_NONE)
            `uvm_info("BS_COV", "--------------------------", UVM_NONE)
        endfunction

    endclass