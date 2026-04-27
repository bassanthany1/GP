
// conv_controller_monitor.svh - UVM Monitor for conv_controller
`ifndef CONV_CONTROLLER_MONITOR_SVH
`define CONV_CONTROLLER_MONITOR_SVH

class conv_controller_monitor extends uvm_monitor;

    virtual conv_controller_if vif;
    uvm_analysis_port #(conv_controller_seq_item) item_collected_port;

    `uvm_component_utils(conv_controller_monitor)

    function new(string name = "conv_controller_monitor", uvm_component parent = null);
        super.new(name, parent);
        item_collected_port = new("item_collected_port", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if(!uvm_config_db#(virtual conv_controller_if)::get(this, "", "vif", vif)) begin
            `uvm_fatal("NOVIF", {"virtual interface must be set for: ", get_full_name(), ".vif"});
        end
    endfunction

    task run_phase(uvm_phase phase);
        conv_controller_seq_item trans;
        trans = conv_controller_seq_item::type_id::create("trans");

        forever begin
            @(posedge vif.clk);

            // Wait for start_conv
            wait(vif.monitor_cb.start_conv == 1);

            // Capture input signals
            trans.kernel_size = vif.monitor_cb.kernel_size;
            trans.out_channels = vif.monitor_cb.out_channels;
            trans.input_height = vif.monitor_cb.input_height;
            trans.input_width = vif.monitor_cb.input_width;
            trans.fc_mode = vif.monitor_cb.fc_mode;

            // Wait for output_valid
            wait(vif.monitor_cb.output_valid == 1);

            // Capture output signals
            trans.output_valid = vif.monitor_cb.output_valid;
            trans.output_channel_start = vif.monitor_cb.output_channel_start;
            trans.output_window_idx_start = vif.monitor_cb.output_window_idx_start;

            for(int i = 0; i < 4; i++) begin
                for(int j = 0; j < 4; j++) begin
                    trans.output_data[i][j] = vif.monitor_cb.output_data[i][j];
                end
            end

            // Wait for conv_done
            wait(vif.monitor_cb.conv_done == 1);
            trans.conv_done = vif.monitor_cb.conv_done;

            // Send transaction to scoreboard
            item_collected_port.write(trans);
        end
    endtask

endclass

`endif // CONV_CONTROLLER_MONITOR_SVH
