
    // =========================================================================
    // 11. BASE TEST
    // =========================================================================
    class br_base_test extends uvm_test;
        `uvm_component_utils(br_base_test)

        br_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = br_env::type_id::create("env", this);
        endfunction

        function uvm_sequencer #(br_seq_item) get_sequencer();
            return env.agent.sequencer;
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction

    endclass 


    // =========================================================================
    // 12. TESTS
    // =========================================================================
    class br_smoke_test extends br_base_test;
        `uvm_component_utils(br_smoke_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_smoke_seq seq = br_smoke_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class br_relu_test extends br_base_test;
        `uvm_component_utils(br_relu_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_relu_seq seq = br_relu_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class br_padding_test extends br_base_test;
        `uvm_component_utils(br_padding_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_padding_seq seq = br_padding_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class br_window_test extends br_base_test;
        `uvm_component_utils(br_window_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_window_seq seq = br_window_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class br_back2back_test extends br_base_test;
        `uvm_component_utils(br_back2back_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_back2back_seq seq = br_back2back_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class br_rand_test extends br_base_test;
        `uvm_component_utils(br_rand_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_rand_seq seq = br_rand_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.num_items = 30;
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class br_regression_test extends br_base_test;
        `uvm_component_utils(br_regression_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_regression_seq seq = br_regression_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    // Full test: all directed suites then heavy random
    class br_full_test extends br_base_test;
        `uvm_component_utils(br_full_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction

        task run_phase(uvm_phase phase);
            br_smoke_seq     smoke = br_smoke_seq    ::type_id::create("smoke");
            br_relu_seq      relu  = br_relu_seq     ::type_id::create("relu");
            br_padding_seq   pad   = br_padding_seq  ::type_id::create("pad");
            br_window_seq    win   = br_window_seq   ::type_id::create("win");
            br_back2back_seq b2b   = br_back2back_seq::type_id::create("b2b");
            br_rand_seq      rnd   = br_rand_seq     ::type_id::create("rnd");

            phase.raise_objection(this);

            `uvm_info("BR_FULL", "=== PHASE 1: Smoke ===", UVM_NONE)
            smoke.start(get_sequencer());

            `uvm_info("BR_FULL", "=== PHASE 2: ReLU Boundary ===", UVM_NONE)
            relu.start(get_sequencer());

            `uvm_info("BR_FULL", "=== PHASE 3: Padding Columns ===", UVM_NONE)
            pad.start(get_sequencer());

            `uvm_info("BR_FULL", "=== PHASE 4: Window Idx Passthrough ===", UVM_NONE)
            win.start(get_sequencer());

            `uvm_info("BR_FULL", "=== PHASE 5: Back-to-Back ===", UVM_NONE)
            b2b.start(get_sequencer());

            `uvm_info("BR_FULL", "=== PHASE 6: Constrained Random (100) ===", UVM_NONE)
            rnd.num_items = 100;
            rnd.start(get_sequencer());

            phase.drop_objection(this);
            `uvm_info("BR_FULL", "=== FULL TEST COMPLETE ===", UVM_NONE)
        endtask

    endclass