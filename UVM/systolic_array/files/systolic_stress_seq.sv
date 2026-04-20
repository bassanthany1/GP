// Stress sequence: sends transactions back-to-back with
  // no idle cycles. Tests DUT's ability to restart immediately
  // after valid_out fires. This is the hardest protocol timing.

  class systolic_stress_seq #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_sequence #(systolic_seq_item #(DW, M, K, N));

    `uvm_object_param_utils(systolic_stress_seq#(DW, M, K, N))

    int num_transactions = 50;

    task body();
      systolic_seq_item #(DW, M, K, N) item;
      // Alternate between k_size=1 (fastest) and k_size=K (slowest)
      // to stress the state machine transitions
      repeat (num_transactions) begin
        automatic int use_k = ($urandom_range(0, 1) ? 1 : K);
        item = systolic_seq_item#(DW, M, K, N)::type_id::create("item");
        start_item(item);
        if (!item.randomize() with {k_size == use_k;}) `uvm_fatal("RAND", "Stress rand failed");
        finish_item(item);
        // finish_item blocks until driver calls item_done()
        // Driver calls item_done() right after valid_out.
        // So next start_item fires immediately → true back-to-back.
      end
    endtask

  endclass