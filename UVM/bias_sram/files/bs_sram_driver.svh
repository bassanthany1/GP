   // =========================================================================
    // 3. DRIVER
    // =========================================================================
    class bs_sram_driver extends uvm_driver #(bs_sram_seq_item);
        `uvm_component_utils(bs_sram_driver)

        virtual bs_sram_if #(
            PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
            PKG_MAX_BIASES, PKG_TOTAL_BIASES
        ).drv_mp vif;

        bs_sram_ref_model drv_ref;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv_ref = bs_sram_ref_model::type_id::create("drv_ref");
            if (!uvm_config_db #(virtual bs_sram_if #(
                    PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
                    PKG_MAX_BIASES, PKG_TOTAL_BIASES))
                ::get(this, "", "vif", vif))
                `uvm_fatal("BS_DRV", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            bs_sram_seq_item item;
            apply_reset();
            forever begin
                seq_item_port.get_next_item(item);
                if (item.is_write) drive_write(item);
                else               drive_read(item);
                seq_item_port.item_done();
            end
        endtask

        task apply_reset();
            vif.cb_drv.rst          <= 1'b1;
            vif.cb_drv.write_enable <= 1'b0;
            vif.cb_drv.read_request <= 1'b0;
            vif.cb_drv.layer_offset <= '0;
            vif.cb_drv.write_addr   <= '0;
            vif.cb_drv.write_data   <= '0;
            vif.cb_drv.read_addr    <= '0;
            vif.cb_drv.burst_length <= '0;
            repeat (5) @(vif.cb_drv);
            vif.cb_drv.rst <= 1'b0;
            repeat (3) @(vif.cb_drv);
        endtask

        task drive_write(bs_sram_seq_item item);
            // Cycle 0: drive address/data, keep write_enable low
            vif.cb_drv.layer_offset <= item.layer_offset;
            vif.cb_drv.write_addr   <= item.write_addr;
            vif.cb_drv.write_data   <= item.write_data;
            vif.cb_drv.write_enable <= 1'b0;
            @(vif.cb_drv);

            // Cycle 1: assert write_enable
            vif.cb_drv.write_enable <= 1'b1;
            @(vif.cb_drv);

            // Cycle 2: deassert
            vif.cb_drv.write_enable <= 1'b0;
            @(vif.cb_drv);

            // Update ref model
            drv_ref.write_beat(int'(item.write_addr), item.write_data);

            `uvm_info("BS_DRV", $sformatf("Drove: %s", item.convert2string()), UVM_HIGH)
        endtask

        task drive_read(bs_sram_seq_item item);
            int unsigned abs_addr;
            abs_addr = int'(item.layer_offset) + int'(item.read_addr);

            // Snapshot expected data BEFORE driving (ref model state at req time)
            drv_ref.predict_burst(abs_addr, int'(item.burst_length),
                                  item.expected_beats);

            // Cycle 0: drive address fields, keep read_request low
            vif.cb_drv.layer_offset <= item.layer_offset;
            vif.cb_drv.read_addr    <= item.read_addr;
            vif.cb_drv.burst_length <= item.burst_length;
            vif.cb_drv.read_request <= 1'b0;
            @(vif.cb_drv);

            // Cycle 1: assert read_request (single cycle pulse)
            vif.cb_drv.read_request <= 1'b1;
            @(vif.cb_drv);

            // Cycle 2: deassert, now wait for burst_complete via monitor
            vif.cb_drv.read_request <= 1'b0;

            // Wait for burst_complete — monitor will capture data independently
            do @(vif.cb_drv); while (!vif.cb_drv.burst_complete);

            @(vif.cb_drv); // idle cycle

            `uvm_info("BS_DRV", $sformatf("Drove: %s", item.convert2string()), UVM_MEDIUM)
        endtask

    endclass