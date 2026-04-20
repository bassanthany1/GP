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