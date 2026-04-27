    // =========================================================================
    // 2. REFERENCE MODEL
    // =========================================================================
    // Mirrors DUT APPLYING_BIAS state logic exactly.
    // =========================================================================
    class br_ref_model extends uvm_object;
        `uvm_object_utils(br_ref_model)

        function new(string name = "br_ref_model");
            super.new(name);
        endfunction

        // Compute expected output for one item. Fills item.exp_output_data.
        function void predict(br_seq_item item);
            for (int r = 0; r < PKG_TILE_ROWS; r++) begin
                for (int c = 0; c < PKG_ARRAY_COLS; c++) begin
                    int unsigned ch_idx;
                    logic signed [PKG_DATA_WIDTH-1:0] biased;

                    ch_idx = int'(item.conv_channel_start) + c;

                    if (ch_idx < int'(item.out_channels)) begin
                        // Active column: add bias
                        biased = item.conv_data[r][c] + item.bias_values[c];
                        if (item.enable_relu && biased < 0)
                            item.exp_output_data[r][c] = '0;
                        else
                            item.exp_output_data[r][c] = biased;
                    end else begin
                        // Padding column: pass through
                        item.exp_output_data[r][c] = item.conv_data[r][c];
                    end
                end
            end
        endfunction

    endclass