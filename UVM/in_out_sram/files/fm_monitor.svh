    // =========================================================================
    // 4. MONITOR
    // =========================================================================
    // Watches the interface every clock edge.
    //
    // Observed write: publishes item with is_write=1 for scoreboard ref update.
    // Observed read:  when any rd_req is seen, waits one more cycle for the
    //                 registered outputs (rd_valid / rd_data / bank_conflict),
    //                 then publishes item with all observed fields filled.
    // =========================================================================
    class fm_monitor extends uvm_monitor;
        `uvm_component_utils(fm_monitor)

        virtual fm_if vif;
        uvm_analysis_port #(fm_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual fm_if)::get(this, "", "vif", vif))
                `uvm_fatal("FM_MON", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                fm_seq_item item;
                @(vif.cb_mon);

                if (vif.cb_mon.rst) continue;

                // ---- Observe write ----
if (vif.cb_mon.wr_en && !$isunknown(vif.cb_mon.wr_addr)) begin
    // Check if any read request is active in this cycle
    bit any_read = 0;
    for (int p = 0; p < PKG_NUM_PORTS; p++)
        if (vif.cb_mon.rd_req[p]) any_read = 1;
    // Only create a write item if there is no concurrent read
    if (!any_read) begin
        item          = fm_seq_item::type_id::create("mon_wr");
        item.is_write = 1;
        item.wr_addr  = vif.cb_mon.wr_addr;
        item.wr_data  = vif.cb_mon.wr_data;
        ap.write(item);
        `uvm_info("FM_MON", $sformatf("Observed: %s", item.convert2string()), UVM_HIGH)
    end
end

                // ---- Observe read request ----
                // A read cycle is any cycle where at least one rd_req is high
                // AND wr_en is NOT also high (to avoid double-counting conflict
                // cycles as separate write items – the conflict data is captured
                // inside the read item itself).
                begin
                    bit any_req = 0;
                    for (int p = 0; p < PKG_NUM_PORTS; p++)
                        if (vif.cb_mon.rd_req[p]) any_req = 1;

                    if (any_req) begin
                        // Capture stimulus fields
                        item          = fm_seq_item::type_id::create("mon_rd");
                        item.is_write = 0;
                        for (int p = 0; p < PKG_NUM_PORTS; p++) begin
                            item.rd_req [p] = vif.cb_mon.rd_req [p];
                            item.rd_addr[p] = vif.cb_mon.rd_addr[p];
                        end
                        // Capture concurrent write fields (for conflict scenario)
                        item.wr_en_during_read    = vif.cb_mon.wr_en;
                        item.wr_addr_during_read  = vif.cb_mon.wr_addr;
                        item.wr_data_during_read  = vif.cb_mon.wr_data;

                        // bank_conflict is COMBINATIONAL: capture it NOW on the
                        // stimulus cycle, before advancing the clock.
                        item.obs_bank_conflict = vif.cb_mon.bank_conflict;

                        // Wait one cycle for registered outputs (rd_valid / rd_data)
                        @(vif.cb_mon);

                        // Capture DUT registered outputs
                        for (int p = 0; p < PKG_NUM_PORTS; p++) begin
                            item.obs_rd_data [p] = vif.cb_mon.rd_data [p];
                            item.obs_rd_valid[p] = vif.cb_mon.rd_valid[p];
                        end
                        // bank_conflict already captured above (do NOT re-sample)

                        ap.write(item);
                        `uvm_info("FM_MON",
                            $sformatf("Observed: %s conflict=%0b",
                                item.convert2string(), item.obs_bank_conflict),
                            UVM_MEDIUM)
                    end
                end
            end
        endtask

    endclass 