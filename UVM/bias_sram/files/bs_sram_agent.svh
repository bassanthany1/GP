    // =========================================================================
    // 7. AGENT
    // =========================================================================
    class bs_sram_agent extends uvm_agent;
        `uvm_component_utils(bs_sram_agent)

        uvm_sequencer #(bs_sram_seq_item) sequencer;
        bs_sram_driver                    driver;
        bs_sram_monitor                   monitor;

        uvm_analysis_port #(bs_sram_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor = bs_sram_monitor::type_id::create("monitor", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sequencer = uvm_sequencer #(bs_sram_seq_item)
                            ::type_id::create("sequencer", this);
                driver    = bs_sram_driver::type_id::create("driver", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            ap = monitor.ap;
            if (get_is_active() == UVM_ACTIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction

    endclass