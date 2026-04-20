// Directed corner-case sequence.
  // Uses inline constraints to force specific scenarios.
  // Run this BEFORE the random sequence to ensure corners are hit.

  class systolic_corner_seq #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_sequence #(systolic_seq_item #(DW, M, K, N));

    `uvm_object_param_utils(systolic_corner_seq#(DW, M, K, N))

    task body();
      systolic_seq_item #(DW, M, K, N) item;

      // ── Corner 1: k_size = 1 (minimum) ────────────────────
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c1");
      start_item(item);
      if (!item.randomize() with {k_size == 1;}) `uvm_fatal("RAND", "Corner 1 failed");
      finish_item(item);

      // ── Corner 2: k_size = K (maximum, max accumulation) ──
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c2");
      start_item(item);
      if (!item.randomize() with {k_size == K;}) `uvm_fatal("RAND", "Corner 2 failed");
      finish_item(item);

      // ── Corner 3: All-zero A matrix ────────────────────────
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c3");
      start_item(item);
      if (!item.randomize() with {foreach (a_matrix[i, j]) a_matrix[i][j] == 0;})
        `uvm_fatal("RAND", "Corner 3 failed");
      finish_item(item);

      // ── Corner 4: Max positive × Max positive (overflow test) ─
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c4");
      start_item(item);
      if (!item.randomize() with {
            k_size == K;
            foreach (a_matrix[i, j]) a_matrix[i][j] == 127;
            foreach (b_matrix[i, j]) b_matrix[i][j] == 127;
          })
        `uvm_fatal("RAND", "Corner 4 failed");
      finish_item(item);

      // ── Corner 5: Min negative × Min negative ─────────────
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c5");
      start_item(item);
      if (!item.randomize() with {
            k_size == K;
            foreach (a_matrix[i, j]) a_matrix[i][j] == -128;
            foreach (b_matrix[i, j]) b_matrix[i][j] == -128;
          })
        `uvm_fatal("RAND", "Corner 5 failed");
      finish_item(item);

      // ── Corner 6: Identity-like: A=I, B=random → C=B ──────
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c6");
      start_item(item);
      if (!item.randomize() with {
            k_size == 1;
            foreach (a_matrix[i, j]) a_matrix[i][j] == (int'(i) == int'(j) ? 1 : 0);
          })
        `uvm_fatal("RAND", "Corner 6 failed");
      finish_item(item);

      // ── Corner 7: k_size=1 with extreme values → closes stress cross ──
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c7");
      start_item(item);
      if (!item.randomize() with {
            k_size == 1;
            foreach (a_matrix[i, j]) a_matrix[i][j] == 127;
            foreach (b_matrix[i, j]) b_matrix[i][j] == 127;
          })
        `uvm_fatal("RAND", "Corner 7 failed");
      finish_item(item);
    endtask

  endclass