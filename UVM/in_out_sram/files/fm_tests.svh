    // =========================================================================
    // 11. BASE TEST
    // =========================================================================
    class fm_base_test extends uvm_test;
        `uvm_component_utils(fm_base_test)

        fm_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = fm_env::type_id::create("env", this);
        endfunction

        function uvm_sequencer #(fm_seq_item) get_sequencer();
            return env.agent.sequencer;
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction

    endclass 


    // =========================================================================
    // 12. TESTS
    // =========================================================================
    class fm_smoke_test extends fm_base_test;
        `uvm_component_utils(fm_smoke_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_smoke_seq seq = fm_smoke_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_multiport_test extends fm_base_test;
        `uvm_component_utils(fm_multiport_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_multiport_seq seq = fm_multiport_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_conflict_test extends fm_base_test;
        `uvm_component_utils(fm_conflict_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_conflict_seq seq = fm_conflict_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_no_conflict_test extends fm_base_test;
        `uvm_component_utils(fm_no_conflict_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_no_conflict_seq seq = fm_no_conflict_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_addr_sweep_test extends fm_base_test;
        `uvm_component_utils(fm_addr_sweep_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_addr_sweep_seq seq = fm_addr_sweep_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_bank_boundary_test extends fm_base_test;
        `uvm_component_utils(fm_bank_boundary_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_bank_boundary_seq seq = fm_bank_boundary_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_rand_test extends fm_base_test;
        `uvm_component_utils(fm_rand_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_rand_seq seq = fm_rand_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.num_writes = 30; seq.num_reads = 60;
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_regression_test extends fm_base_test;
        `uvm_component_utils(fm_regression_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_regression_seq seq = fm_regression_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    // Full test – all suites in order, heavy random at end
    class fm_full_test extends fm_base_test;
        `uvm_component_utils(fm_full_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction

        task run_phase(uvm_phase phase);
            fm_smoke_seq         smoke  = fm_smoke_seq        ::type_id::create("smoke");
            fm_multiport_seq     mport  = fm_multiport_seq    ::type_id::create("mport");
            fm_conflict_seq      conf   = fm_conflict_seq     ::type_id::create("conf");
            fm_no_conflict_seq   noconf = fm_no_conflict_seq  ::type_id::create("noconf");
            fm_addr_sweep_seq    sweep  = fm_addr_sweep_seq   ::type_id::create("sweep");
            fm_bank_boundary_seq bndry  = fm_bank_boundary_seq::type_id::create("bndry");
            fm_bank_pattern_seq  pat    = fm_bank_pattern_seq ::type_id::create("pat");   // NEW
            fm_rand_seq          rnd    = fm_rand_seq         ::type_id::create("rnd");

            phase.raise_objection(this);

            `uvm_info("FM_FULL", "=== PHASE 1: Smoke ===", UVM_NONE)
            smoke.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 2: Multi-Port Combinations ===", UVM_NONE)
            mport.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 3: Bank Conflict Detection ===", UVM_NONE)
            conf.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 4: No-Conflict Verification ===", UVM_NONE)
            noconf.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 5: Full Address Sweep ===", UVM_NONE)
            sweep.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 6: Bank Boundary Addresses ===", UVM_NONE)
            bndry.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 7: Exhaustive Bank Pattern ===", UVM_NONE)
            pat.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 8: Random (100w / 200r) ===", UVM_NONE)
            rnd.num_writes = 100; rnd.num_reads = 200;
            rnd.start(get_sequencer());

            phase.drop_objection(this);
            `uvm_info("FM_FULL", "=== FULL TEST COMPLETE ===", UVM_NONE)
        endtask

    endclass 