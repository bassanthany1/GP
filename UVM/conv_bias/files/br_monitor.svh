    // =========================================================================
    // 4. MONITOR
    // =========================================================================
    // Watches the interface. On output_valid, captures output_data and
    // publishes one br_seq_item. Also captures conv_valid stimulus fields
    // so the scoreboard can match them.
    // =========================================================================
    class br_monitor extends uvm_monitor;
        `uvm_component_utils(br_monitor)

        virtual br_if vif;
        uvm_analysis_port #(br_seq_item) ap;

        // Shadow the stimulus so we can attach it to the response item
        logic                          sh_enable_relu;
        logic [7:0]                    sh_out_channels;
        logic [CH_W-1:0]              sh_ch_start;
        logic [PKG_WIN_IDX_W-1:0]    sh_win_idx;
        logic signed [PKG_DATA_WIDTH-1:0]
                                       sh_conv_data [PKG_TILE_ROWS][PKG_ARRAY_COLS];
        logic signed [PKG_BIAS_WIDTH-1:0]
                                       sh_bias [PKG_ARRAY_COLS];
        int  sh_bias_idx;
        bit  sh_capturing_bias;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual br_if)::get(this, "", "vif", vif))
                `uvm_fatal("BR_MON", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            br_seq_item item;
            forever begin
                @(vif.cb_mon);
                if (vif.cb_mon.rst) begin
                    sh_capturing_bias = 0;
                    sh_bias_idx       = 0;
                    continue;
                end

                // ----- Capture conv stimulus -----
                if (vif.cb_mon.conv_valid) begin
                    sh_enable_relu  = vif.cb_mon.enable_relu;
                    sh_out_channels = vif.cb_mon.out_channels;
                    sh_ch_start     = vif.cb_mon.conv_channel_start;
                    sh_win_idx      = vif.cb_mon.conv_window_idx_start;
                    foreach (sh_conv_data[r,c])
                        sh_conv_data[r][c] = vif.cb_mon.conv_data[r][c];
                    sh_capturing_bias = 1;
                    sh_bias_idx       = 0;
                end

                // ----- Shadow bias SRAM data beats -----
                if (sh_capturing_bias && vif.cb_mon.bias_sram_valid
                    && sh_bias_idx < PKG_ARRAY_COLS) begin
                    sh_bias[sh_bias_idx] = vif.cb_mon.bias_sram_data;
                    sh_bias_idx++;
                end

                // ----- Capture output when valid -----
                if (vif.cb_mon.output_valid) begin
                    item = br_seq_item::type_id::create("mon_item");

                    // Copy shadowed stimulus
                    item.enable_relu           = sh_enable_relu;
                    item.out_channels          = sh_out_channels;
                    item.conv_channel_start    = sh_ch_start;
                    item.conv_window_idx_start = sh_win_idx;
                    foreach (item.conv_data[r,c])
                        item.conv_data[r][c]   = sh_conv_data[r][c];
                    foreach (item.bias_values[c])
                        item.bias_values[c]    = sh_bias[c];

                    // Capture DUT outputs
                    foreach (item.output_data[r,c])
                        item.output_data[r][c] = vif.cb_mon.output_data[r][c];
                    item.output_channel_start    = vif.cb_mon.output_channel_start;
                    item.output_window_idx_start = vif.cb_mon.output_window_idx_start;
                    item.output_valid_seen        = 1'b1;

                    sh_capturing_bias = 0;
                    ap.write(item);

                    `uvm_info("BR_MON",
                        $sformatf("Observed output: %s", item.convert2string()),
                        UVM_MEDIUM)
                end
            end
        endtask

    endclass