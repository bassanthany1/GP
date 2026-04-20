// ============================================================
  // systolic_monitor.sv
  // Passive observer. Captures A, B, k_size on load_data.
  // Captures c_flat on valid_out. Broadcasts to analysis port.
  // ============================================================

  class systolic_monitor #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_monitor;

    `uvm_component_param_utils(systolic_monitor#(DW, M, K, N))

    // Virtual interface handle (monitor modport — read-only)
    virtual systolic_if #(DW, M, K, N).mon_mp vif;

    // Analysis port: broadcasts completed transactions to
    // scoreboard AND coverage collector simultaneously (fan-out).
    uvm_analysis_port #(systolic_seq_item #(DW, M, K, N)) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      // Create the analysis port in build_phase (not new())
      ap = new("ap", this);
      if (!uvm_config_db#(virtual systolic_if #(DW, M, K, N))::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "systolic_monitor: vif not found");
    endfunction

    // ── run_phase: main monitor loop ───────────────────────────
    task run_phase(uvm_phase phase);
  systolic_seq_item #(DW, M, K, N) item;

  forever begin
    @(vif.cb_mon);
    
    // ── Ignore any activity while reset is asserted ──────────
    if (vif.cb_mon.rst)  continue;
    if (!vif.cb_mon.load_data) continue;

    // Only proceed if data is not X/Z
    if ($isunknown(vif.cb_mon.k_size)) begin
      `uvm_warning("MON", "load_data seen but k_size is X — skipping (reset artifact)")
      continue;
    end

    item = systolic_seq_item#(DW, M, K, N)::type_id::create("item");
    item.k_size = vif.cb_mon.k_size;

        // Unpack flat buses back into 2D arrays for easy scoreboard use
        for (int r = 0; r < M; r++)
        for (int k = 0; k < K; k++) item.a_matrix[r][k] = vif.cb_mon.a_flat[(r*K+k)*DW+:DW];
        for (int k = 0; k < K; k++)
        for (int n = 0; n < N; n++) item.b_matrix[k][n] = vif.cb_mon.b_flat[(k*N+n)*DW+:DW];

        // ── Now wait for valid_out ──────────────────────────
        // The DUT takes (k_size + M + N - 2) cycles.
        // We just wait — don't assume how many cycles.
        do begin
          @(vif.cb_mon);
        end while (!vif.cb_mon.valid_out);

        // ── Capture response ────────────────────────────────
        // valid_out is high: c_flat is valid this cycle.
        // Unpack flat output into 2D array.
        for (int r = 0; r < M; r++)
        for (int n = 0; n < N; n++) item.c_flat[r][n] = vif.cb_mon.c_flat[(r*N+n)*4*DW+:4*DW];

        // ── Broadcast to all subscribers via analysis port ──
        // ap.write() calls every connected component's write() method.
        // Scoreboard gets it. Coverage gets it. Zero coupling.
        ap.write(item);

        `uvm_info("MON", $sformatf("Captured: %s", item.convert2string()), UVM_MEDIUM)
      end

    endtask

  endclass