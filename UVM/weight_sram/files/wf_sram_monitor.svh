  // =========================================================================
    // 4. MONITOR
    // =========================================================================
    // Watches the interface. On each read_request, collects all read_valid
    // beats until burst_complete. Fills item.read_beats and publishes via ap.
    // For writes, just observes and re-broadcasts for scoreboard ref update.
    // =========================================================================
    class wf_sram_monitor extends uvm_monitor;
        `uvm_component_utils(wf_sram_monitor)

        virtual wf_sram_if #(
            PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
            PKG_MAX_WEIGHTS, PKG_TOTAL_WEIGHTS
        ).mon_mp vif;

        uvm_analysis_port #(wf_sram_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual wf_sram_if #(
                    PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
                    PKG_MAX_WEIGHTS, PKG_TOTAL_WEIGHTS))
                ::get(this, "", "vif", vif))
                `uvm_fatal("WF_MON", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                wf_sram_seq_item item;
                @(vif.cb_mon);

                if (vif.cb_mon.rst) continue;

                // ---- Observe write ----
                if (vif.cb_mon.write_enable) begin
                    if ($isunknown(vif.cb_mon.write_addr)) continue;
                    item            = wf_sram_seq_item::type_id::create("mon_wr");
                    item.is_write   = 1;
                    item.write_addr = vif.cb_mon.write_addr;
                    item.write_data = vif.cb_mon.write_data;
                    item.layer_offset = vif.cb_mon.layer_offset;
                    ap.write(item);
                    `uvm_info("WF_MON", $sformatf("Observed: %s", item.convert2string()), UVM_HIGH)
                end

                // ---- Observe read request ----
                else if (vif.cb_mon.read_request) begin
                    if ($isunknown(vif.cb_mon.burst_length)) continue;

                    item              = wf_sram_seq_item::type_id::create("mon_rd");
                    item.is_write     = 0;
                    item.read_addr    = vif.cb_mon.read_addr;
                    item.layer_offset = vif.cb_mon.layer_offset;
                    item.burst_length = vif.cb_mon.burst_length;

                    // Collect beats until burst_complete
                    collect_burst(item);

                    ap.write(item);
                    `uvm_info("WF_MON", $sformatf("Observed: %s beats=%0d",
                        item.convert2string(), item.read_beats.size()), UVM_MEDIUM)
                end
            end
        endtask

        task collect_burst(wf_sram_seq_item item);
            int unsigned watchdog = 0;
            int unsigned max_cycles = PKG_PIPE_LATENCY + PKG_MAX_BURST_LEN + 8;
            item.burst_complete_seen = 0;

            forever begin
                @(vif.cb_mon);
                watchdog++;

                if (vif.cb_mon.rst) return;

                if (vif.cb_mon.read_valid)
                    item.read_beats.push_back(vif.cb_mon.read_data);

                if (vif.cb_mon.burst_complete) begin
                    item.burst_complete_seen = 1;
                    return;
                end

                if (watchdog > max_cycles) begin
                    `uvm_error("WF_MON", $sformatf(
                        "Watchdog: %0d beats, no burst_complete after %0d cycles",
                        item.read_beats.size(), watchdog))
                    return;
                end
            end
        endtask

    endclass 