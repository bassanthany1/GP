    // =========================================================================
    // 1. SEQUENCE ITEM
    // =========================================================================
    // One item covers one complete conv tile transaction:
    //   - stimulus  : conv_data, conv_channel_start, conv_window_idx_start,
    //                 enable_relu, out_channels
    //   - observed  : output_data (filled by monitor)
    //   - expected  : exp_output_data (filled by driver/ref model)
    // =========================================================================
    class br_seq_item extends uvm_sequence_item;
        `uvm_object_utils(br_seq_item)

        // ---- Stimulus ----
        rand logic                          enable_relu;
        rand logic [CHN_W-1:0]             out_channels;
        rand logic [CH_W-1:0]              conv_channel_start;
        rand logic [PKG_WIN_IDX_W-1:0]    conv_window_idx_start;
        rand logic signed [PKG_DATA_WIDTH-1:0]
                                            conv_data [PKG_TILE_ROWS][PKG_ARRAY_COLS];
        // Biases to load into the mock SRAM (one per active column)
        rand logic signed [PKG_BIAS_WIDTH-1:0]
                                            bias_values [PKG_ARRAY_COLS];

        // ---- Observed (filled by monitor) ----
        logic signed [PKG_DATA_WIDTH-1:0]
                                            output_data [PKG_TILE_ROWS][PKG_ARRAY_COLS];
        logic [CH_W-1:0]                   output_channel_start;
        logic [PKG_WIN_IDX_W-1:0]         output_window_idx_start;
        logic                              output_valid_seen;

        // ---- Expected (filled by driver via ref model) ----
        logic signed [PKG_DATA_WIDTH-1:0]
                                            exp_output_data [PKG_TILE_ROWS][PKG_ARRAY_COLS];

        // ---- Constraints ----
        // out_channels: at least 1, at most MAX_OUT_CHANNELS
        constraint c_out_ch   { out_channels inside {[1:PKG_MAX_OUT_CHANNELS]}; }

        // conv_channel_start must be a multiple of ARRAY_COLS and leave room
        // for at least one active column
        constraint c_ch_start {
            conv_channel_start < out_channels;
            conv_channel_start % PKG_ARRAY_COLS == 0;
        }

        // Keep conv_data in a reasonable signed range
        constraint c_conv_data_range {
            foreach (conv_data[r,c])
                conv_data[r][c] inside {[-1000:1000]};
        }

        // Keep biases in a reasonable signed range
        constraint c_bias_range {
            foreach (bias_values[c])
                bias_values[c] inside {[-500:500]};
        }

        function string convert2string();
            return $sformatf(
                "ch_start=%0d win=%0d relu=%0b out_ch=%0d",
                conv_channel_start, conv_window_idx_start,
                enable_relu, out_channels);
        endfunction

    endclass