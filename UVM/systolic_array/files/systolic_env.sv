 // ============================================================
  // systolic_env.sv
  // Top-level UVM environment. Creates agent, scoreboard,
  // coverage. Wires analysis port fan-out in connect_phase.
  // ============================================================

  class systolic_env #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_env;

    `uvm_component_param_utils(systolic_env#(DW, M, K, N))

    systolic_agent #(DW, M, K, N)      agent;
    systolic_scoreboard #(DW, M, K, N) scoreboard;
    systolic_coverage #(DW, M, K, N)   coverage;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // ── build_phase: create all children ──────────────────────
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent      = systolic_agent#(DW, M, K, N)::type_id::create("agent", this);
      scoreboard = systolic_scoreboard#(DW, M, K, N)::type_id::create("scoreboard", this);
      coverage   = systolic_coverage#(DW, M, K, N)::type_id::create("coverage", this);
    endfunction

    // ── connect_phase: wire TLM ports ─────────────────────────
    // The monitor's analysis port fans out to BOTH scoreboard
    // and coverage. This is standard UVM fan-out wiring.
    function void connect_phase(uvm_phase phase);
      // agent.ap is the monitor's analysis port (passed through agent)
      agent.ap.connect(scoreboard.analysis_export);
      agent.ap.connect(coverage.analysis_export);
      // That's it! UVM handles the fan-out automatically.
    endfunction

  endclass


  // Baseline random sequence — exercises a wide distribution
  // of k_size values and INT8 data values.
  // The item's own constraints handle the distribution (10/80/10).

  class systolic_rand_seq #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_sequence #(systolic_seq_item #(DW, M, K, N));

    `uvm_object_param_utils(systolic_rand_seq#(DW, M, K, N))

    int num_transactions = 100;  // set from test

    task body();
      systolic_seq_item #(DW, M, K, N) item;
      repeat (num_transactions) begin
        item = systolic_seq_item#(DW, M, K, N)::type_id::create("item");
        start_item(item);
        if (!item.randomize()) `uvm_fatal("RAND", "Randomization failed!");
        finish_item(item);  // blocks until driver calls item_done()
      end
    endtask

  endclass