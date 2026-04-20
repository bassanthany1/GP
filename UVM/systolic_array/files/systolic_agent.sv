  // ============================================================
  // systolic_agent.sv
  // Bundles: sequencer + driver + monitor.
  // is_active = UVM_ACTIVE  → creates driver + sequencer (block-level)
  // is_active = UVM_PASSIVE → monitor only (chip-level reuse)
  // ============================================================

  class systolic_agent #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_agent;

    `uvm_component_param_utils(systolic_agent#(DW, M, K, N))

    // Child components (declared, created conditionally)
    uvm_sequencer #(systolic_seq_item #(DW, M, K, N))     sequencer;
    systolic_driver #(DW, M, K, N)                        driver;
    systolic_monitor #(DW, M, K, N)                       monitor;

    // Expose monitor's analysis port so env can connect scoreboard/coverage
    uvm_analysis_port #(systolic_seq_item #(DW, M, K, N)) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      // Monitor always exists — active OR passive
      monitor = systolic_monitor#(DW, M, K, N)::type_id::create("monitor", this);

      // Driver + sequencer only in ACTIVE mode
      if (get_is_active() == UVM_ACTIVE) begin
        sequencer =
            uvm_sequencer#(systolic_seq_item#(DW, M, K, N))::type_id::create("sequencer", this);
        driver = systolic_driver#(DW, M, K, N)::type_id::create("driver", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      // Expose monitor's ap through agent's ap (simple passthrough)
      ap = monitor.ap;

      // Connect driver's seq_item_port to sequencer's export (TLM)
      if (get_is_active() == UVM_ACTIVE) driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

  endclass