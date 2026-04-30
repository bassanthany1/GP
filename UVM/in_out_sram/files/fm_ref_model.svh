    // =========================================================================
    // 2. REFERENCE MODEL
    // =========================================================================
    // Shadow memory: flat array [0..TOTAL_ELEMENTS-1].
    // Provides write() and predict_read() to compute expected outputs.
    //
    // predict_read() also computes expected bank_conflict:
    //   conflict if wr_en_this_cycle AND any active rd_req hits same bank.
    // =========================================================================
    class fm_ref_model extends uvm_object;
        `uvm_object_utils(fm_ref_model)

        logic signed [PKG_DATA_WIDTH-1:0] mem [PKG_TOTAL_ELEMENTS];

        function new(string name = "fm_ref_model");
            super.new(name);
            foreach (mem[i]) mem[i] = '0;
        endfunction

        // Write one element
        function void write(int unsigned addr,
                            logic signed [PKG_DATA_WIDTH-1:0] data);
            if (addr < PKG_TOTAL_ELEMENTS) mem[addr] = data;
        endfunction

        // Read one element (combinational model - before clock edge)
        function logic signed [PKG_DATA_WIDTH-1:0] read(int unsigned addr);
            if (addr < PKG_TOTAL_ELEMENTS) return mem[addr];
            return '0;
        endfunction

        // Predict full read transaction output.
        // Fills item.exp_rd_data, item.exp_rd_valid, item.exp_bank_conflict.
        // Does NOT write wr_data_during_read to shadow (caller decides).
        function void predict_read(fm_seq_item item);
            int unsigned wr_bank;

            // Expected rd_valid: registered version of rd_req (1 cycle later)
            foreach (item.rd_req[p])
                item.exp_rd_valid[p] = item.rd_req[p];

            // Expected rd_data for each active port
            foreach (item.rd_req[p]) begin
                if (item.rd_req[p])
                    item.exp_rd_data[p] = read(int'(item.rd_addr[p]));
                else
                    item.exp_rd_data[p] = '0; // DUT holds last / resets
            end

            // Expected bank_conflict
            item.exp_bank_conflict = 0;
            if (item.wr_en_during_read) begin
                wr_bank = int'(item.wr_addr_during_read) % 3;
                foreach (item.rd_req[p]) begin
                    if (item.rd_req[p]) begin
                        int unsigned rb;
                        rb = int'(item.rd_addr[p]) % 3;
                        if (rb == wr_bank)
                            item.exp_bank_conflict = 1;
                    end
                end
            end
        endfunction

    endclass 