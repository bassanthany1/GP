 // ============================================================
  // systolic_rand_test.sv
  // Runs corner cases first, then 200 random transactions.
  // ============================================================
  class systolic_rand_test extends systolic_base_test #(8, 4, 256, 4);

    `uvm_component_utils(systolic_rand_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      systolic_corner_seq #(8, 4, 256, 4) corner_seq;
      systolic_rand_seq #(8, 4, 256, 4)   rand_seq;

      phase.raise_objection(this);  // Tell UVM "sim is not done yet"

      // Phase 1: Directed corners (deterministic, always runs)
      corner_seq = systolic_corner_seq#(8, 4, 256, 4)::type_id::create("corners");
      corner_seq.start(get_sequencer());

      // Phase 2: Constrained random (seeds controlled by +ntb_random_seed)
      rand_seq = systolic_rand_seq#(8, 4, 256, 4)::type_id::create("rand");
      rand_seq.num_transactions = 200;
      rand_seq.start(get_sequencer());

      phase.drop_objection(this);  // Tell UVM "sim can end now"
    endtask

  endclass