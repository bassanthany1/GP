    // =========================================================================
    // 9. BASE SEQUENCE
    // =========================================================================
    class bs_sram_base_seq extends uvm_sequence #(bs_sram_seq_item);
        `uvm_object_utils(bs_sram_base_seq)
        function new(string name = "bs_sram_base_seq"); super.new(name); endfunction

        task send_write(int unsigned addr,
                        logic signed [PKG_DATA_WIDTH-1:0] data,
                        int unsigned offset = 0);
            bs_sram_seq_item item = bs_sram_seq_item::type_id::create("item");
            start_item(item);
            item.is_write     = 1;
            item.write_addr   = addr;
            item.write_data   = data;
            item.layer_offset = offset;
            finish_item(item);
        endtask

        task send_read(int unsigned addr, int unsigned len, int unsigned offset = 0);
            bs_sram_seq_item item = bs_sram_seq_item::type_id::create("item");
            start_item(item);
            item.is_write     = 0;
            item.read_addr    = addr;
            item.burst_length = len;
            item.layer_offset = offset;
            finish_item(item);
        endtask

        task send_rand_write();
            bs_sram_seq_item item = bs_sram_seq_item::type_id::create("item");
            start_item(item);
            item.is_write = 1;
            if (!item.randomize() with { is_write == 1; })
                `uvm_fatal("BS_SEQ", "Write randomize failed")
            finish_item(item);
        endtask

        task send_rand_read();
            bs_sram_seq_item item = bs_sram_seq_item::type_id::create("item");
            start_item(item);
            item.is_write = 0;
            if (!item.randomize() with { is_write == 0; })
                `uvm_fatal("BS_SEQ", "Read randomize failed")
            finish_item(item);
        endtask

    endclass 


    // =========================================================================
    // 10. SEQUENCES
    // =========================================================================

    // --------------------------------------------------------------------------
    // Smoke: write 8 biases, read them back
    // --------------------------------------------------------------------------
    class bs_sram_smoke_seq extends bs_sram_base_seq;
        `uvm_object_utils(bs_sram_smoke_seq)
        function new(string name = "bs_sram_smoke_seq"); super.new(name); endfunction
        task body();
            for (int i = 0; i < 8; i++)
                send_write(i, 32'(i * 100 - 400), 0);
            send_read(0, 8, 0);
        endtask
    endclass 

    // --------------------------------------------------------------------------
    // Layer offset: verify layer_offset + read_addr address translation
    // Maps to LeNet-5 bias layout:
    //   C1  : 6  biases @ offset 0
    //   S2  : 6  biases @ offset 6
    //   C3  : 16 biases @ offset 12
    //   S4  : 16 biases @ offset 28
    //   C5  : 120 biases @ offset 44   (max burst = 16, so tiled reads)
    //   F6  : 84 biases @ offset 164
    // --------------------------------------------------------------------------
    class bs_sram_offset_seq extends bs_sram_base_seq;
        `uvm_object_utils(bs_sram_offset_seq)
        function new(string name = "bs_sram_offset_seq"); super.new(name); endfunction
        task body();
            // C1 layer at offset 0 (6 biases)
            for (int i = 0; i < 6; i++)
                send_write(i, 32'(i * 1024 - 3072), 0);
            send_read(0, 6, 0);

            // S2 layer: write to absolute addresses 6..11, read via offset=6
            for (int i = 0; i < 6; i++)
                send_write(6 + i, 32'(i * 512 + 256), 0);
            send_read(0, 6, 6);

            // C3 layer: write to absolute 12..27, read via offset=12
            for (int i = 0; i < 16; i++)
                send_write(12 + i, 32'(i * 256 - 2048), 0);
            send_read(0, 16, 12);

            // S4 layer: write to absolute 28..43, read via offset=28
            for (int i = 0; i < 16; i++)
                send_write(28 + i, 32'(i * 128 + 64), 0);
            send_read(0, 16, 28);
        endtask
    endclass 

    // --------------------------------------------------------------------------
    // Burst length stress: min=1, mid=8, max=16 (PKG_MAX_BURST_LEN)
    // --------------------------------------------------------------------------
    class bs_sram_burst_len_seq extends bs_sram_base_seq;
        `uvm_object_utils(bs_sram_burst_len_seq)
        function new(string name = "bs_sram_burst_len_seq"); super.new(name); endfunction
        task body();
            // Pre-fill first 16 locations
            for (int i = 0; i < PKG_MAX_BURST_LEN; i++)
                send_write(i, 32'(i ^ 32'hA5A5A5A5), 0);
            send_read(0, 1,                 0);
            send_read(0, 4,                 0);
            send_read(0, 8,                 0);
            send_read(0, 12,                0);
            send_read(0, PKG_MAX_BURST_LEN, 0);
        endtask
    endclass 

    // --------------------------------------------------------------------------
    // Write-then-read interleaved
    // --------------------------------------------------------------------------
    class bs_sram_wr_rd_seq extends bs_sram_base_seq;
        `uvm_object_utils(bs_sram_wr_rd_seq)
        function new(string name = "bs_sram_wr_rd_seq"); super.new(name); endfunction
        task body();
            // 4 groups of 4 addresses, each written then immediately burst-read
            for (int i = 0; i < 4; i++) begin
                for (int j = 0; j < 4; j++)
                    send_write(i * 4 + j, 32'((i * 4 + j) * 777 - 1024), 0);
                send_read(i * 4, 4, 0);
            end
        endtask
    endclass 

    // --------------------------------------------------------------------------
    // Back-to-back reads (non-overlapping windows)
    // --------------------------------------------------------------------------
    class bs_sram_b2b_read_seq extends bs_sram_base_seq;
        `uvm_object_utils(bs_sram_b2b_read_seq)
        function new(string name = "bs_sram_b2b_read_seq"); super.new(name); endfunction
        task body();
            // Fill the first 32 biases
            for (int i = 0; i < 32; i++)
                send_write(i, 32'(i * 333 - 5000), 0);
            // Four back-to-back 8-beat reads
            send_read(0,  8, 0);
            send_read(8,  8, 0);
            send_read(16, 8, 0);
            send_read(24, 8, 0);
        endtask
    endclass 

    // --------------------------------------------------------------------------
    // Signed data: negative, zero, max-positive, min-negative 32-bit values
    // --------------------------------------------------------------------------
    class bs_sram_signed_seq extends bs_sram_base_seq;
        `uvm_object_utils(bs_sram_signed_seq)
        function new(string name = "bs_sram_signed_seq"); super.new(name); endfunction
        task body();
            send_write(0, 32'h0000_0000, 0);           // zero
            send_write(1, 32'h7FFF_FFFF, 0);           // INT32_MAX
            send_write(2, 32'h8000_0000, 0);           // INT32_MIN
            send_write(3, 32'hFFFF_FFFF, 0);           // -1
            send_write(4, 32'h0000_0001, 0);           // +1
            send_write(5, 32'hDEAD_BEEF, 0);           // arbitrary negative
            send_read(0, 6, 0);
        endtask
    endclass 

    // --------------------------------------------------------------------------
    // Random pairs (constrained)
    // --------------------------------------------------------------------------
    class bs_sram_rand_seq extends bs_sram_base_seq;
        `uvm_object_utils(bs_sram_rand_seq)
        int unsigned num_pairs = 20;
        function new(string name = "bs_sram_rand_seq"); super.new(name); endfunction
        task body();
            repeat (num_pairs / 2) send_rand_write();
            repeat (num_pairs)     send_rand_read();
        endtask
    endclass 

    // --------------------------------------------------------------------------
    // Full LeNet-5 integration: all 6 bias layers
    //   Total biases per layer: C1=6, S2=6, C3=16, S4=16, C5=120, F6=84 = 248
    //   But TOTAL_BIASES=236 in DUT, so we respect that budget.
    //   Layout used here (cumulative start addresses):
    //     C1 @ 0    (6)
    //     S2 @ 6    (6)
    //     C3 @ 12   (16)
    //     S4 @ 28   (16)
    //     C5 @ 44   (120)  -> 8 burst-reads of 15 to exhaust
    //     F6 @ 164  (72)   -> 236-164=72 to stay within TOTAL_BIASES
    // --------------------------------------------------------------------------
    class bs_sram_lenet_seq extends bs_sram_base_seq;
        `uvm_object_utils(bs_sram_lenet_seq)
        function new(string name = "bs_sram_lenet_seq"); super.new(name); endfunction
        task body();
            // ----- Write all layers -----
            // C1 (6 biases @ abs 0)
            for (int i = 0; i < 6; i++)
                send_write(i, 32'(i * 200 - 600), 0);

            // S2 (6 biases @ abs 6)
            for (int i = 0; i < 6; i++)
                send_write(6 + i, 32'(i * 150 + 50), 0);

            // C3 (16 biases @ abs 12)
            for (int i = 0; i < 16; i++)
                send_write(12 + i, 32'(i * 300 - 2400), 0);

            // S4 (16 biases @ abs 28)
            for (int i = 0; i < 16; i++)
                send_write(28 + i, 32'(i * 100 + 10), 0);

            // C5 (120 biases @ abs 44)
            for (int i = 0; i < 120; i++)
                send_write(44 + i, 32'(i ^ 32'h3C3C3C3C), 0);

            // F6 (72 biases @ abs 164, capped to fit TOTAL_BIASES=236)
            for (int i = 0; i < 72; i++)
                send_write(164 + i, 32'(i ^ 32'h55AA55AA), 0);

            // ----- Read all layers via layer_offset -----
            // C1: burst of 6
            send_read(0, 6, 0);

            // S2: burst of 6 via offset=6
            send_read(0, 6, 6);

            // C3: burst of 16 via offset=12
            send_read(0, 16, 12);

            // S4: burst of 16 via offset=28
            send_read(0, 16, 28);

            // C5: 8 x burst-16 via offset=44 (covers all 120 in 8 tiles of 15)
            for (int tile = 0; tile < 8; tile++)
                send_read(tile * 15, 15, 44);

            // F6: 5 x burst-14 via offset=164 (covers 70 of 72)
            for (int tile = 0; tile < 5; tile++)
                send_read(tile * 14, 14, 164);
            // last 2
            send_read(70, 2, 164);
        endtask
    endclass 
    // --------------------------------------------------------------------------
    // Full regression sequence
    // --------------------------------------------------------------------------
    class bs_sram_regression_seq extends bs_sram_base_seq;
        `uvm_object_utils(bs_sram_regression_seq)
        function new(string name = "bs_sram_regression_seq"); super.new(name); endfunction
        task body();
            bs_sram_smoke_seq     smoke  = bs_sram_smoke_seq    ::type_id::create("smoke");
            bs_sram_offset_seq    off    = bs_sram_offset_seq   ::type_id::create("off");
            bs_sram_burst_len_seq blen   = bs_sram_burst_len_seq::type_id::create("blen");
            bs_sram_wr_rd_seq     wrrd   = bs_sram_wr_rd_seq    ::type_id::create("wrrd");
            bs_sram_b2b_read_seq  b2b    = bs_sram_b2b_read_seq ::type_id::create("b2b");
            bs_sram_signed_seq    sgn    = bs_sram_signed_seq   ::type_id::create("sgn");
            bs_sram_lenet_seq     lenet  = bs_sram_lenet_seq    ::type_id::create("lenet");
            bs_sram_rand_seq      rnd    = bs_sram_rand_seq     ::type_id::create("rnd");
            rnd.num_pairs = 50;
            `uvm_info("BS_REG", "=== Regression start ===", UVM_NONE)
            smoke.start(m_sequencer);
            off.start(m_sequencer);
            blen.start(m_sequencer);
            wrrd.start(m_sequencer);
            b2b.start(m_sequencer);
            sgn.start(m_sequencer);
            lenet.start(m_sequencer);
            rnd.start(m_sequencer);
            `uvm_info("BS_REG", "=== Regression complete ===", UVM_NONE)
        endtask
    endclass 