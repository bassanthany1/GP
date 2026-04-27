
// conv_controller_scoreboard.svh - UVM Scoreboard for conv_controller
`ifndef CONV_CONTROLLER_SCOREBOARD_SVH
`define CONV_CONTROLLER_SCOREBOARD_SVH

class conv_controller_scoreboard extends uvm_scoreboard;

    uvm_analysis_imp #(conv_controller_seq_item, conv_controller_scoreboard) item_collected_export;

    // Expected values tracking
    logic [$clog2(5+1)-1:0]  expected_kernel_size;
    logic [$clog2(120+1)-1:0] expected_out_channels;
    logic [$clog2(28+1)-1:0] expected_input_height;
    logic [$clog2(28+1)-1:0] expected_input_width;
    logic                    expected_fc_mode;

    int total_transactions;
    int passed_transactions;
    int failed_transactions;

    `uvm_component_utils(conv_controller_scoreboard)

    function new(string name = "conv_controller_scoreboard", uvm_component parent = null);
        super.new(name, parent);
        item_collected_export = new("item_collected_export", this);
        total_transactions = 0;
        passed_transactions = 0;
        failed_transactions = 0;
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
    endfunction

    function void write(conv_controller_seq_item trans);
        logic [$clog2(28*28+1)-1:0] max_windows;

        total_transactions++;

        `uvm_info("SCOREBOARD", $sformatf("Transaction #%0d: kernel_size=%0d, out_channels=%0d, input_height=%0d, input_width=%0d, fc_mode=%0d",
            total_transactions, trans.kernel_size, trans.out_channels, trans.input_height, trans.input_width, trans.fc_mode), UVM_LOW)

        // Store expected values
        expected_kernel_size = trans.kernel_size;
        expected_out_channels = trans.out_channels;
        expected_input_height = trans.input_height;
        expected_input_width = trans.input_width;
        expected_fc_mode = trans.fc_mode;

        // Verify conv_done signal
        if(trans.conv_done == 1'b1) begin
            `uvm_info("SCOREBOARD", "conv_done signal is correct", UVM_LOW)
            passed_transactions++;
        end else begin
            `uvm_error("SCOREBOARD", "conv_done signal is not asserted")
            failed_transactions++;
        end

        // Verify output_valid signal
        if(trans.output_valid == 1'b1) begin
            `uvm_info("SCOREBOARD", "output_valid signal is correct", UVM_LOW)
        end else begin
            `uvm_error("SCOREBOARD", "output_valid signal is not asserted")
            failed_transactions++;
        end

        // Verify output_channel_start is within valid range
        if(trans.output_channel_start < expected_out_channels) begin
            `uvm_info("SCOREBOARD", $sformatf("output_channel_start=%0d is within valid range [0:%0d]", 
                trans.output_channel_start, expected_out_channels-1), UVM_LOW)
        end else begin
            `uvm_error("SCOREBOARD", $sformatf("output_channel_start=%0d is out of valid range [0:%0d]", 
                trans.output_channel_start, expected_out_channels-1))
            failed_transactions++;
        end

        // Verify output_window_idx_start is within valid range
        max_windows = (expected_input_height - expected_kernel_size + 1) * 
                      (expected_input_width - expected_kernel_size + 1);
        if(trans.output_window_idx_start < max_windows) begin
            `uvm_info("SCOREBOARD", $sformatf("output_window_idx_start=%0d is within valid range [0:%0d]", 
                trans.output_window_idx_start, max_windows-1), UVM_LOW)
        end else begin
            `uvm_error("SCOREBOARD", $sformatf("output_window_idx_start=%0d is out of valid range [0:%0d]", 
                trans.output_window_idx_start, max_windows-1))
            failed_transactions++;
        end

        `uvm_info("SCOREBOARD", $sformatf("Transaction #%0d completed. Passed: %0d, Failed: %0d", 
            total_transactions, passed_transactions, failed_transactions), UVM_LOW)
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("SCOREBOARD", $sformatf("Final Report - Total: %0d, Passed: %0d, Failed: %0d", 
            total_transactions, passed_transactions, failed_transactions), UVM_LOW)
    endfunction

endclass
// Mixed mode test - enhances cross coverage of kernel_size and fc_mode
class conv_controller_mixed_mode_seq extends conv_controller_base_seq;
    `uvm_object_utils(conv_controller_mixed_mode_seq)

    int num_transactions;

    function new(string name = "conv_controller_mixed_mode_seq");
        super.new(name);
        num_transactions = 8;
    endfunction

    task body();
        conv_controller_seq_item item;

        // Test kernel_size=3 with fc_mode=0
        item = conv_controller_seq_item::type_id::create("item");
        start_item(item);
        if(!item.randomize() with {
            kernel_size == 3;
            fc_mode == 0;
            out_channels inside {[1:120]};
            input_height inside {[5:28]};
            input_width inside {[5:28]};
        }) begin
            `uvm_error("SEQ", "Randomization failed for kernel_size=3, fc_mode=0")
        end
        finish_item(item);

        // Test kernel_size=3 with fc_mode=1
        item = conv_controller_seq_item::type_id::create("item");
        start_item(item);
        if(!item.randomize() with {
            kernel_size == 3;
            fc_mode == 1;
            out_channels inside {[1:120]};
            input_height inside {[5:28]};
            input_width inside {[5:28]};
        }) begin
            `uvm_error("SEQ", "Randomization failed for kernel_size=3, fc_mode=1")
        end
        finish_item(item);

        // Test kernel_size=5 with fc_mode=0
        item = conv_controller_seq_item::type_id::create("item");
        start_item(item);
        if(!item.randomize() with {
            kernel_size == 5;
            fc_mode == 0;
            out_channels inside {[1:120]};
            input_height inside {[5:28]};
            input_width inside {[5:28]};
        }) begin
            `uvm_error("SEQ", "Randomization failed for kernel_size=5, fc_mode=0")
        end
        finish_item(item);

        // Test kernel_size=5 with fc_mode=1
        item = conv_controller_seq_item::type_id::create("item");
        start_item(item);
        if(!item.randomize() with {
            kernel_size == 5;
            fc_mode == 1;
            out_channels inside {[1:120]};
            input_height inside {[5:28]};
            input_width inside {[5:28]};
        }) begin
            `uvm_error("SEQ", "Randomization failed for kernel_size=5, fc_mode=1")
        end
        finish_item(item);

        // Additional random transactions to improve coverage
        repeat(num_transactions) begin
            item = conv_controller_seq_item::type_id::create("item");
            start_item(item);
            if(!item.randomize() with {
                kernel_size inside {[3:5]};
                fc_mode dist {0 := 7, 1 := 3};
                out_channels inside {[1:120]};
                input_height inside {[5:28]};
                input_width inside {[5:28]};
            }) begin
                `uvm_error("SEQ", "Randomization failed for mixed mode sequence")
            end
            finish_item(item);
        end
    endtask
endclass

// High stress test - tests with maximum parameter combinations and many transactions
class conv_controller_high_stress_seq extends conv_controller_base_seq;
    `uvm_object_utils(conv_controller_high_stress_seq)

    int num_transactions;

    function new(string name = "conv_controller_high_stress_seq");
        super.new(name);
        num_transactions = 100;  // Large number of transactions for stress testing
    endfunction

    task body();
        conv_controller_seq_item item;
        int kernel_size_values[] = {3, 5};
        int fc_mode_values[] = {0, 1};
        int test_iteration;

        `uvm_info("SEQ", $sformatf("Starting high stress sequence with %0d transactions", num_transactions), UVM_LOW)

        // Test various combinations of kernel_size and fc_mode
        for(int k = 0; k < kernel_size_values.size(); k++) begin
            for(int f = 0; f < fc_mode_values.size(); f++) begin
                // Test with small channels
                repeat(5) begin
                    item = conv_controller_seq_item::type_id::create("item");
                    start_item(item);
                    if(!item.randomize() with {
                        kernel_size == kernel_size_values[k];
                        fc_mode == fc_mode_values[f];
                        out_channels inside {[1:16]};
                        input_height inside {[5:10]};
                        input_width inside {[5:10]};
                    }) begin
                        `uvm_error("SEQ", "Randomization failed for high stress small channels")
                    end
                    finish_item(item);
                end

                // Test with medium channels
                repeat(5) begin
                    item = conv_controller_seq_item::type_id::create("item");
                    start_item(item);
                    if(!item.randomize() with {
                        kernel_size == kernel_size_values[k];
                        fc_mode == fc_mode_values[f];
                        out_channels inside {[17:64]};
                        input_height inside {[11:20]};
                        input_width inside {[11:20]};
                    }) begin
                        `uvm_error("SEQ", "Randomization failed for high stress medium channels")
                    end
                    finish_item(item);
                end

                // Test with large channels
                repeat(5) begin
                    item = conv_controller_seq_item::type_id::create("item");
                    start_item(item);
                    if(!item.randomize() with {
                        kernel_size == kernel_size_values[k];
                        fc_mode == fc_mode_values[f];
                        out_channels inside {[65:120]};
                        input_height inside {[21:28]};
                        input_width inside {[21:28]};
                    }) begin
                        `uvm_error("SEQ", "Randomization failed for high stress large channels")
                    end
                    finish_item(item);
                end
            end
        end

        // Additional random transactions with full parameter range
        repeat(num_transactions - 40) begin
            item = conv_controller_seq_item::type_id::create("item");
            start_item(item);
            if(!item.randomize() with {
                kernel_size inside {[3:5]};
                fc_mode dist {0 := 7, 1 := 3};
                out_channels inside {[1:120]};
                input_height inside {[5:28]};
                input_width inside {[5:28]};
            }) begin
                `uvm_error("SEQ", "Randomization failed for high stress random transactions")
            end
            finish_item(item);
        end

        `uvm_info("SEQ", "High stress sequence completed", UVM_LOW)
    endtask
endclass

`endif // CONV_CONTROLLER_SCOREBOARD_SVH
