    // =========================================================================
    // 3. DRIVER
    // =========================================================================
    // Drives one item per DUT clock cycle (writes OR reads).
    // For write items:   asserts wr_en for 1 cycle, deasserts, updates ref.
    // For read items:    drives rd_req/rd_addr, optionally also wr_en
    //                    (conflict injection), then waits 1 cycle for outputs.
    // =========================================================================
    class fm_driver extends uvm_driver #(fm_seq_item);
        `uvm_component_utils(fm_driver)

        virtual fm_if vif;
        fm_ref_model drv_ref;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv_ref = fm_ref_model::type_id::create("drv_ref");
            if (!uvm_config_db #(virtual fm_if)::get(this, "", "vif", vif))
                `uvm_fatal("FM_DRV", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            fm_seq_item item;
            apply_reset();
            forever begin
                seq_item_port.get_next_item(item);
                if (item.is_write) drive_write(item);
                else               drive_read(item);
                seq_item_port.item_done();
            end
        endtask

        // ---- Reset ----
        task apply_reset();
            vif.cb_drv.rst    <= 1'b1;
            vif.cb_drv.wr_en  <= 1'b0;
            vif.cb_drv.wr_addr <= '0;
            vif.cb_drv.wr_data <= '0;
            for (int p = 0; p < PKG_NUM_PORTS; p++) begin
                vif.cb_drv.rd_req [p] <= 1'b0;
                vif.cb_drv.rd_addr[p] <= '0;
            end
            repeat (5) @(vif.cb_drv);
            vif.cb_drv.rst <= 1'b0;
            repeat (2) @(vif.cb_drv);
        endtask

        // ---- Write transaction ----
        // Cycle 0: drive addr+data, wr_en low
        // Cycle 1: assert wr_en
        // Cycle 2: deassert wr_en, update ref model
        task drive_write(fm_seq_item item);
            // Cycle 0: setup
            vif.cb_drv.wr_addr <= item.wr_addr;
            vif.cb_drv.wr_data <= item.wr_data;
            vif.cb_drv.wr_en   <= 1'b0;
            deassert_reads();
            @(vif.cb_drv);

            // Cycle 1: commit
            vif.cb_drv.wr_en <= 1'b1;
            @(vif.cb_drv);

            // Cycle 2: deassert
            vif.cb_drv.wr_en <= 1'b0;
            @(vif.cb_drv);

            // Update shadow
            drv_ref.write(int'(item.wr_addr), item.wr_data);

            `uvm_info("FM_DRV",
                $sformatf("Drove: %s", item.convert2string()), UVM_HIGH)
        endtask

        // ---- Read transaction ----
        // Cycle 0: drive rd_req/rd_addr (+ optional concurrent wr_en).
        //          Compute expected values from current shadow state.
        // Cycle 1: deassert everything; monitor captures outputs this cycle.
        // Cycle 2: idle gap.
        task drive_read(fm_seq_item item);
            // Snapshot expected BEFORE driving
            drv_ref.predict_read(item);

            // Cycle 0: assert stimulus
            for (int p = 0; p < PKG_NUM_PORTS; p++) begin
                vif.cb_drv.rd_req [p] <= item.rd_req[p];
                vif.cb_drv.rd_addr[p] <= item.rd_addr[p];
            end

            if (item.wr_en_during_read) begin
                vif.cb_drv.wr_en   <= 1'b1;
                vif.cb_drv.wr_addr <= item.wr_addr_during_read;
                vif.cb_drv.wr_data <= item.wr_data_during_read;
            end else begin
                vif.cb_drv.wr_en <= 1'b0;
            end
            @(vif.cb_drv);

            // Cycle 1: deassert – monitor sees rd_valid/rd_data this cycle
            deassert_reads();
            vif.cb_drv.wr_en <= 1'b0;

            // If concurrent write happened, update shadow AFTER the read snapshot
            // (write takes effect on clock edge, read data comes from pre-write value)
            if (item.wr_en_during_read)
                drv_ref.write(int'(item.wr_addr_during_read),
                              item.wr_data_during_read);
            @(vif.cb_drv);

            // Cycle 2: idle
            @(vif.cb_drv);

            `uvm_info("FM_DRV",
                $sformatf("Drove: %s", item.convert2string()), UVM_MEDIUM)
        endtask

        task deassert_reads();
            for (int p = 0; p < PKG_NUM_PORTS; p++)
                vif.cb_drv.rd_req[p] <= 1'b0;
        endtask

    endclass 