
// conv_controller_agent.svh - UVM Agent for conv_controller
`ifndef CONV_CONTROLLER_AGENT_SVH
`define CONV_CONTROLLER_AGENT_SVH

class conv_controller_agent extends uvm_agent;

    conv_controller_driver driver;
    conv_controller_monitor monitor;
    uvm_sequencer #(conv_controller_seq_item) sequencer;

    virtual conv_controller_if vif;

    `uvm_component_utils(conv_controller_agent)

    function new(string name = "conv_controller_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Set agent as active
        //set_is_active(UVM_ACTIVE);

        if(!uvm_config_db#(virtual conv_controller_if)::get(this, "", "vif", vif)) begin
            `uvm_fatal("NOVIF", {"virtual interface must be set for: ", get_full_name(), ".vif"});
        end

        monitor = conv_controller_monitor::type_id::create("monitor", this);

        if(get_is_active() == UVM_ACTIVE) begin
            sequencer = uvm_sequencer #(conv_controller_seq_item)::type_id::create("sequencer", this);
            driver = conv_controller_driver::type_id::create("driver", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        if(get_is_active() == UVM_ACTIVE) begin
            driver.seq_item_port.connect(sequencer.seq_item_export);
        end
    endfunction

endclass

`endif // CONV_CONTROLLER_AGENT_SVH
