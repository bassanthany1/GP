    // =========================================================================
    // 11. BASE TEST
    // =========================================================================
    class bs_sram_base_test extends uvm_test;
        `uvm_component_utils(bs_sram_base_test)

        bs_sram_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = bs_sram_env::type_id::create("env", this);
        endfunction

        function uvm_sequencer #(bs_sram_seq_item) get_sequencer();
            return env.agent.sequencer;
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction

    endclass 


    // =========================================================================
    // 12. TESTS
    // =========================================================================

    class bs_sram_smoke_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_smoke_seq seq = bs_sram_smoke_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_offset_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_offset_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_offset_seq seq = bs_sram_offset_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_burst_len_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_burst_len_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_burst_len_seq seq = bs_sram_burst_len_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_wr_rd_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_wr_rd_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_wr_rd_seq seq = bs_sram_wr_rd_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_b2b_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_b2b_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_b2b_read_seq seq = bs_sram_b2b_read_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_signed_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_signed_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_signed_seq seq = bs_sram_signed_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_rand_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_rand_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_rand_seq seq = bs_sram_rand_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.num_pairs = 20;
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_lenet_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_lenet_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_lenet_seq seq = bs_sram_lenet_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_regression_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_regression_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_regression_seq seq = bs_sram_regression_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    // --------------------------------------------------------------------------
    // Full test: all directed phases + random
    // --------------------------------------------------------------------------
    class bs_sram_full_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_full_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        task run_phase(uvm_phase phase);
            bs_sram_smoke_seq     smoke = bs_sram_smoke_seq    ::type_id::create("smoke");
            bs_sram_offset_seq    off   = bs_sram_offset_seq   ::type_id::create("off");
            bs_sram_burst_len_seq blen  = bs_sram_burst_len_seq::type_id::create("blen");
            bs_sram_wr_rd_seq     wrrd  = bs_sram_wr_rd_seq    ::type_id::create("wrrd");
            bs_sram_b2b_read_seq  b2b   = bs_sram_b2b_read_seq ::type_id::create("b2b");
            bs_sram_signed_seq    sgn   = bs_sram_signed_seq   ::type_id::create("sgn");
            bs_sram_lenet_seq     lenet = bs_sram_lenet_seq    ::type_id::create("lenet");
            bs_sram_rand_seq      rnd   = bs_sram_rand_seq     ::type_id::create("rnd");

            phase.raise_objection(this);

            `uvm_info("BS_FULL", "=== PHASE 1: Smoke ===", UVM_NONE)
            smoke.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 2: Layer Offset (LeNet-5 layers) ===", UVM_NONE)
            off.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 3: Burst Length Stress ===", UVM_NONE)
            blen.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 4: Write-Read Interleaved ===", UVM_NONE)
            wrrd.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 5: Back-to-Back Reads ===", UVM_NONE)
            b2b.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 6: Signed Corner Cases ===", UVM_NONE)
            sgn.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 7: LeNet-5 Integration ===", UVM_NONE)
            lenet.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 8: Random (100 pairs) ===", UVM_NONE)
            rnd.num_pairs = 100;
            rnd.start(get_sequencer());

            // Drain pipeline
            repeat (PKG_PIPE_LATENCY + 8) @(posedge env.agent.monitor.vif.cb_mon);

            phase.drop_objection(this);

            `uvm_info("BS_FULL", "=== FULL TEST COMPLETE ===", UVM_NONE)
        endtask

    endclass 