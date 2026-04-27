// =========================================================================
// 1. SEQUENCE ITEM
// =========================================================================
    class bs_sram_seq_item extends uvm_sequence_item;
        `uvm_object_utils(bs_sram_seq_item)

        // Transaction type
        bit is_write;

        // Write fields
        rand logic [$clog2(PKG_TOTAL_BIASES)-1:0]    write_addr;
        rand logic signed [PKG_DATA_WIDTH-1:0]        write_data;

        // Read fields
        rand logic [$clog2(PKG_MAX_BIASES)-1:0]       read_addr;
        rand logic [$clog2(PKG_MAX_BURST_LEN+1)-1:0]  burst_length;

        // Common
        rand logic [$clog2(PKG_TOTAL_BIASES+1)-1:0]   layer_offset;

        // Response (filled by monitor)
        logic signed [PKG_DATA_WIDTH-1:0] read_beats[$];
        bit                               burst_complete_seen;

        // Expected (filled by driver from ref model)
        logic signed [PKG_DATA_WIDTH-1:0] expected_beats[$];

        constraint c_write_addr   { write_addr   < PKG_TOTAL_BIASES; }
        constraint c_read_addr    { read_addr    < PKG_MAX_BIASES;   }
        constraint c_burst_length { burst_length inside {[1:PKG_MAX_BURST_LEN]}; }
        constraint c_no_overflow  {
            !is_write ->
            (layer_offset + read_addr + burst_length) <= PKG_TOTAL_BIASES;
        }

        function string convert2string();
            if (is_write)
                return $sformatf("WR addr=0x%02x data=%0d offset=%0d",
                    write_addr, $signed(write_data), layer_offset);
            else
                return $sformatf("RD addr=0x%02x offset=%0d len=%0d",
                    read_addr, layer_offset, burst_length);
        endfunction

    endclass