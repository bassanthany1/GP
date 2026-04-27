
// conv_controller_tests.svh - UVM Tests for conv_controller
`ifndef CONV_CONTROLLER_TESTS_SVH
`define CONV_CONTROLLER_TESTS_SVH

// Base test
class conv_controller_base_test extends uvm_test;

    conv_controller_env env;
    virtual conv_controller_if vif;

    `uvm_component_utils(conv_controller_base_test)

    function new(string name = "conv_controller_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        env = conv_controller_env::type_id::create("env", this);

        if(!uvm_config_db#(virtual conv_controller_if)::get(this, "", "vif", vif)) begin
            `uvm_fatal("NOVIF", {"virtual interface must be set for: ", get_full_name(), ".vif"});
        end

        uvm_config_db#(virtual conv_controller_if)::set(this, "env.agent", "vif", vif);
    endfunction

    task run_phase(uvm_phase phase);
        super.run_phase(phase);
        phase.raise_objection(this);
        #100ns;
        phase.drop_objection(this);
    endtask
endclass

// Basic test
class conv_controller_basic_test extends conv_controller_base_test;
    `uvm_component_utils(conv_controller_basic_test)

    function new(string name = "conv_controller_basic_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        conv_controller_basic_seq seq;

        super.run_phase(phase);
        phase.raise_objection(this);

        `uvm_info("TEST", "Starting basic test", UVM_LOW)

        seq = conv_controller_basic_seq::type_id::create("seq");
        seq.start(env.agent.sequencer);

        phase.drop_objection(this);
    endtask
endclass

// Random test
class conv_controller_random_test extends conv_controller_base_test;
    `uvm_component_utils(conv_controller_random_test)

    function new(string name = "conv_controller_random_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        conv_controller_random_seq seq;

        super.run_phase(phase);
        phase.raise_objection(this);

        `uvm_info("TEST", "Starting random test", UVM_LOW)

        seq = conv_controller_random_seq::type_id::create("seq");
        seq.start(env.agent.sequencer);

        phase.drop_objection(this);
    endtask
endclass

// FC mode test
class conv_controller_fc_test extends conv_controller_base_test;
    `uvm_component_utils(conv_controller_fc_test)

    function new(string name = "conv_controller_fc_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        conv_controller_fc_seq seq;

        super.run_phase(phase);
        phase.raise_objection(this);

        `uvm_info("TEST", "Starting FC mode test", UVM_LOW)

        seq = conv_controller_fc_seq::type_id::create("seq");
        seq.start(env.agent.sequencer);

        phase.drop_objection(this);
    endtask
endclass

// Max parameters test
class conv_controller_max_params_test extends conv_controller_base_test;
    `uvm_component_utils(conv_controller_max_params_test)

    function new(string name = "conv_controller_max_params_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        conv_controller_max_params_seq seq;

        super.run_phase(phase);
        phase.raise_objection(this);

        `uvm_info("TEST", "Starting max parameters test", UVM_LOW)

        seq = conv_controller_max_params_seq::type_id::create("seq");
        seq.start(env.agent.sequencer);

        phase.drop_objection(this);
    endtask
endclass

// Small parameters test - enhances coverage for small parameter ranges
class conv_controller_small_params_seq extends conv_controller_base_seq;
    `uvm_object_utils(conv_controller_small_params_seq)

    int num_transactions;

    function new(string name = "conv_controller_small_params_seq");
        super.new(name);
        num_transactions = 10;
    endfunction

    task body();
        conv_controller_seq_item item;

        repeat(num_transactions) begin
            item = conv_controller_seq_item::type_id::create("item");
            start_item(item);
            if(!item.randomize() with {
                kernel_size inside {[3:3]};
                out_channels inside {[1:16]};
                input_height inside {[5:10]};
                input_width inside {[5:10]};
                fc_mode dist {0 := 7, 1 := 3};
            }) begin
                `uvm_error("SEQ", "Randomization failed for small params sequence")
            end
            finish_item(item);
        end
    endtask
endclass

class conv_controller_small_params_test extends conv_controller_base_test;
    `uvm_component_utils(conv_controller_small_params_test)

    function new(string name = "conv_controller_small_params_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        conv_controller_small_params_seq seq;

        super.run_phase(phase);
        phase.raise_objection(this);

        `uvm_info("TEST", "Starting small parameters test", UVM_LOW)

        seq = conv_controller_small_params_seq::type_id::create("seq");
        seq.start(env.agent.sequencer);

        phase.drop_objection(this);
    endtask
