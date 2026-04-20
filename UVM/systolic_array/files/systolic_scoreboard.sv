// ============================================================
  // systolic_scoreboard.sv
  // Receives transactions from monitor's analysis port.
  // Computes golden C=A×B, compares element-by-element.
  // ============================================================

  class systolic_scoreboard #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_scoreboard;

    `uvm_component_param_utils(systolic_scoreboard#(DW, M, K, N))

    // Analysis export: the "input port" that connects to monitor's ap.
    // uvm_analysis_imp automatically calls our write() method.
    uvm_analysis_imp #(
        systolic_seq_item #(DW,M,K,N),
        systolic_scoreboard #(DW,M,K,N)
    ) analysis_export;

    // Statistics counters
    int unsigned total_transactions = 0;
    int unsigned total_errors = 0;
    int unsigned total_elements = 0;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      analysis_export = new("analysis_export", this);
    endfunction

    // ── write(): called by monitor's ap.write() ────────────────
    // This is called ONCE per transaction. No need to synchronize
    // with the clock — we're in the transaction domain now.
    function void write(systolic_seq_item#(DW, M, K, N) item);
      logic signed [4*DW-1:0] expected[M-1:0][N-1:0];
      int errors_this_txn = 0;

      // ── Compute golden reference: C = A × B ─────────────────
      // CRITICAL: Only sum up to k_size columns/rows.
      // k_size may be < K — the rest of the matrix is don't-care.
      // This is what the old testbench ALWAYS got wrong (k_size=0).
      for (int r = 0; r < M; r++) begin
        for (int n = 0; n < N; n++) begin
          automatic logic signed [4*DW-1:0] acc = '0;
          for (int k = 0; k < item.k_size; k++) begin
            // INT8 × INT8 → sign-extended to 4×DW before accumulate
            acc += ((4 * DW)'(item.a_matrix[r][k]) * (4 * DW)'(item.b_matrix[k][n]));
          end
          expected[r][n] = acc;
        end
      end

      // ── Compare DUT output with golden ─────────────────────
      for (int r = 0; r < M; r++) begin
        for (int n = 0; n < N; n++) begin
          total_elements++;
          if (item.c_flat[r][n] !== expected[r][n]) begin
            // !== checks for X/Z too, not just value mismatch
            `uvm_error("SB_MISMATCH", $sformatf(
                       "C[%0d][%0d]: GOT=%0d EXPECTED=%0d (k_size=%0d)",
                       r,
                       n,
                       $signed(
                           item.c_flat[r][n]
                       ),
                       $signed(
                           expected[r][n]
                       ),
                       item.k_size
                       ));
            errors_this_txn++;
            total_errors++;
          end
        end
      end

      total_transactions++;

      if (errors_this_txn == 0)
        `uvm_info("SB_PASS", $sformatf(
                  "TXN %0d PASSED (k_size=%0d)", total_transactions, item.k_size), UVM_MEDIUM)
    endfunction

    // ── report_phase: final summary ────────────────────────────
    function void report_phase(uvm_phase phase);
      if (total_errors == 0)
        `uvm_info(
            "SB_FINAL", $sformatf(
            "ALL %0d TRANSACTIONS PASSED (%0d elements checked)", total_transactions, total_elements
            ), UVM_NONE)
      else
        `uvm_error("SB_FINAL", $sformatf(
                   "%0d ERRORS in %0d transactions", total_errors, total_transactions));
    endfunction

  endclass