    // =========================================================================
    // 6. COVERAGE
    // =========================================================================
    class br_coverage extends uvm_subscriber #(br_seq_item);
        `uvm_component_utils(br_coverage)

        br_seq_item curr;

        // ---- ReLU enabled/disabled ----
        covergroup cg_relu;
            cp_relu: coverpoint curr.enable_relu {
                bins relu_off = {0};
                bins relu_on  = {1};
            }
        endgroup

        // ---- Channel tile position ----
        covergroup cg_channel_start;
            cp_ch: coverpoint curr.conv_channel_start {
                bins ch_first  = {0};
                bins ch_mid    = {[4:59]};
                bins ch_last   = {[60:116]};
            }
        endgroup

        // ---- Number of active channels ----
        covergroup cg_out_channels;
            cp_n: coverpoint curr.out_channels {
                bins n_tiny   = {[1:8]};
                bins n_small  = {[9:32]};
                bins n_medium = {[33:80]};
                bins n_large  = {[81:120]};
            }
        endgroup

        // ---- Padding scenario: some columns are padding ----
        covergroup cg_padding;
            // padding exists when conv_channel_start + ARRAY_COLS > out_channels
            cp_pad: coverpoint (int'(curr.conv_channel_start)
                                + PKG_ARRAY_COLS > int'(curr.out_channels)) {
                bins no_pad  = {0};
                bins has_pad = {1};
            }
        endgroup

        // ---- ReLU clipping: biased value crosses zero ----
        covergroup cg_relu_clip;
            cp_clip: coverpoint (curr.enable_relu
                                 && ($signed(curr.conv_data[0][0])
                                     + $signed(curr.bias_values[0])) < 0) {
                bins no_clip = {0};
                bins clipped = {1};
            }
        endgroup

        // ---- Cross: relu x padding ----
        covergroup cg_cross;
            cp_relu: coverpoint curr.enable_relu { bins off={0}; bins on={1}; }
            cp_pad:  coverpoint (int'(curr.conv_channel_start)
                                 + PKG_ARRAY_COLS > int'(curr.out_channels)) {
                bins no={0}; bins yes={1};
            }
            cross cp_relu, cp_pad;
        endgroup

        // ---- Window index distribution ----
        covergroup cg_window;
            cp_win: coverpoint curr.conv_window_idx_start {
                bins win_0    = {0};
                bins win_low  = {[1:127]};
                bins win_mid  = {[128:511]};
                bins win_high = {[512:1023]};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_relu         = new();
            cg_channel_start = new();
            cg_out_channels = new();
            cg_padding      = new();
            cg_relu_clip    = new();
            cg_cross        = new();
            cg_window       = new();
        endfunction

        function void write(br_seq_item t);
            curr = t;
            cg_relu.sample();
            cg_channel_start.sample();
            cg_out_channels.sample();
            cg_padding.sample();
            cg_relu_clip.sample();
            cg_cross.sample();
            cg_window.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("BR_COV", "---- Coverage Summary ----", UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  ReLU on/off     : %.1f%%",
                cg_relu.get_coverage()),          UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  Channel start   : %.1f%%",
                cg_channel_start.get_coverage()), UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  Out channels    : %.1f%%",
                cg_out_channels.get_coverage()),  UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  Padding cols    : %.1f%%",
                cg_padding.get_coverage()),       UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  ReLU clipping   : %.1f%%",
                cg_relu_clip.get_coverage()),     UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  ReLU x Padding  : %.1f%%",
                cg_cross.get_coverage()),         UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  Window idx      : %.1f%%",
                cg_window.get_coverage()),        UVM_NONE)
            `uvm_info("BR_COV", "--------------------------", UVM_NONE)
        endfunction

    endclass