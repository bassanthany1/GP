  // ============================================================
  // systolic_seq_item.sv
  // One transaction = one matrix multiply.
  // Fields: stimulus (rand) + response (captured by monitor).
  // ============================================================

  class systolic_seq_item #(
      parameter int DW = 8,
      parameter int M  = 4,
      parameter int K  = 256,
      parameter int N  = 4
  ) extends uvm_sequence_item;

    // Register with factory so it can be overridden in tests
    `uvm_object_param_utils(systolic_seq_item#(DW, M, K, N))

    // ── STIMULUS FIELDS (randomized by sequences) ─────────────

    // Matrix A: M rows × K cols, INT8 signed
    rand logic signed [DW-1:0] a_matrix[M-1:0][K-1:0];

    // Matrix B: K rows × N cols, INT8 signed
    rand logic signed [DW-1:0] b_matrix[K-1:0][N-1:0];

    // k_size: the actual inner dimension used this transaction.
    // This is what the old testbench forgot to drive!
    rand logic [$clog2(K+1)-1:0] k_size;

    // ── RESPONSE FIELDS (written by monitor, read by scoreboard) ──
    logic signed [4*DW-1:0] c_flat[M-1:0][N-1:0];  // DUT output

    // ── CONSTRAINTS ───────────────────────────────────────────

    // k_size must be in [1, K]. Never 0 (assertion in interface catches it too).
    constraint c_ksize_valid {k_size inside {[1 : K]};}

    // Weighted distribution: hit extremes more often.
    // 10% chance k_size=1, 10% k_size=K, 80% random middle.
    // This ensures corner cases get covered without directed tests.
    constraint c_ksize_dist {
      k_size dist {
        1           := 10,
        [2 : K - 1] := 80,
        K           := 10
      };
    }

    // Default: values across full INT8 range [-128, +127].
    // Sequences can override this with tighter constraints.
    constraint c_values_default {
      foreach (a_matrix[i, j]) a_matrix[i][j] inside {[-128 : 127]};
      foreach (b_matrix[i, j]) b_matrix[i][j] inside {[-128 : 127]};
    }

    // ── UTILITY METHODS ───────────────────────────────────────

    // Flatten a_matrix → a_flat for driving onto the interface.
    // Layout: a_flat[(r*K+k)*DW +: DW] = a_matrix[r][k]
    function logic signed [M*K*DW-1:0] get_a_flat();
      for (int r = 0; r < M; r++)
      for (int k = 0; k < K; k++) get_a_flat[(r*K+k)*DW+:DW] = a_matrix[r][k];
    endfunction

    // Flatten b_matrix → b_flat.
    // Layout: b_flat[(k*N+n)*DW +: DW] = b_matrix[k][n]
    function logic signed [K*N*DW-1:0] get_b_flat();
      for (int k = 0; k < K; k++)
      for (int n = 0; n < N; n++) get_b_flat[(k*N+n)*DW+:DW] = b_matrix[k][n];
    endfunction

    // Pretty-print for `uvm_info messages
    function string convert2string();
      return $sformatf(
          "k_size=%0d | A[0][0]=%0d B[0][0]=%0d | C[0][0]=%0d",
          k_size,
          a_matrix[0][0],
          b_matrix[0][0],
          c_flat[0][0]
      );
    endfunction

    // do_copy: required for sequence item cloning
    function void do_copy(uvm_object rhs);
      systolic_seq_item #(DW, M, K, N) rhs_;
      super.do_copy(rhs);
      $cast(rhs_, rhs);
      a_matrix = rhs_.a_matrix;
      b_matrix = rhs_.b_matrix;
      k_size   = rhs_.k_size;
      c_flat   = rhs_.c_flat;
    endfunction

  endclass