endclass

// Medium parameters test - enhances coverage for medium parameter ranges
class conv_controller_medium_params_seq extends conv_controller_base_seq;
    `uvm_object_utils(conv_controller_medium_params_seq)

    int num_transactions;

    function new(string name = "conv_controller_medium_params_seq");
        super.new(name);
        num_transactions = 10;
    endfunction

    task body();
        conv_controller_seq_item item;

        repeat(num_transactions) begin
            item = conv_controller_seq_item::type_id::create("item");
            start_item(item);
            if(!item.randomize() with {
                kernel_size inside {[3:5]};
                out_channels inside {[17:64]};
                input_height inside {[11:20]};
                input_width inside {[11:20]};
                fc_mode dist {0 := 8, 1 := 2};
            }) begin
                `uvm_error("SEQ", "Randomization failed for medium params sequence")
            end
            finish_item(item);
        end
    endtask
endclass

class conv_controller_medium_params_test extends conv_controller_base_test;
    `uvm_component_utils(conv_controller_medium_params_test)

    function new(string name = "conv_controller_medium_params_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        conv_controller_medium_params_seq seq;

        super.run_phase(phase);
        phase.raise_objection(this);

        `uvm_info("TEST", "Starting medium parameters test", UVM_LOW)

        seq = conv_controller_medium_params_seq::type_id::create("seq");
        seq.start(env.agent.sequencer);

        phase.drop_objection(this);
    endtask
endclass

