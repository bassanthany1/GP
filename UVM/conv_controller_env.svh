
// conv_controller_env.svh - UVM Environment for conv_controller
`ifndef CONV_CONTROLLER_ENV_SVH
`define CONV_CONTROLLER_ENV_SVH

class conv_controller_env extends uvm_env;

    conv_controller_agent agent;
    conv_controller_scoreboard scoreboard;
    conv_controller_subscriber subscriber;

    `uvm_component_utils(conv_controller_env)

    function new(string name = "conv_controller_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        agent = conv_controller_agent::type_id::create("agent", this);
        scoreboard = conv_controller_scoreboard::type_id::create("scoreboard", this);
        subscriber = conv_controller_subscriber::type_id::create("subscriber", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // Connect monitor to scoreboard
        agent.monitor.item_collected_port.connect(scoreboard.item_collected_export);

        // Connect monitor to subscriber
        agent.monitor.item_collected_port.connect(subscriber.analysis_export);
    endfunction

endclass

`endif // CONV_CONTROLLER_ENV_SVH
