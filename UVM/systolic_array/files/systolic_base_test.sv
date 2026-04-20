 // ============================================================
  // systolic_base_test.sv
  // Base class all tests inherit from. Creates env, gets vif.
  // ============================================================
  class systolic_base_test #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_test;

    `uvm_component_param_utils(systolic_base_test#(DW, M, K, N))

    systolic_env #(DW, M, K, N) env;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = systolic_env#(DW, M, K, N)::type_id::create("env", this);
    endfunction

    // Convenience: extract seq handle for the agent's sequencer
    function uvm_sequencer#(systolic_seq_item#(DW, M, K, N)) get_sequencer();
      return env.agent.sequencer;
    endfunction

  endclass