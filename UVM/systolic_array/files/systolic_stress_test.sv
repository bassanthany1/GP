 // ============================================================
  // systolic_stress_test.sv
  // Pure back-to-back stress, no idle time between transactions.
  // ============================================================
  class systolic_stress_test extends systolic_base_test #(8, 4, 256, 4);

    `uvm_component_utils(systolic_stress_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      systolic_stress_seq #(8, 4, 256, 4) seq;
      phase.raise_objection(this);
      seq = systolic_stress_seq#(8, 4, 256, 4)::type_id::create("stress");
      seq.num_transactions = 50;
      seq.start(get_sequencer());
      phase.drop_objection(this);
    endtask

  endclass