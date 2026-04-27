   // =========================================================================
    // 9. BASE SEQUENCE
    // =========================================================================
    class wf_sram_base_seq extends uvm_sequence #(wf_sram_seq_item);
        `uvm_object_utils(wf_sram_base_seq)
        function new(string name = "wf_sram_base_seq"); super.new(name); endfunction

        task send_write(int unsigned addr,
                        logic signed [PKG_DATA_WIDTH-1:0] data,
                        int unsigned offset = 0);
            wf_sram_seq_item item = wf_sram_seq_item::type_id::create("item");
            start_item(item);
            item.is_write     = 1;
            item.write_addr   = addr;
            item.write_data   = data;
            item.layer_offset = offset;
            finish_item(item);
        endtask

        task send_read(int unsigned addr, int unsigned len, int unsigned offset = 0);
            wf_sram_seq_item item = wf_sram_seq_item::type_id::create("item");
            start_item(item);
            item.is_write     = 0;
            item.read_addr    = addr;
            item.burst_length = len;
            item.layer_offset = offset;
            finish_item(item);
        endtask

        task send_rand_write();
            wf_sram_seq_item item = wf_sram_seq_item::type_id::create("item");
            start_item(item);
            item.is_write = 1;
            if (!item.randomize() with { is_write == 1; })
                `uvm_fatal("WF_SEQ", "Write randomize failed")
            finish_item(item);
        endtask

        task send_rand_read();
            wf_sram_seq_item item = wf_sram_seq_item::type_id::create("item");
            start_item(item);
            item.is_write = 0;
            if (!item.randomize() with { is_write == 0; })
                `uvm_fatal("WF_SEQ", "Read randomize failed")
            finish_item(item);
        endtask

    endclass : wf_sram_base_seq


    // =========================================================================
    // 10. SEQUENCES
    // =========================================================================

    // Smoke: write 8, read back
    class wf_sram_smoke_seq extends wf_sram_base_seq;
        `uvm_object_utils(wf_sram_smoke_seq)
        function new(string name = "wf_sram_smoke_seq"); super.new(name); endfunction
        task body();
            for (int i = 0; i < 8; i++)
                send_write(i, 8'(i * 3 + 1), 0);
            send_read(0, 8, 0);
        endtask
    endclass

    // Layer offset: verify layer_offset + read_addr address translation
    class wf_sram_offset_seq extends wf_sram_base_seq;
        `uvm_object_utils(wf_sram_offset_seq)
        function new(string name = "wf_sram_offset_seq"); super.new(name); endfunction
        task body();
            // Conv1 layer at offset 0
            for (int i = 0; i < 16; i++)
                send_write(i, 8'(i - 8), 0);
            send_read(0, 16, 0);

            // Conv2 layer at offset 150
            for (int i = 0; i < 8; i++)
                send_write(150 + i, 8'(i * 5), 0);
            send_read(0, 8, 150);
        endtask
    endclass

    // Burst length stress: min, mid, max
    class wf_sram_burst_len_seq extends wf_sram_base_seq;
        `uvm_object_utils(wf_sram_burst_len_seq)
        function new(string name = "wf_sram_burst_len_seq"); super.new(name); endfunction
        task body();
            for (int i = 0; i < PKG_MAX_BURST_LEN; i++)
                send_write(i, 8'(i ^ 8'hA5), 0);
            send_read(0, 1,                  0);
            send_read(0, 16,                 0);
            send_read(0, 64,                 0);
            send_read(0, 255,                0);
            send_read(0, PKG_MAX_BURST_LEN,  0);
        endtask
    endclass

    // Write-then-read interleaved
    class wf_sram_wr_rd_seq extends wf_sram_base_seq;
        `uvm_object_utils(wf_sram_wr_rd_seq)
        function new(string name = "wf_sram_wr_rd_seq"); super.new(name); endfunction
        task body();
            for (int i = 0; i < 16; i++) begin
                send_write(i * 4, 8'(i * 7 + 3), 0);
                send_read(i * 4, 4, 0);
            end
        endtask
    endclass

    // Back-to-back reads
    class wf_sram_b2b_read_seq extends wf_sram_base_seq;
        `uvm_object_utils(wf_sram_b2b_read_seq)
        function new(string name = "wf_sram_b2b_read_seq"); super.new(name); endfunction
        task body();
            for (int i = 0; i < 256; i++) send_write(i, 8'(i), 0);
            send_read(0,   32, 0);
            send_read(32,  32, 0);
            send_read(64,  32, 0);
            send_read(128, 32, 0);
        endtask
    endclass

    // Random pairs
    class wf_sram_rand_seq extends wf_sram_base_seq;
        `uvm_object_utils(wf_sram_rand_seq)
        int unsigned num_pairs = 20;
        function new(string name = "wf_sram_rand_seq"); super.new(name); endfunction
        task body();
            repeat (num_pairs / 2) send_rand_write();
            repeat (num_pairs)     send_rand_read();
        endtask
    endclass

    // LeNet-5 integration
    class wf_sram_lenet_seq extends wf_sram_base_seq;
        `uvm_object_utils(wf_sram_lenet_seq)
        function new(string name = "wf_sram_lenet_seq"); super.new(name); endfunction
        task body();
            for (int i = 0; i < 150; i++)
                send_write(i, 8'(i ^ 8'h3C), 0);
            for (int i = 0; i < 256; i++)
                send_write(150 + i, 8'(i ^ 8'h55), 0);
            send_read(0,   25,  0);
            send_read(75,  25,  0);
            send_read(0,   150, 150);
            send_read(150, 150, 150);
        endtask
    endclass

    // Full regression
    class wf_sram_regression_seq extends wf_sram_base_seq;
        `uvm_object_utils(wf_sram_regression_seq)
        function new(string name = "wf_sram_regression_seq"); super.new(name); endfunction
        task body();
            wf_sram_smoke_seq     smoke = wf_sram_smoke_seq    ::type_id::create("smoke");
            wf_sram_offset_seq    off   = wf_sram_offset_seq   ::type_id::create("off");
            wf_sram_burst_len_seq blen  = wf_sram_burst_len_seq::type_id::create("blen");
            wf_sram_wr_rd_seq     wrrd  = wf_sram_wr_rd_seq    ::type_id::create("wrrd");
            wf_sram_b2b_read_seq  b2b   = wf_sram_b2b_read_seq ::type_id::create("b2b");
            wf_sram_rand_seq      rnd   = wf_sram_rand_seq     ::type_id::create("rnd");
            wf_sram_lenet_seq     lenet = wf_sram_lenet_seq    ::type_id::create("lenet");
            rnd.num_pairs = 50;
            `uvm_info("WF_REG", "=== Regression start ===", UVM_NONE)
            smoke.start(m_sequencer);
            off.start(m_sequencer);
            blen.start(m_sequencer);
            wrrd.start(m_sequencer);
            b2b.start(m_sequencer);
            lenet.start(m_sequencer);
            rnd.start(m_sequencer);
            `uvm_info("WF_REG", "=== Regression complete ===", UVM_NONE)
        endtask
    endclass