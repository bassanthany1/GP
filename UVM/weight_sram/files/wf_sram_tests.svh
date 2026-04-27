   // =========================================================================
    // 11. BASE TEST
    // =========================================================================
    class wf_sram_base_test extends uvm_test;
        `uvm_component_utils(wf_sram_base_test)

        wf_sram_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = wf_sram_env::type_id::create("env", this);
        endfunction

        function uvm_sequencer #(wf_sram_seq_item) get_sequencer();
            return env.agent.sequencer;
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction

    endclass 


    // =========================================================================
    // 12. TESTS
    // =========================================================================
    class wf_sram_smoke_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_smoke_seq seq = wf_sram_smoke_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_offset_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_offset_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_offset_seq seq = wf_sram_offset_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_burst_len_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_burst_len_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_burst_len_seq seq = wf_sram_burst_len_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_wr_rd_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_wr_rd_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_wr_rd_seq seq = wf_sram_wr_rd_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_b2b_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_b2b_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_b2b_read_seq seq = wf_sram_b2b_read_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_rand_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_rand_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_rand_seq seq = wf_sram_rand_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.num_pairs = 20;
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_lenet_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_lenet_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_lenet_seq seq = wf_sram_lenet_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_regression_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_regression_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_regression_seq seq = wf_sram_regression_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_full_test extends wf_sram_base_test;
    `uvm_component_utils(wf_sram_full_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
        // --- Phase 1: Directed corners ---
        wf_sram_smoke_seq     smoke = wf_sram_smoke_seq    ::type_id::create("smoke");
        wf_sram_offset_seq    off   = wf_sram_offset_seq   ::type_id::create("off");
        wf_sram_burst_len_seq blen  = wf_sram_burst_len_seq::type_id::create("blen");
        wf_sram_wr_rd_seq     wrrd  = wf_sram_wr_rd_seq    ::type_id::create("wrrd");
        wf_sram_b2b_read_seq  b2b   = wf_sram_b2b_read_seq ::type_id::create("b2b");
        wf_sram_lenet_seq     lenet = wf_sram_lenet_seq    ::type_id::create("lenet");
        // --- Phase 2: Constrained random ---
        wf_sram_rand_seq      rnd   = wf_sram_rand_seq     ::type_id::create("rnd");

        phase.raise_objection(this);

        `uvm_info("WF_FULL", "=== PHASE 1: Smoke ===", UVM_NONE)
        smoke.start(get_sequencer());

        `uvm_info("WF_FULL", "=== PHASE 2: Layer Offset ===", UVM_NONE)
        off.start(get_sequencer());

        `uvm_info("WF_FULL", "=== PHASE 3: Burst Length Stress ===", UVM_NONE)
        blen.start(get_sequencer());

        `uvm_info("WF_FULL", "=== PHASE 4: Write-Read Interleaved ===", UVM_NONE)
        wrrd.start(get_sequencer());

        `uvm_info("WF_FULL", "=== PHASE 5: Back-to-Back Reads ===", UVM_NONE)
        b2b.start(get_sequencer());

        `uvm_info("WF_FULL", "=== PHASE 6: LeNet-5 Integration ===", UVM_NONE)
        lenet.start(get_sequencer());

        `uvm_info("WF_FULL", "=== PHASE 7: Random (100 pairs) ===", UVM_NONE)
        rnd.num_pairs = 100;
        rnd.start(get_sequencer());

        // Drain pipeline before dropping objection
        repeat (PKG_PIPE_LATENCY + 8) @(posedge env.agent.monitor.vif.cb_mon);

        phase.drop_objection(this);

        `uvm_info("WF_FULL", "=== FULL TEST COMPLETE ===", UVM_NONE)
    endtask

endclass 