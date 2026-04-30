    // =========================================================================
    // 9. BASE SEQUENCE  – helper tasks used by all derived sequences
    // =========================================================================
    class fm_base_seq extends uvm_sequence #(fm_seq_item);
        `uvm_object_utils(fm_base_seq)
        function new(string name = "fm_base_seq"); super.new(name); endfunction

        // ---- Directed write ----
        task send_write(int unsigned addr,
                        logic signed [PKG_DATA_WIDTH-1:0] data);
            fm_seq_item item = fm_seq_item::type_id::create("item");
            start_item(item);
            item.is_write = 1;
            item.wr_addr  = addr;
            item.wr_data  = data;
            finish_item(item);
        endtask

        // ---- Directed read: choose which ports to activate ----
        // port_mask[2:0] selects ports; each active port reads its addr.
        task send_read(
            input bit [2:0]                          port_mask,
            input logic [PKG_ADDR_WIDTH-1:0]         addrs [PKG_NUM_PORTS]
        );
            fm_seq_item item = fm_seq_item::type_id::create("item");
            start_item(item);
            item.is_write          = 0;
            item.wr_en_during_read = 0;
            for (int p = 0; p < PKG_NUM_PORTS; p++) begin
                item.rd_req [p] = port_mask[p];
                item.rd_addr[p] = addrs[p];
            end
            finish_item(item);
        endtask

        // ---- Directed read+write conflict injection ----
        task send_conflict(
            input bit [2:0]                         port_mask,
            input logic [PKG_ADDR_WIDTH-1:0]        rd_addrs [PKG_NUM_PORTS],
            input logic [PKG_ADDR_WIDTH-1:0]        wr_addr,
            input logic signed [PKG_DATA_WIDTH-1:0] wr_data
        );
            fm_seq_item item = fm_seq_item::type_id::create("item");
            start_item(item);
            item.is_write              = 0;
            item.wr_en_during_read     = 1;
            item.wr_addr_during_read   = wr_addr;
            item.wr_data_during_read   = wr_data;
            for (int p = 0; p < PKG_NUM_PORTS; p++) begin
                item.rd_req [p] = port_mask[p];
                item.rd_addr[p] = rd_addrs[p];
            end
            finish_item(item);
        endtask

        // ---- Random write ----
        task send_rand_write();
            fm_seq_item item = fm_seq_item::type_id::create("item");
            start_item(item);
            item.is_write = 1;
            if (!item.randomize() with { is_write == 1; })
                `uvm_fatal("FM_SEQ", "Write randomize failed")
            finish_item(item);
        endtask

        // ---- Random read (no concurrent write) ----
        task send_rand_read();
            fm_seq_item item = fm_seq_item::type_id::create("item");
            start_item(item);
            item.is_write = 0;
            if (!item.randomize() with {
                    is_write == 0;
                    wr_en_during_read == 0;
                    // At least one port active
                    (rd_req[0] | rd_req[1] | rd_req[2]) == 1;
                })
                `uvm_fatal("FM_SEQ", "Read randomize failed")
            finish_item(item);
        endtask

        // ---- Random read with possible concurrent write ----
        task send_rand_conflict();
            fm_seq_item item = fm_seq_item::type_id::create("item");
            start_item(item);
            item.is_write = 0;
            // Disable c_no_concurrent so wr_en_during_read can be forced to 1
            item.c_no_concurrent.constraint_mode(0);
            if (!item.randomize() with {
                    is_write == 0;
                    wr_en_during_read == 1;
                    (rd_req[0] | rd_req[1] | rd_req[2]) == 1;
                })
                `uvm_fatal("FM_SEQ", "Conflict randomize failed")
            finish_item(item);
        endtask

    endclass 


    // =========================================================================
    // 10. SEQUENCES
    // =========================================================================

    // ---------- Smoke: write 8 locations, read back on all ports ----------
    class fm_smoke_seq extends fm_base_seq;
        `uvm_object_utils(fm_smoke_seq)
        function new(string name = "fm_smoke_seq"); super.new(name); endfunction
        task body();
            logic [PKG_ADDR_WIDTH-1:0] addrs [PKG_NUM_PORTS];

            // Write 8 known values
            for (int i = 0; i < 8; i++)
                send_write(i, 8'(i * 7 + 1));

            // Port 0 reads addr 0
            addrs[0] = 0; addrs[1] = 0; addrs[2] = 0;
            send_read(3'b001, addrs);

            // Port 1 reads addr 3 (different bank from 0)
            addrs[0] = 0; addrs[1] = 3; addrs[2] = 0;
            send_read(3'b010, addrs);

            // Port 2 reads addr 6 (different bank again)
            addrs[0] = 0; addrs[1] = 0; addrs[2] = 6;
            send_read(3'b100, addrs);

            // All 3 ports reading simultaneously – different banks
            addrs[0] = 0; addrs[1] = 1; addrs[2] = 2;
            send_read(3'b111, addrs);
        endtask
    endclass 

    // ---------- Multi-port: all 8 combinations of port_mask ----------
    class fm_multiport_seq extends fm_base_seq;
        `uvm_object_utils(fm_multiport_seq)
        function new(string name = "fm_multiport_seq"); super.new(name); endfunction
        task body();
            logic [PKG_ADDR_WIDTH-1:0] addrs [PKG_NUM_PORTS];

            // Pre-load known data: first 9 addresses
            for (int i = 0; i < 9; i++)
                send_write(i, 8'(i + 10));

            // Each port reads a different bank to avoid conflict
            // bank0 addrs: 0,3,6  bank1 addrs: 1,4,7  bank2 addrs: 2,5,8
            // Iterate all 7 non-zero port combinations
            for (int mask = 1; mask < 8; mask++) begin
                addrs[0] = 0;  // bank0
                addrs[1] = 1;  // bank1
                addrs[2] = 2;  // bank2
                send_read(3'(mask), addrs);
            end

            // All ports same address (same bank → no conflict since only reads)
            addrs[0] = 5; addrs[1] = 5; addrs[2] = 5;
            send_read(3'b111, addrs);

            // All ports crossing banks: p0→bank0, p1→bank0, p2→bank0
            addrs[0] = 0; addrs[1] = 3; addrs[2] = 6;
            send_read(3'b111, addrs);

            // In fm_multiport_seq body(), add after the existing reads:

// Ensure all single-port + each bank is covered
addrs[0]=0; addrs[1]=0; addrs[2]=0;
send_read(3'b001, addrs);   // p0 only, bank0
addrs[0]=1; addrs[1]=0; addrs[2]=0;
send_read(3'b001, addrs);   // p0 only, bank1
addrs[0]=2; addrs[1]=0; addrs[2]=0;
send_read(3'b001, addrs);   // p0 only, bank2

addrs[0]=0; addrs[1]=0; addrs[2]=0;
send_read(3'b010, addrs);   // p1 only, bank0
addrs[0]=0; addrs[1]=1; addrs[2]=0;
send_read(3'b010, addrs);   // p1 only, bank1
addrs[0]=0; addrs[1]=2; addrs[2]=0;
send_read(3'b010, addrs);   // p1 only, bank2

addrs[0]=0; addrs[1]=0; addrs[2]=0;
send_read(3'b100, addrs);   // p2 only, bank0
addrs[0]=0; addrs[1]=0; addrs[2]=1;
send_read(3'b100, addrs);   // p2 only, bank1
addrs[0]=0; addrs[1]=0; addrs[2]=2;
send_read(3'b100, addrs);   // p2 only, bank2

// Two ports, same bank (all combinations)
addrs[0]=0; addrs[1]=3; addrs[2]=0;
send_read(3'b011, addrs);   // p0+p1, both bank0
addrs[0]=1; addrs[1]=4; addrs[2]=0;
send_read(3'b011, addrs);   // p0+p1, both bank1
addrs[0]=2; addrs[1]=5; addrs[2]=0;
send_read(3'b011, addrs);   // p0+p1, both bank2

addrs[0]=0; addrs[1]=0; addrs[2]=3;
send_read(3'b101, addrs);   // p0+p2, both bank0
addrs[0]=1; addrs[1]=0; addrs[2]=4;
send_read(3'b101, addrs);   // p0+p2, both bank1
addrs[0]=2; addrs[1]=0; addrs[2]=5;
send_read(3'b101, addrs);   // p0+p2, both bank2

addrs[0]=0; addrs[1]=0; addrs[2]=3;
send_read(3'b110, addrs);   // p1+p2, both bank0
addrs[0]=0; addrs[1]=1; addrs[2]=4;
send_read(3'b110, addrs);   // p1+p2, both bank1
addrs[0]=0; addrs[1]=2; addrs[2]=5;
send_read(3'b110, addrs);   // p1+p2, both bank2

// All 3 ports, all same bank
addrs[0]=0; addrs[1]=3; addrs[2]=6;
send_read(3'b111, addrs);   // all bank0
addrs[0]=1; addrs[1]=4; addrs[2]=7;
send_read(3'b111, addrs);   // all bank1
addrs[0]=2; addrs[1]=5; addrs[2]=8;
send_read(3'b111, addrs);   // all bank2
        endtask
    endclass 

    // ---------- Bank conflict: write vs read same bank ----------
    class fm_conflict_seq extends fm_base_seq;
        `uvm_object_utils(fm_conflict_seq)
        function new(string name = "fm_conflict_seq"); super.new(name); endfunction
        task body();
            logic [PKG_ADDR_WIDTH-1:0] rd [PKG_NUM_PORTS];

            /// Pre-load ALL locations so no address returns 'x'
    for (int i = 0; i < PKG_TOTAL_ELEMENTS; i++)
        send_write(i, 8'(i * 3));   // or any deterministic pattern

    // Now directed conflict tests
    rd[0]=0; rd[1]=1; rd[2]=2;
    send_conflict(3'b001, rd, 0, 8'hAA);

            // Conflict: wr_addr=1 (bank1), p1 reads addr=1 (bank1) → conflict
            rd[0]=0; rd[1]=1; rd[2]=2;
            send_conflict(3'b010, rd, 1, 8'hBB);   // same bank1 → conflict

            // Conflict: wr_addr=2 (bank2), p2 reads addr=2 (bank2) → conflict
            rd[0]=0; rd[1]=1; rd[2]=2;
            send_conflict(3'b100, rd, 2, 8'hCC);   // same bank2 → conflict

            // All 3 ports active, wr hits bank0 → port0 conflict only
            rd[0]=0; rd[1]=1; rd[2]=2;
            send_conflict(3'b111, rd, 3, 8'hDD);   // wr@3→bank0, p0@0→bank0

            // Random conflict injections
            repeat (8) send_rand_conflict();
        endtask
    endclass 

    // ---------- No-conflict: write and reads on different banks ----------
    class fm_no_conflict_seq extends fm_base_seq;
        `uvm_object_utils(fm_no_conflict_seq)
        function new(string name = "fm_no_conflict_seq"); super.new(name); endfunction


        task body();
    logic [PKG_ADDR_WIDTH-1:0] rd [PKG_NUM_PORTS];

    // Pre-load ALL locations
    for (int i = 0; i < PKG_TOTAL_ELEMENTS; i++)
        send_write(i, 8'(i + 50));

    // wr@bank0 (addr=0), reads on bank1 and bank2 → no conflict
    rd[0]=1; rd[1]=2; rd[2]=4;
    send_conflict(3'b111, rd, 0, 8'h11);

    // wr@bank1 (addr=1), reads on bank0 and bank2 → no conflict
    rd[0]=0; rd[1]=2; rd[2]=5;
    send_conflict(3'b111, rd, 1, 8'h22);

    // wr@bank2 (addr=2), reads on bank0 and bank1 → no conflict
    rd[0]=0; rd[1]=1; rd[2]=3;
    send_conflict(3'b111, rd, 2, 8'h33);
endtask

    endclass 

    // ---------- Address sweep: write and read every address 0..863 ----------
    class fm_addr_sweep_seq extends fm_base_seq;
        `uvm_object_utils(fm_addr_sweep_seq)
        function new(string name = "fm_addr_sweep_seq"); super.new(name); endfunction
        task body();
            logic [PKG_ADDR_WIDTH-1:0] addrs [PKG_NUM_PORTS];

            // Write all 864 locations
            for (int i = 0; i < PKG_TOTAL_ELEMENTS; i++)
                send_write(i, 8'(i ^ 8'hA5));

            // Read back every address via port 0
            for (int i = 0; i < PKG_TOTAL_ELEMENTS; i++) begin
                addrs[0] = i; addrs[1] = 0; addrs[2] = 0;
                send_read(3'b001, addrs);
            end

            // Read back in strides of 3 (hits each bank once per triplet)
            // using all 3 ports simultaneously
            for (int i = 0; i < PKG_TOTAL_ELEMENTS - 2; i += 3) begin
                addrs[0] = i;   // bank0
                addrs[1] = i+1; // bank1
                addrs[2] = i+2; // bank2
                send_read(3'b111, addrs);
            end
        endtask
    endclass 

    // ---------- Bank boundary: addresses 0,1,2,3,4,5 and 861,862,863 ----------
    class fm_bank_boundary_seq extends fm_base_seq;
        `uvm_object_utils(fm_bank_boundary_seq)
        function new(string name = "fm_bank_boundary_seq"); super.new(name); endfunction
        task body();
            logic [PKG_ADDR_WIDTH-1:0] addrs [PKG_NUM_PORTS];

            // Write boundary addresses
            send_write(0,   8'h01); // bank0 row0
            send_write(1,   8'h02); // bank1 row0
            send_write(2,   8'h03); // bank2 row0
            send_write(3,   8'h04); // bank0 row1
            send_write(4,   8'h05); // bank1 row1
            send_write(5,   8'h06); // bank2 row1
            send_write(861, 8'h07); // bank0 row287
            send_write(862, 8'h08); // bank1 row287
            send_write(863, 8'h09); // bank2 row287

            // Read boundaries: addr 0,1,2 – each in different bank
            addrs[0]=0; addrs[1]=1; addrs[2]=2;
            send_read(3'b111, addrs);

            // Read addr 3,4,5
            addrs[0]=3; addrs[1]=4; addrs[2]=5;
            send_read(3'b111, addrs);

            // Read top 3 addresses
            addrs[0]=861; addrs[1]=862; addrs[2]=863;
            send_read(3'b111, addrs);

            // Read address 0 on all 3 ports (same bank0, read-read: OK)
            addrs[0]=0; addrs[1]=0; addrs[2]=0;
            send_read(3'b111, addrs);
        endtask
    endclass 

    // ---------- Random: mixed writes and reads ----------
    class fm_rand_seq extends fm_base_seq;
        `uvm_object_utils(fm_rand_seq)
        int unsigned num_writes = 20;
        int unsigned num_reads  = 40;
        function new(string name = "fm_rand_seq"); super.new(name); endfunction

        task body();
    // Pre-load ALL locations so random reads never hit uninitialized memory
    for (int i = 0; i < PKG_TOTAL_ELEMENTS; i++)
        send_write(i, 8'(i ^ 8'h5A));
    // Additional random writes
    repeat (num_writes) send_rand_write();
    // Random reads — now safe across full address space
    repeat (num_reads)  send_rand_read();
endtask

    endclass 

    // ---------- Exhaustive bank pattern (covers all 63 cross bins) ----------
class fm_bank_pattern_seq extends fm_base_seq;
    `uvm_object_utils(fm_bank_pattern_seq)
    function new(string name = "fm_bank_pattern_seq");
        super.new(name);
    endfunction

    task body();
        logic [PKG_ADDR_WIDTH-1:0] addrs [PKG_NUM_PORTS];
        bit [2:0] port_mask;
        // Use representative addresses for each bank
        localparam int unsigned BANK0_ADDR = 0;
        localparam int unsigned BANK1_ADDR = 1;
        localparam int unsigned BANK2_ADDR = 2;
        localparam int unsigned INACTIVE   = 3;

        // Pre‑write the three representative addresses (banks 0,1,2)
        // to ensure deterministic read data
        send_write(BANK0_ADDR, 8'hA0);
        send_write(BANK1_ADDR, 8'hA1);
        send_write(BANK2_ADDR, 8'hA2);

        // Exhaustive cross coverage of (bank0, bank1, bank2) each in {0,1,2,3}
        for (int b0 = 0; b0 <= INACTIVE; b0++) begin
            for (int b1 = 0; b1 <= INACTIVE; b1++) begin
                for (int b2 = 0; b2 <= INACTIVE; b2++) begin
                    // Skip all-inactive
                    if (b0 == INACTIVE && b1 == INACTIVE && b2 == INACTIVE)
                        continue;

                    // Build port mask and address array
                    port_mask = 0;
                    if (b0 != INACTIVE) begin
                        port_mask[0] = 1;
                        addrs[0] = (b0 == 0) ? BANK0_ADDR :
                                   (b0 == 1) ? BANK1_ADDR : BANK2_ADDR;
                    end else begin
                        addrs[0] = 0;
                    end

                    if (b1 != INACTIVE) begin
                        port_mask[1] = 1;
                        addrs[1] = (b1 == 0) ? BANK0_ADDR :
                                   (b1 == 1) ? BANK1_ADDR : BANK2_ADDR;
                    end else begin
                        addrs[1] = 0;
                    end

                    if (b2 != INACTIVE) begin
                        port_mask[2] = 1;
                        addrs[2] = (b2 == 0) ? BANK0_ADDR :
                                   (b2 == 1) ? BANK1_ADDR : BANK2_ADDR;
                    end else begin
                        addrs[2] = 0;
                    end

                    send_read(port_mask, addrs);
                end
            end
        end
    endtask
endclass 

    // ---------- Full regression ----------
    class fm_regression_seq extends fm_base_seq;
        `uvm_object_utils(fm_regression_seq)
        function new(string name = "fm_regression_seq"); super.new(name); endfunction
        task body();
            fm_smoke_seq       smoke   = fm_smoke_seq      ::type_id::create("smoke");
            fm_multiport_seq   mport   = fm_multiport_seq  ::type_id::create("mport");
            fm_conflict_seq    conf    = fm_conflict_seq   ::type_id::create("conf");
            fm_no_conflict_seq noconf  = fm_no_conflict_seq::type_id::create("noconf");
            fm_addr_sweep_seq  sweep   = fm_addr_sweep_seq ::type_id::create("sweep");
            fm_bank_boundary_seq bndry = fm_bank_boundary_seq::type_id::create("bndry");
            fm_bank_pattern_seq pat = fm_bank_pattern_seq::type_id::create("pat");
            fm_rand_seq        rnd     = fm_rand_seq       ::type_id::create("rnd");
            rnd.num_writes = 50; rnd.num_reads = 100;
            `uvm_info("FM_REG", "=== Regression start ===", UVM_NONE)
            smoke.start(m_sequencer);
            mport.start(m_sequencer);
            conf.start(m_sequencer);
            noconf.start(m_sequencer);
            sweep.start(m_sequencer);
            bndry.start(m_sequencer);
            pat.start(m_sequencer);
            rnd.start(m_sequencer);
            `uvm_info("FM_REG", "=== Regression complete ===", UVM_NONE)
        endtask
    endclass 