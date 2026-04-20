 // ============================================================
  // systolic_full_test
  // Runs ALL scenarios: corners → random → stress, in sequence.
  // One simulation, complete verification.
  // ============================================================
  class systolic_full_test extends systolic_base_test #(8, 4, 256, 4);

    `uvm_component_utils(systolic_full_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      systolic_corner_seq #(8, 4, 256, 4) corner_seq;
      systolic_rand_seq #(8, 4, 256, 4)   rand_seq;
      systolic_stress_seq #(8, 4, 256, 4) stress_seq;

      phase.raise_objection(this);

      // ── Phase 1: Directed corners ──────────────────────────
      `uvm_info("TEST", "=== PHASE 1: Corner Cases ===", UVM_NONE)
      corner_seq = systolic_corner_seq#(8, 4, 256, 4)::type_id::create("corners");
      corner_seq.start(get_sequencer());

      // ── Phase 2: Constrained random ────────────────────────
      `uvm_info("TEST", "=== PHASE 2: Random (200 txns) ===", UVM_NONE)
      rand_seq = systolic_rand_seq#(8, 4, 256, 4)::type_id::create("rand");
      rand_seq.num_transactions = 200;
      rand_seq.start(get_sequencer());

      // ── Phase 3: Back-to-back stress ───────────────────────
      `uvm_info("TEST", "=== PHASE 3: Stress (50 txns) ===", UVM_NONE)
      stress_seq = systolic_stress_seq#(8, 4, 256, 4)::type_id::create("stress");
      stress_seq.num_transactions = 50;
      stress_seq.start(get_sequencer());

      phase.drop_objection(this);
    endtask

  endclass