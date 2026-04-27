    // =========================================================================
    // 9. BASE SEQUENCE
    // =========================================================================
    class br_base_seq extends uvm_sequence #(br_seq_item);
        `uvm_object_utils(br_base_seq)
        function new(string name = "br_base_seq"); super.new(name); endfunction

        // Send a fully specified transaction
        task send_directed(
            input logic                         enable_relu,
            input logic [7:0]                   out_channels,
            input logic [CH_W-1:0]              ch_start,
            input logic [PKG_WIN_IDX_W-1:0]    win_idx,
            input logic signed [PKG_DATA_WIDTH-1:0]
                                                conv_data [PKG_TILE_ROWS][PKG_ARRAY_COLS],
            input logic signed [PKG_BIAS_WIDTH-1:0]
                                                bias_values [PKG_ARRAY_COLS]
        );
            br_seq_item item = br_seq_item::type_id::create("item");
            start_item(item);
            item.enable_relu           = enable_relu;
            item.out_channels          = out_channels;
            item.conv_channel_start    = ch_start;
            item.conv_window_idx_start = win_idx;
            foreach (conv_data[r,c])   item.conv_data[r][c]   = conv_data[r][c];
            foreach (bias_values[c])   item.bias_values[c]    = bias_values[c];
            finish_item(item);
        endtask

        // Send a random transaction
        task send_rand();
            br_seq_item item = br_seq_item::type_id::create("item");
            start_item(item);
            if (!item.randomize())
                `uvm_fatal("BR_SEQ", "Randomize failed")
            finish_item(item);
        endtask

        // Send random with relu forced on or off
        task send_rand_relu(input bit relu_en);
            br_seq_item item = br_seq_item::type_id::create("item");
            start_item(item);
            if (!item.randomize() with { enable_relu == relu_en; })
                `uvm_fatal("BR_SEQ", "Randomize with relu failed")
            finish_item(item);
        endtask

        // Send random with last tile (padding scenario guaranteed)
        task send_rand_padded();
            br_seq_item item = br_seq_item::type_id::create("item");
            start_item(item);
            // Force ch_start such that ch_start + ARRAY_COLS > out_channels
            if (!item.randomize() with {
                    out_channels > 0;
                    out_channels <= PKG_MAX_OUT_CHANNELS;
                    conv_channel_start < out_channels;
                    conv_channel_start % PKG_ARRAY_COLS == 0;
                    int'(conv_channel_start) + PKG_ARRAY_COLS > int'(out_channels);
                })
                `uvm_fatal("BR_SEQ", "Randomize padded failed")
            finish_item(item);
        endtask

    endclass 


    // =========================================================================
    // 10. SEQUENCES
    // =========================================================================

    // ---------- Smoke: 4 directed transactions ----------
    class br_smoke_seq extends br_base_seq;
        `uvm_object_utils(br_smoke_seq)
        function new(string name = "br_smoke_seq"); super.new(name); endfunction
        task body();
            logic signed [PKG_DATA_WIDTH-1:0]  cd [PKG_TILE_ROWS][PKG_ARRAY_COLS];
            logic signed [PKG_BIAS_WIDTH-1:0]  bv [PKG_ARRAY_COLS];

            // All zeros + zero bias → zero output, relu irrelevant
            foreach (cd[r,c]) cd[r][c] = '0;
            foreach (bv[c])   bv[c]    = '0;
            send_directed(0, 4, 0, 0, cd, bv);

            // Simple positive values, no relu
            foreach (cd[r,c]) cd[r][c] = 32'(r * 4 + c + 1);
            foreach (bv[c])   bv[c]    = 32'(10);
            send_directed(0, 4, 0, 1, cd, bv);

            // Positive values + relu (no clipping expected)
            send_directed(1, 4, 0, 2, cd, bv);

            // Negative biased values + relu → clipped to 0
            foreach (cd[r,c]) cd[r][c] = 32'(1);
            foreach (bv[c])   bv[c]    = -32'(5);
            send_directed(1, 4, 0, 3, cd, bv);
        endtask
    endclass 

    // ---------- ReLU boundary: values exactly at zero ----------
    class br_relu_seq extends br_base_seq;
        `uvm_object_utils(br_relu_seq)
        function new(string name = "br_relu_seq"); super.new(name); endfunction
        task body();
            logic signed [PKG_DATA_WIDTH-1:0]  cd [PKG_TILE_ROWS][PKG_ARRAY_COLS];
            logic signed [PKG_BIAS_WIDTH-1:0]  bv [PKG_ARRAY_COLS];

            // biased == 0 → should stay 0 even with relu
            foreach (cd[r,c]) cd[r][c] = 32'(5);
            foreach (bv[c])   bv[c]    = -32'(5);
            send_directed(1, 4, 0, 0, cd, bv);

            // biased == -1 with relu → clips to 0
            foreach (bv[c]) bv[c] = -32'(6);
            send_directed(1, 4, 0, 1, cd, bv);

            // biased == -1 WITHOUT relu → should stay -1
            send_directed(0, 4, 0, 2, cd, bv);

            // Large negative bias + relu
            foreach (cd[r,c]) cd[r][c] = 32'(0);
            foreach (bv[c])   bv[c]    = -32'(1000);
            send_directed(1, 4, 0, 3, cd, bv);

            // Large positive bias
            foreach (cd[r,c]) cd[r][c] = 32'(0);
            foreach (bv[c])   bv[c]    = 32'(1000);
            send_directed(1, 4, 0, 4, cd, bv);

            // Random relu stress
            repeat (8) send_rand_relu(1);
            repeat (8) send_rand_relu(0);
        endtask
    endclass 

    // ---------- Padding: last tile with some inactive cols ----------
    class br_padding_seq extends br_base_seq;
        `uvm_object_utils(br_padding_seq)
        function new(string name = "br_padding_seq"); super.new(name); endfunction
        task body();
            logic signed [PKG_DATA_WIDTH-1:0]  cd [PKG_TILE_ROWS][PKG_ARRAY_COLS];
            logic signed [PKG_BIAS_WIDTH-1:0]  bv [PKG_ARRAY_COLS];

            // out_channels=5, ch_start=4 → only col0 active, cols 1-3 pass-through
            foreach (cd[r,c]) cd[r][c] = 32'(r * 10 + c + 1);
            foreach (bv[c])   bv[c]    = 32'(7);
            send_directed(1, 5, 4, 0, cd, bv);

            // out_channels=6, ch_start=4 → cols 0-1 active, cols 2-3 pass-through
            send_directed(1, 6, 4, 1, cd, bv);

            // out_channels=7, ch_start=4 → cols 0-2 active, col 3 pass-through
            send_directed(1, 7, 4, 2, cd, bv);

            // out_channels=8, ch_start=4 → all 4 cols active, no padding
            send_directed(1, 8, 4, 3, cd, bv);

            // Random padded transactions
            repeat (10) send_rand_padded();
        endtask
    endclass 

    // ---------- Window index passthrough ----------
    class br_window_seq extends br_base_seq;
        `uvm_object_utils(br_window_seq)
        function new(string name = "br_window_seq"); super.new(name); endfunction
        task body();
            logic signed [PKG_DATA_WIDTH-1:0]  cd [PKG_TILE_ROWS][PKG_ARRAY_COLS];
            logic signed [PKG_BIAS_WIDTH-1:0]  bv [PKG_ARRAY_COLS];
            foreach (cd[r,c]) cd[r][c] = 32'(1);
            foreach (bv[c])   bv[c]    = 32'(1);
            // Sweep window_idx spot values — explicit calls (no foreach-on-literal)
            send_directed(0, 4, 0, 10'd0,    cd, bv);
            send_directed(0, 4, 0, 10'd1,    cd, bv);
            send_directed(0, 4, 0, 10'd127,  cd, bv);
            send_directed(0, 4, 0, 10'd128,  cd, bv);
            send_directed(0, 4, 0, 10'd255,  cd, bv);
            send_directed(0, 4, 0, 10'd512,  cd, bv);
            send_directed(0, 4, 0, 10'd1023, cd, bv);
        endtask
    endclass 

    // ---------- Back-to-back transactions ----------
    class br_back2back_seq extends br_base_seq;
        `uvm_object_utils(br_back2back_seq)
        function new(string name = "br_back2back_seq"); super.new(name); endfunction
        task body();
            repeat (16) send_rand();
        endtask
    endclass 

    // ---------- Constrained random ----------
    class br_rand_seq extends br_base_seq;
        `uvm_object_utils(br_rand_seq)
        int unsigned num_items = 30;
        function new(string name = "br_rand_seq"); super.new(name); endfunction
        task body();
            repeat (num_items) send_rand();
        endtask
    endclass 

    // ---------- Full regression ----------
    class br_regression_seq extends br_base_seq;
        `uvm_object_utils(br_regression_seq)
        function new(string name = "br_regression_seq"); super.new(name); endfunction
        task body();
            br_smoke_seq     smoke = br_smoke_seq    ::type_id::create("smoke");
            br_relu_seq      relu  = br_relu_seq     ::type_id::create("relu");
            br_padding_seq   pad   = br_padding_seq  ::type_id::create("pad");
            br_window_seq    win   = br_window_seq   ::type_id::create("win");
            br_back2back_seq b2b   = br_back2back_seq::type_id::create("b2b");
            br_rand_seq      rnd   = br_rand_seq     ::type_id::create("rnd");
            rnd.num_items = 50;
            `uvm_info("BR_REG", "=== Regression start ===", UVM_NONE)
            smoke.start(m_sequencer);
            relu.start(m_sequencer);
            pad.start(m_sequencer);
            win.start(m_sequencer);
            b2b.start(m_sequencer);
            rnd.start(m_sequencer);
            `uvm_info("BR_REG", "=== Regression complete ===", UVM_NONE)
        endtask
    endclass