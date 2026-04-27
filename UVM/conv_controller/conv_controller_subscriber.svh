
// conv_controller_subscriber.svh - UVM Subscriber for conv_controller
`ifndef CONV_CONTROLLER_SUBSCRIBER_SVH
`define CONV_CONTROLLER_SUBSCRIBER_SVH

class conv_controller_subscriber extends uvm_subscriber #(conv_controller_seq_item);

    int transaction_count;

    // Coverage group
    covergroup conv_controller_cg;
        // Kernel size coverage
        cp_kernel_size: coverpoint transaction.kernel_size {
            bins kernel_3 = {3};
            bins kernel_5 = {5};
            bins kernel_other = default;
        }

        // Output channels coverage
        cp_out_channels: coverpoint transaction.out_channels {
            bins small_channels[] = {[1:16]};
            bins medium_channels[] = {[17:64]};
            bins large_channels[] = {[65:120]};
        }

        // Input dimensions coverage
        cp_input_height: coverpoint transaction.input_height {
            bins small_height[] = {[5:10]};
            bins medium_height[] = {[11:20]};
            bins large_height[] = {[21:28]};
        }

        cp_input_width: coverpoint transaction.input_width {
            bins small_width[] = {[5:10]};
            bins medium_width[] = {[11:20]};
            bins large_width[] = {[21:28]};
        }

        // FC mode coverage
        cp_fc_mode: coverpoint transaction.fc_mode {
            bins conv_mode = {0};
            bins fc_mode = {1};
        }

        // Cross coverage
        cross_kernel_fc: cross cp_kernel_size, cp_fc_mode;
        cross_dimensions: cross cp_input_height, cp_input_width;
        cross_channels_kernel: cross cp_out_channels, cp_kernel_size;
    endgroup

    // Transaction for coverage
    conv_controller_seq_item transaction;

    `uvm_component_utils(conv_controller_subscriber)

    function new(string name = "conv_controller_subscriber", uvm_component parent = null);
        super.new(name, parent);
        transaction_count = 0;
        conv_controller_cg = new();
    endfunction

    function void write(conv_controller_seq_item t);
        transaction_count++;

        `uvm_info("SUBSCRIBER", $sformatf("Received transaction #%0d", transaction_count), UVM_HIGH)
        `uvm_info("SUBSCRIBER", $sformatf("  kernel_size: %0d", t.kernel_size), UVM_HIGH)
        `uvm_info("SUBSCRIBER", $sformatf("  out_channels: %0d", t.out_channels), UVM_HIGH)
        `uvm_info("SUBSCRIBER", $sformatf("  input_height: %0d", t.input_height), UVM_HIGH)
        `uvm_info("SUBSCRIBER", $sformatf("  input_width: %0d", t.input_width), UVM_HIGH)
        `uvm_info("SUBSCRIBER", $sformatf("  fc_mode: %0d", t.fc_mode), UVM_HIGH)
        `uvm_info("SUBSCRIBER", $sformatf("  conv_done: %0d", t.conv_done), UVM_HIGH)
        `uvm_info("SUBSCRIBER", $sformatf("  output_valid: %0d", t.output_valid), UVM_HIGH)
        `uvm_info("SUBSCRIBER", $sformatf("  output_channel_start: %0d", t.output_channel_start), UVM_HIGH)
        `uvm_info("SUBSCRIBER", $sformatf("  output_window_idx_start: %0d", t.output_window_idx_start), UVM_HIGH)

        // Log output data
        for(int i = 0; i < 4; i++) begin
            for(int j = 0; j < 4; j++) begin
                `uvm_info("SUBSCRIBER", $sformatf("  output_data[%0d][%0d]: %0d", i, j, t.output_data[i][j]), UVM_HIGH)
            end
        end

        // Sample coverage
        transaction = t;
        conv_controller_cg.sample();
    endfunction

    function void report_phase(uvm_phase phase);
        real overall_coverage;
        real kernel_coverage;
        real channels_coverage;
        real height_coverage;
        real width_coverage;
        real fc_coverage;

        super.report_phase(phase);
        `uvm_info("SUBSCRIBER", $sformatf("Total transactions received: %0d", transaction_count), UVM_LOW)

        // Get coverage values
        kernel_coverage = conv_controller_cg.cp_kernel_size.get_coverage();
        channels_coverage = conv_controller_cg.cp_out_channels.get_coverage();
        height_coverage = conv_controller_cg.cp_input_height.get_coverage();
        width_coverage = conv_controller_cg.cp_input_width.get_coverage();
        fc_coverage = conv_controller_cg.cp_fc_mode.get_coverage();
        overall_coverage = conv_controller_cg.get_coverage();

        // Display detailed coverage summary
        `uvm_info("SUBSCRIBER", "============================================", UVM_LOW)
        `uvm_info("SUBSCRIBER", "          COVERAGE SUMMARY", UVM_LOW)
        `uvm_info("SUBSCRIBER", "============================================", UVM_LOW)
        `uvm_info("SUBSCRIBER", $sformatf("  Individual Coverpoints:"), UVM_LOW)
        `uvm_info("SUBSCRIBER", $sformatf("    kernel_size coverage:    %6.2f%%", kernel_coverage), UVM_LOW)
        `uvm_info("SUBSCRIBER", $sformatf("    out_channels coverage:   %6.2f%%", channels_coverage), UVM_LOW)
        `uvm_info("SUBSCRIBER", $sformatf("    input_height coverage:   %6.2f%%", height_coverage), UVM_LOW)
        `uvm_info("SUBSCRIBER", $sformatf("    input_width coverage:    %6.2f%%", width_coverage), UVM_LOW)
        `uvm_info("SUBSCRIBER", $sformatf("    fc_mode coverage:       %6.2f%%", fc_coverage), UVM_LOW)
        `uvm_info("SUBSCRIBER", "", UVM_LOW)
        `uvm_info("SUBSCRIBER", $sformatf("  Cross Coverage:"), UVM_LOW)
        `uvm_info("SUBSCRIBER", $sformatf("    kernel_size x fc_mode:  %6.2f%%", conv_controller_cg.cross_kernel_fc.get_coverage()), UVM_LOW)
        `uvm_info("SUBSCRIBER", $sformatf("    height x width:         %6.2f%%", conv_controller_cg.cross_dimensions.get_coverage()), UVM_LOW)
        `uvm_info("SUBSCRIBER", $sformatf("    channels x kernel_size:  %6.2f%%", conv_controller_cg.cross_channels_kernel.get_coverage()), UVM_LOW)
        `uvm_info("SUBSCRIBER", "", UVM_LOW)
        `uvm_info("SUBSCRIBER", $sformatf("  Overall Coverage:            %6.2f%%", overall_coverage), UVM_LOW)
        `uvm_info("SUBSCRIBER", "============================================", UVM_LOW)

        // Check if coverage meets minimum threshold
        if(overall_coverage < 80.0) begin
            `uvm_warning("COVERAGE", $sformatf("Coverage is below 80%%: %.2f%%", overall_coverage))
        end else if(overall_coverage < 95.0) begin
            `uvm_info("COVERAGE", $sformatf("Coverage is good: %.2f%%", overall_coverage), UVM_LOW)
        end else begin
            `uvm_info("COVERAGE", $sformatf("Excellent coverage achieved: %.2f%%", overall_coverage), UVM_LOW)
        end
    endfunction

endclass

`endif // CONV_CONTROLLER_SUBSCRIBER_SVH
