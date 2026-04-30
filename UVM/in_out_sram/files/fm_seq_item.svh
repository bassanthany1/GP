// =========================================================================
    // 1. SEQUENCE ITEM
    // =========================================================================
    // One item covers ONE complete stimulus cycle:
    //   is_write = 1  -> single-port write (wr_en + wr_addr + wr_data)
    //   is_write = 0  -> multi-port read   (rd_req[0..2] + rd_addr[0..2])
    //
    // On read items the monitor fills:
    //   obs_rd_data [NUM_PORTS]   - captured DUT read outputs
    //   obs_rd_valid[NUM_PORTS]   - captured rd_valid
    //   obs_bank_conflict         - captured bank_conflict
    //
    // The driver/ref-model fills:
    //   exp_rd_data [NUM_PORTS]   - expected data from shadow memory
    //   exp_bank_conflict         - expected conflict flag
    // =========================================================================
    class fm_seq_item extends uvm_sequence_item;
        `uvm_object_utils(fm_seq_item)

        // ---- Transaction type ----
        bit is_write;

        // ---- Write fields ----
        rand logic [PKG_ADDR_WIDTH-1:0]          wr_addr;
        rand logic signed [PKG_DATA_WIDTH-1:0]   wr_data;

        // ---- Read fields (3 ports) ----
        rand logic                                rd_req  [PKG_NUM_PORTS];
        rand logic [PKG_ADDR_WIDTH-1:0]          rd_addr [PKG_NUM_PORTS];

        // ---- Simultaneous write-during-read (conflict scenario) ----
        // When is_write=0 but wr_en_during_read=1, the driver also asserts
        // wr_en this cycle so we can test bank_conflict.
        rand bit                                  wr_en_during_read;
        rand logic [PKG_ADDR_WIDTH-1:0]          wr_addr_during_read;
        rand logic signed [PKG_DATA_WIDTH-1:0]   wr_data_during_read;

        // ---- Observed (filled by monitor) ----
        logic signed [PKG_DATA_WIDTH-1:0]        obs_rd_data  [PKG_NUM_PORTS];
        logic                                     obs_rd_valid [PKG_NUM_PORTS];
        logic                                     obs_bank_conflict;

        // ---- Expected (filled by driver via ref model) ----
        logic signed [PKG_DATA_WIDTH-1:0]        exp_rd_data  [PKG_NUM_PORTS];
        bit                                       exp_rd_valid [PKG_NUM_PORTS];
        bit                                       exp_bank_conflict;

        // ---- Constraints ----
        constraint c_wr_addr   { wr_addr < PKG_TOTAL_ELEMENTS; }
        constraint c_rd_addrs  {
            foreach (rd_addr[p]) rd_addr[p] < PKG_TOTAL_ELEMENTS;
        }
        constraint c_wr_during { wr_addr_during_read < PKG_TOTAL_ELEMENTS; }

        // By default don't inject concurrent write on read cycles (keep clean)
        constraint c_no_concurrent { wr_en_during_read == 0; }

        function string convert2string();
            if (is_write)
                return $sformatf("WR addr=%0d data=%0d",
                    wr_addr, $signed(wr_data));
            else begin
                string s;
                s = $sformatf("RD req=[%0b,%0b,%0b] addr=[%0d,%0d,%0d]",
                    rd_req[0], rd_req[1], rd_req[2],
                    rd_addr[0], rd_addr[1], rd_addr[2]);
                if (wr_en_during_read)
                    s = {s, $sformatf(" +WR@%0d", wr_addr_during_read)};
                return s;
            end
        endfunction

    endclass