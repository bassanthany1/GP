
// conv_controller_driver.svh - UVM Driver for conv_controller
`ifndef CONV_CONTROLLER_DRIVER_SVH
`define CONV_CONTROLLER_DRIVER_SVH

class conv_controller_driver extends uvm_driver #(conv_controller_seq_item);

    virtual conv_controller_if vif;

    `uvm_component_utils(conv_controller_driver)

    function new(string name = "conv_controller_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if(!uvm_config_db#(virtual conv_controller_if)::get(this, "", "vif", vif)) begin
            `uvm_fatal("NOVIF", {"virtual interface must be set for: ", get_full_name(), ".vif"});
        end
    endfunction

    task run_phase(uvm_phase phase);
        reset_dut();
        forever begin
            seq_item_port.get_next_item(req);
            drive_item(req);
            seq_item_port.item_done();
        end
    endtask

    task reset_dut();
        @(posedge vif.clk);
        vif.driver_cb.start_conv <= 0;
        vif.driver_cb.fc_mode <= 0;
        vif.driver_cb.kernel_size <= 0;
        vif.driver_cb.out_channels <= 0;
        vif.driver_cb.input_height <= 0;
        vif.driver_cb.input_width <= 0;
    endtask

    task drive_item(conv_controller_seq_item item);
        @(posedge vif.clk);
        vif.driver_cb.start_conv <= 1;
        vif.driver_cb.fc_mode <= item.fc_mode;
        vif.driver_cb.kernel_size <= item.kernel_size;
        vif.driver_cb.out_channels <= item.out_channels;
        vif.driver_cb.input_height <= item.input_height;
        vif.driver_cb.input_width <= item.input_width;

        @(posedge vif.clk);
        vif.driver_cb.start_conv <= 0;

        // Wait for conv_done to ensure the entire transaction is complete
        wait(vif.monitor_cb.conv_done == 1);

        // Capture systolic_out if available
        for(int i = 0; i < 4; i++) begin
            for(int j = 0; j < 4; j++) begin
                item.systolic_out[i][j] = vif.driver_cb.systolic_out[i][j];
            end
        end

        @(posedge vif.clk);
    endtask

endclass

`endif // CONV_CONTROLLER_DRIVER_SVH
