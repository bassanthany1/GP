 // =========================================================================
    // 2. REFERENCE MODEL
    // =========================================================================
    class wf_sram_ref_model extends uvm_object;
        `uvm_object_utils(wf_sram_ref_model)

        logic signed [PKG_DATA_WIDTH-1:0] bram [PKG_BRAM_DEPTH];

        function new(string name = "wf_sram_ref_model");
            super.new(name);
            foreach (bram[i]) bram[i] = '0;
        endfunction

        function void write_beat(int unsigned addr,
                                 logic signed [PKG_DATA_WIDTH-1:0] data);
            if (addr < PKG_BRAM_DEPTH) bram[addr] = data;
        endfunction

        function void predict_burst(int unsigned abs_addr,
                                    int unsigned burst_len,
                                    ref logic signed [PKG_DATA_WIDTH-1:0] expected[$]);
            expected.delete();
            for (int i = 0; i < int'(burst_len); i++) begin
                int unsigned a = abs_addr + i;
                expected.push_back((a < PKG_BRAM_DEPTH) ? bram[a] : '0);
            end
        endfunction

    endclass 