// Boundary values test - enhances coverage for boundary parameter values
class conv_controller_boundary_seq extends conv_controller_base_seq;
    `uvm_object_utils(conv_controller_boundary_seq)

    function new(string name = "conv_controller_boundary_seq");
        super.new(name);
    endfunction

    task body();
        conv_controller_seq_item item;

        // Test minimum values
        item = conv_controller_seq_item::type_id::create("item");
        start_item(item);
        if(!item.randomize() with {
            kernel_size == 3;
            out_channels == 1;
            input_height == 5;
            input_width == 5;
            fc_mode == 0;
        }) begin
            `uvm_error("SEQ", "Randomization failed for minimum values")
        end
        finish_item(item);

        // Test maximum values
        item = conv_controller_seq_item::type_id::create("item");
        start_item(item);
        if(!item.randomize() with {
            kernel_size == 5;
            out_channels == 120;
            input_height == 28;
            input_width == 28;
            fc_mode == 0;
        }) begin
            `uvm_error("SEQ", "Randomization failed for maximum values")
        end
        finish_item(item);

        // Test FC mode with maximum values
        item = conv_controller_seq_item::type_id::create("item");
        start_item(item);
        if(!item.randomize() with {
            kernel_size == 5;
            out_channels == 120;
            input_height == 28;
            input_width == 28;
            fc_mode == 1;
        }) begin
            `uvm_error("SEQ", "Randomization failed for FC mode max values")
        end
        finish_item(item);

        // Test kernel_size=3 with maximum channels
        item = conv_controller_seq_item::type_id::create("item");
        start_item(item);
        if(!item.randomize() with {
            kernel_size == 3;
            out_channels == 120;
            input_height == 28;
            input_width == 28;
            fc_mode == 0;
        }) begin
            `uvm_error("SEQ", "Randomization failed for kernel_size=3 max channels")
        end
        finish_item(item);
    endtask
endclass

class conv_controller_boundary_test extends conv_controller_base_test;
    `uvm_component_utils(conv_controller_boundary_test)

    function new(string name = "conv_controller_boundary_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        conv_controller_boundary_seq seq;

        super.run_phase(phase);
        phase.raise_objection(this);

        `uvm_info("TEST", "Starting boundary values test", UVM_LOW)

        seq = conv_controller_boundary_seq::type_id::create("seq");
        seq.start(env.agent.sequencer);

        phase.drop_objection(this);
    endtask
endclass



class conv_controller_mixed_mode_test extends conv_controller_base_test;
    `uvm_component_utils(conv_controller_mixed_mode_test)

    function new(string name = "conv_controller_mixed_mode_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        conv_controller_mixed_mode_seq seq;

        super.run_phase(phase);
        phase.raise_objection(this);

        `uvm_info("TEST", "Starting mixed mode test", UVM_LOW)

        seq = conv_controller_mixed_mode_seq::type_id::create("seq");
        seq.start(env.agent.sequencer);

        phase.drop_objection(this);
    endtask
endclass



class conv_controller_high_stress_test extends conv_controller_base_test;
    `uvm_component_utils(conv_controller_high_stress_test)

    function new(string name = "conv_controller_high_stress_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        conv_controller_high_stress_seq seq;

        super.run_phase(phase);
        phase.raise_objection(this);

        `uvm_info("TEST", "Starting high stress test", UVM_LOW)

        seq = conv_controller_high_stress_seq::type_id::create("seq");
        seq.start(env.agent.sequencer);

        phase.drop_objection(this);
    endtask
endclass

// My test class - collects all existing tests in a single test
class my_test extends conv_controller_base_test;
    `uvm_component_utils(my_test)

    function new(string name = "my_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        conv_controller_basic_seq basic_seq;
        conv_controller_random_seq random_seq;
        conv_controller_fc_seq fc_seq;
        conv_controller_max_params_seq max_params_seq;
        conv_controller_small_params_seq small_params_seq;
        conv_controller_medium_params_seq medium_params_seq;
        conv_controller_boundary_seq boundary_seq;
        conv_controller_mixed_mode_seq mixed_mode_seq;
        conv_controller_high_stress_seq high_stress_seq;

        super.run_phase(phase);
        phase.raise_objection(this);

        `uvm_info("TEST", "============================================", UVM_LOW)
        `uvm_info("TEST", "Starting my_test - Running all test scenarios", UVM_LOW)
        `uvm_info("TEST", "============================================", UVM_LOW)

        // Run basic test
        `uvm_info("TEST", "Running basic test scenario", UVM_LOW)
        basic_seq = conv_controller_basic_seq::type_id::create("basic_seq");
        basic_seq.start(env.agent.sequencer);

        // Run random test
        `uvm_info("TEST", "Running random test scenario", UVM_LOW)
        random_seq = conv_controller_random_seq::type_id::create("random_seq");
        random_seq.start(env.agent.sequencer);

        // Run FC mode test
        `uvm_info("TEST", "Running FC mode test scenario", UVM_LOW)
        fc_seq = conv_controller_fc_seq::type_id::create("fc_seq");
        fc_seq.start(env.agent.sequencer);

        // Run max parameters test
        `uvm_info("TEST", "Running max parameters test scenario", UVM_LOW)
        max_params_seq = conv_controller_max_params_seq::type_id::create("max_params_seq");
        max_params_seq.start(env.agent.sequencer);

        // Run small parameters test
        `uvm_info("TEST", "Running small parameters test scenario", UVM_LOW)
        small_params_seq = conv_controller_small_params_seq::type_id::create("small_params_seq");
        small_params_seq.start(env.agent.sequencer);

        // Run medium parameters test
        `uvm_info("TEST", "Running medium parameters test scenario", UVM_LOW)
        medium_params_seq = conv_controller_medium_params_seq::type_id::create("medium_params_seq");
        medium_params_seq.start(env.agent.sequencer);

        // Run boundary values test
        `uvm_info("TEST", "Running boundary values test scenario", UVM_LOW)
        boundary_seq = conv_controller_boundary_seq::type_id::create("boundary_seq");
        boundary_seq.start(env.agent.sequencer);

        // Run mixed mode test
        `uvm_info("TEST", "Running mixed mode test scenario", UVM_LOW)
        mixed_mode_seq = conv_controller_mixed_mode_seq::type_id::create("mixed_mode_seq");
        mixed_mode_seq.start(env.agent.sequencer);

        // Run high stress test
        `uvm_info("TEST", "Running high stress test scenario", UVM_LOW)
        high_stress_seq = conv_controller_high_stress_seq::type_id::create("high_stress_seq");
        high_stress_seq.start(env.agent.sequencer);

        `uvm_info("TEST", "============================================", UVM_LOW)
        `uvm_info("TEST", "my_test completed - All test scenarios executed", UVM_LOW)
        `uvm_info("TEST", "============================================", UVM_LOW)

        phase.drop_objection(this);
    endtask
endclass

`endif // CONV_CONTROLLER_TESTS_SVH
