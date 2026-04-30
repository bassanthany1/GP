    // =========================================================================
    // 7. AGENT
    // =========================================================================
    class fm_agent extends uvm_agent;
        `uvm_component_utils(fm_agent)

        uvm_sequencer #(fm_seq_item) sequencer;
        fm_driver                    driver;
        fm_monitor                   monitor;

        uvm_analysis_port #(fm_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor = fm_monitor::type_id::create("monitor", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sequencer = uvm_sequencer #(fm_seq_item)
                            ::type_id::create("sequencer", this);
                driver    = fm_driver::type_id::create("driver", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            ap = monitor.ap;
            if (get_is_active() == UVM_ACTIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction

    endclass 