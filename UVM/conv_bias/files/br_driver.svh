    // =========================================================================
    // 3. DRIVER
    // =========================================================================
    // Drives conv stimulus and responds to bias SRAM burst requests.
    //
    // Protocol:
    //   1. Wait for DUT to be idle (output_valid low, no pending request).
    //   2. Assert conv_valid for one cycle with the conv_data tile.
    //   3. Monitor bias_sram_read_req – when asserted, stream back
    //      bias_sram_data one per cycle with bias_sram_valid, then pulse
    //      bias_sram_burst_done.
    //   4. Wait for output_valid from DUT (signalling the monitor to latch).
    // =========================================================================
    class br_driver extends uvm_driver #(br_seq_item);
        `uvm_component_utils(br_driver)

        virtual br_if vif;

        br_ref_model drv_ref;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv_ref = br_ref_model::type_id::create("drv_ref");
            if (!uvm_config_db #(virtual br_if)::get(this, "", "vif", vif))
                `uvm_fatal("BR_DRV", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            br_seq_item item;
            apply_reset();
            forever begin
                seq_item_port.get_next_item(item);
                drive_transaction(item);
                seq_item_port.item_done();
            end
        endtask

        // ---- Reset ----
        task apply_reset();
            vif.cb_drv.rst                   <= 1'b1;
            vif.cb_drv.enable_relu           <= 1'b0;
            vif.cb_drv.out_channels          <= '0;
            vif.cb_drv.conv_valid            <= 1'b0;
            vif.cb_drv.conv_channel_start    <= '0;
            vif.cb_drv.conv_window_idx_start <= '0;
            vif.cb_drv.bias_sram_data        <= '0;
            vif.cb_drv.bias_sram_valid       <= 1'b0;
            vif.cb_drv.bias_sram_burst_done  <= 1'b0;
            foreach (vif.cb_drv.conv_data[r,c])
                vif.cb_drv.conv_data[r][c] <= '0;
            repeat (5) @(vif.cb_drv);
            vif.cb_drv.rst <= 1'b0;
            repeat (3) @(vif.cb_drv);
        endtask

        // ---- Drive one full transaction ----
        task drive_transaction(br_seq_item item);
            // Compute expected output BEFORE driving (ref model)
            drv_ref.predict(item);

            // Set static inputs
            vif.cb_drv.enable_relu  <= item.enable_relu;
            vif.cb_drv.out_channels <= item.out_channels;
            @(vif.cb_drv);

            // Pulse conv_valid for exactly one cycle
            vif.cb_drv.conv_valid            <= 1'b1;
            vif.cb_drv.conv_channel_start    <= item.conv_channel_start;
            vif.cb_drv.conv_window_idx_start <= item.conv_window_idx_start;
            foreach (vif.cb_drv.conv_data[r,c])
                vif.cb_drv.conv_data[r][c] <= item.conv_data[r][c];
            @(vif.cb_drv);
            vif.cb_drv.conv_valid <= 1'b0;

            // Wait for DUT to request bias burst, then service it
            service_bias_burst(item);

            // Wait for output_valid (monitor will capture the actual data)
            wait_output_valid();

            // Small idle gap between transactions
            repeat (2) @(vif.cb_drv);

            `uvm_info("BR_DRV", $sformatf("Drove: %s", item.convert2string()), UVM_MEDIUM)
        endtask

        // ---- Service one bias SRAM burst ----
        // DUT asserts bias_sram_read_req, provides addr & burst_len.
        // Driver responds with bias_sram_valid + data for each beat,
        // then asserts bias_sram_burst_done for one cycle.
        task service_bias_burst(br_seq_item item);
            int unsigned burst_len;
            int unsigned watchdog = 0;
            int unsigned max_wait = 20;

            // Wait for bias_sram_read_req
            while (!vif.cb_drv.bias_sram_read_req) begin
                @(vif.cb_drv);
                watchdog++;
                if (watchdog > max_wait)
                    `uvm_fatal("BR_DRV", "Timeout waiting for bias_sram_read_req")
            end

            burst_len = int'(vif.cb_drv.bias_sram_burst_len);
            @(vif.cb_drv); // req was seen this cycle; data starts next

            // Stream burst_len beats with bias_sram_valid
            for (int i = 0; i < int'(burst_len); i++) begin
                vif.cb_drv.bias_sram_valid <= 1'b1;
                // Use bias_values[i] for valid columns; wrap if burst > ARRAY_COLS
                vif.cb_drv.bias_sram_data  <=
                    (i < PKG_ARRAY_COLS) ? item.bias_values[i] :
                                           item.bias_values[PKG_ARRAY_COLS-1];
                @(vif.cb_drv);
            end
            vif.cb_drv.bias_sram_valid <= 1'b0;

            // Pulse burst_done
            vif.cb_drv.bias_sram_burst_done <= 1'b1;
            @(vif.cb_drv);
            vif.cb_drv.bias_sram_burst_done <= 1'b0;
        endtask

        // ---- Wait for output_valid from DUT ----
        task wait_output_valid();
            int unsigned watchdog = 0;
            int unsigned max_wait = 50;
            while (!vif.cb_drv.output_valid) begin
                @(vif.cb_drv);
                watchdog++;
                if (watchdog > max_wait)
                    `uvm_fatal("BR_DRV", "Timeout waiting for output_valid")
            end
        endtask

    endclass