// ============================================================
  // systolic_coverage.sv
  // Functional coverage collector. Samples covergroups every
  // time monitor broadcasts a completed transaction.
  // ============================================================

  class systolic_coverage #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_subscriber #(systolic_seq_item #(DW, M, K, N));

    `uvm_component_param_utils(systolic_coverage#(DW, M, K, N))

    // Local copy of current transaction for covergroup sampling
    systolic_seq_item #(DW, M, K, N) curr_item;

    // ── Covergroup 1: k_size distribution ─────────────────────
    // Are we hitting the minimum, maximum, and mid-range values?
    covergroup cg_ksize;
      cp_ksize: coverpoint curr_item.k_size {
        bins min_k = {1};
        bins small_k = {[2 : 16]};
        bins mid_k = {[17 : (K / 2)]};
        bins large_k = {[(K / 2 + 1) : K - 1]};
        bins max_k = {K};
      }
    endgroup

    // ── Covergroup 2: Matrix A value distribution ──────────────
    // Do we hit zeros, max positive, max negative, mixed signs?
    // We sample A[0][0] as a representative element.
    covergroup cg_a_values;
      cp_a00: coverpoint curr_item.a_matrix[0][0] {
        bins max_pos = {127};
        bins pos = {[1 : 126]};
        bins zero = {0};
        bins neg = {[-127 : -1]};
        bins min_neg = {-128};
      }
    endgroup

    // ── Covergroup 3: Sign combination cross ──────────────────
    // Did A and B have all 4 sign combinations? (++, +-, -+, --)
    // Cross coverage ensures we test signed multiply thoroughly.
    covergroup cg_sign_cross;
      cp_a_sign: coverpoint (curr_item.a_matrix[0][0] >= 0) {
        bins positive = {1}; bins negative = {0};
      }
      cp_b_sign: coverpoint (curr_item.b_matrix[0][0] >= 0) {
        bins positive = {1}; bins negative = {0};
      }
      // Cross: all 4 combinations of A-sign × B-sign must be hit
      cx_ab_sign: cross cp_a_sign, cp_b_sign;
    endgroup

    // ── Covergroup 4: k_size × value corner cross ─────────────
    // Were extreme values exercised at extreme k_sizes?
    // Max accumulation (k_size=K, values=±128) is the worst case.
    covergroup cg_stress_cross;
      cp_k: coverpoint curr_item.k_size {bins k_min = {1}; bins k_max = {K}; bins k_mid = default;}
      cp_aval: coverpoint (curr_item.a_matrix[0][0] == 127 || curr_item.a_matrix[0][0] == -128) {
        bins extreme = {1}; bins normal = {0};
      }
      cx_stress: cross cp_k, cp_aval;
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      // Instantiate covergroups in new() — they exist for entire sim
      cg_ksize        = new();
      cg_a_values     = new();
      cg_sign_cross   = new();
      cg_stress_cross = new();
    endfunction

    // ── write(): called by monitor's ap.write() ────────────────
    // uvm_subscriber automatically creates analysis_export and
    // calls write() — no wiring needed in env.
    function void write(systolic_seq_item#(DW, M, K, N) t);
      curr_item = t;
      // Sample ALL covergroups with this transaction's data
      cg_ksize.sample();
      cg_a_values.sample();
      cg_sign_cross.sample();
      cg_stress_cross.sample();
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("COV", $sformatf(
                "Coverage: k_size=%.1f%% | values=%.1f%% | signs=%.1f%% | stress=%.1f%%",
                cg_ksize.get_coverage(),
                cg_a_values.get_coverage(),
                cg_sign_cross.get_coverage(),
                cg_stress_cross.get_coverage()
                ), UVM_NONE)
    endfunction

  endclass