    // =========================================================================
    // 7. AGENT
    // =========================================================================
    class br_agent extends uvm_agent;
        `uvm_component_utils(br_agent)

        uvm_sequencer #(br_seq_item) sequencer;
        br_driver                    driver;
        br_monitor                   monitor;

        uvm_analysis_port #(br_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor = br_monitor::type_id::create("monitor", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sequencer = uvm_sequencer #(br_seq_item)
                            ::type_id::create("sequencer", this);
                driver    = br_driver::type_id::create("driver", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            ap = monitor.ap;
            if (get_is_active() == UVM_ACTIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction

    endclass