// =============================================================================
// bias_relu_tb.sv
// Full UVM Verification for bias_add_relu_streaming
// Pattern: single-package, plain uvm_analysis_imp, no tagged imps.
//
// Compile:  vlog bias_relu_tb.sv
// Run:      vsim -c bias_relu_tb_top +UVM_TESTNAME=br_full_test -do "run -all"
//
// Tests available:
//   br_smoke_test         - basic bias+relu sanity
//   br_relu_test          - relu boundary corners
//   br_padding_test       - partial channel tile (ch_idx >= out_channels)
//   br_window_test        - window_idx passthrough
//   br_back2back_test     - back-to-back conv_valid transactions
//   br_rand_test          - constrained-random
//   br_regression_test    - full regression
//   br_full_test          - everything (default)
// =============================================================================


// =============================================================================
// PACKAGE
// =============================================================================
package br_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // -------------------------------------------------------------------------
    // Parameters – must match DUT
    // -------------------------------------------------------------------------
    localparam int PKG_MAX_OUT_CHANNELS = 120;
    localparam int PKG_TILE_ROWS        = 4;
    localparam int PKG_ARRAY_COLS       = 4;
    localparam int PKG_DATA_WIDTH       = 32;
    localparam int PKG_BIAS_WIDTH       = 32;
    localparam int PKG_MAX_BURST_LEN    = 32;
    localparam int PKG_WIN_IDX_W        = 10;   // $clog2(1024)

    // Derived widths (mirrors DUT's $clog2 expressions)
    localparam int CH_W  = $clog2(PKG_MAX_OUT_CHANNELS);       // channel addr width
    localparam int CHN_W = $clog2(PKG_MAX_OUT_CHANNELS + 1);  // out_channels width
    localparam int BL_W  = $clog2(PKG_MAX_BURST_LEN + 1);     // burst_len width


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


    // =========================================================================
    // 3. DRIVER
    // =========================================================================
    // Drives conv stimulus and responds to bias SRAM burst requests.
    //
    // Protocol:
    //   1. Wait for DUT to be idle (output_valid low, no pending request).
    //   2. Assert conv_valid for one cycle with the conv_data tile.
    //   3. Monitor bias_sram_read_req – when asserted, stream back
    //      bias_sram_data one per cycle with bias_sram_valid, then pulse
    //      bias_sram_burst_done.
    //   4. Wait for output_valid from DUT (signalling the monitor to latch).
    // =========================================================================
    class br_driver extends uvm_driver #(br_seq_item);
        `uvm_component_utils(br_driver)

        virtual br_if vif;

        br_ref_model drv_ref;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv_ref = br_ref_model::type_id::create("drv_ref");
            if (!uvm_config_db #(virtual br_if)::get(this, "", "vif", vif))
                `uvm_fatal("BR_DRV", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            br_seq_item item;
            apply_reset();
            forever begin
                seq_item_port.get_next_item(item);
                drive_transaction(item);
                seq_item_port.item_done();
            end
        endtask

        // ---- Reset ----
        task apply_reset();
            vif.cb_drv.rst                   <= 1'b1;
            vif.cb_drv.enable_relu           <= 1'b0;
            vif.cb_drv.out_channels          <= '0;
            vif.cb_drv.conv_valid            <= 1'b0;
            vif.cb_drv.conv_channel_start    <= '0;
            vif.cb_drv.conv_window_idx_start <= '0;
            vif.cb_drv.bias_sram_data        <= '0;
            vif.cb_drv.bias_sram_valid       <= 1'b0;
            vif.cb_drv.bias_sram_burst_done  <= 1'b0;
            foreach (vif.cb_drv.conv_data[r,c])
                vif.cb_drv.conv_data[r][c] <= '0;
            repeat (5) @(vif.cb_drv);
            vif.cb_drv.rst <= 1'b0;
            repeat (3) @(vif.cb_drv);
        endtask

        // ---- Drive one full transaction ----
        task drive_transaction(br_seq_item item);
            // Compute expected output BEFORE driving (ref model)
            drv_ref.predict(item);

            // Set static inputs
            vif.cb_drv.enable_relu  <= item.enable_relu;
            vif.cb_drv.out_channels <= item.out_channels;
            @(vif.cb_drv);

            // Pulse conv_valid for exactly one cycle
            vif.cb_drv.conv_valid            <= 1'b1;
            vif.cb_drv.conv_channel_start    <= item.conv_channel_start;
            vif.cb_drv.conv_window_idx_start <= item.conv_window_idx_start;
            foreach (vif.cb_drv.conv_data[r,c])
                vif.cb_drv.conv_data[r][c] <= item.conv_data[r][c];
            @(vif.cb_drv);
            vif.cb_drv.conv_valid <= 1'b0;

            // Wait for DUT to request bias burst, then service it
            service_bias_burst(item);

            // Wait for output_valid (monitor will capture the actual data)
            wait_output_valid();

            // Small idle gap between transactions
            repeat (2) @(vif.cb_drv);

            `uvm_info("BR_DRV", $sformatf("Drove: %s", item.convert2string()), UVM_MEDIUM)
        endtask

        // ---- Service one bias SRAM burst ----
        // DUT asserts bias_sram_read_req, provides addr & burst_len.
        // Driver responds with bias_sram_valid + data for each beat,
        // then asserts bias_sram_burst_done for one cycle.
        task service_bias_burst(br_seq_item item);
            int unsigned burst_len;
            int unsigned watchdog = 0;
            int unsigned max_wait = 20;

            // Wait for bias_sram_read_req
            while (!vif.cb_drv.bias_sram_read_req) begin
                @(vif.cb_drv);
                watchdog++;
                if (watchdog > max_wait)
                    `uvm_fatal("BR_DRV", "Timeout waiting for bias_sram_read_req")
            end

            burst_len = int'(vif.cb_drv.bias_sram_burst_len);
            @(vif.cb_drv); // req was seen this cycle; data starts next

            // Stream burst_len beats with bias_sram_valid
            for (int i = 0; i < int'(burst_len); i++) begin
                vif.cb_drv.bias_sram_valid <= 1'b1;
                // Use bias_values[i] for valid columns; wrap if burst > ARRAY_COLS
                vif.cb_drv.bias_sram_data  <=
                    (i < PKG_ARRAY_COLS) ? item.bias_values[i] :
                                           item.bias_values[PKG_ARRAY_COLS-1];
                @(vif.cb_drv);
            end
            vif.cb_drv.bias_sram_valid <= 1'b0;

            // Pulse burst_done
            vif.cb_drv.bias_sram_burst_done <= 1'b1;
            @(vif.cb_drv);
            vif.cb_drv.bias_sram_burst_done <= 1'b0;
        endtask

        // ---- Wait for output_valid from DUT ----
        task wait_output_valid();
            int unsigned watchdog = 0;
            int unsigned max_wait = 50;
            while (!vif.cb_drv.output_valid) begin
                @(vif.cb_drv);
                watchdog++;
                if (watchdog > max_wait)
                    `uvm_fatal("BR_DRV", "Timeout waiting for output_valid")
            end
        endtask

    endclass 


    // =========================================================================
    // 4. MONITOR
    // =========================================================================
    // Watches the interface. On output_valid, captures output_data and
    // publishes one br_seq_item. Also captures conv_valid stimulus fields
    // so the scoreboard can match them.
    // =========================================================================
    class br_monitor extends uvm_monitor;
        `uvm_component_utils(br_monitor)

        virtual br_if vif;
        uvm_analysis_port #(br_seq_item) ap;

        // Shadow the stimulus so we can attach it to the response item
        logic                          sh_enable_relu;
        logic [7:0]                    sh_out_channels;
        logic [CH_W-1:0]              sh_ch_start;
        logic [PKG_WIN_IDX_W-1:0]    sh_win_idx;
        logic signed [PKG_DATA_WIDTH-1:0]
                                       sh_conv_data [PKG_TILE_ROWS][PKG_ARRAY_COLS];
        logic signed [PKG_BIAS_WIDTH-1:0]
                                       sh_bias [PKG_ARRAY_COLS];
        int  sh_bias_idx;
        bit  sh_capturing_bias;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual br_if)::get(this, "", "vif", vif))
                `uvm_fatal("BR_MON", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            br_seq_item item;
            forever begin
                @(vif.cb_mon);
                if (vif.cb_mon.rst) begin
                    sh_capturing_bias = 0;
                    sh_bias_idx       = 0;
                    continue;
                end

                // ----- Capture conv stimulus -----
                if (vif.cb_mon.conv_valid) begin
                    sh_enable_relu  = vif.cb_mon.enable_relu;
                    sh_out_channels = vif.cb_mon.out_channels;
                    sh_ch_start     = vif.cb_mon.conv_channel_start;
                    sh_win_idx      = vif.cb_mon.conv_window_idx_start;
                    foreach (sh_conv_data[r,c])
                        sh_conv_data[r][c] = vif.cb_mon.conv_data[r][c];
                    sh_capturing_bias = 1;
                    sh_bias_idx       = 0;
                end

                // ----- Shadow bias SRAM data beats -----
                if (sh_capturing_bias && vif.cb_mon.bias_sram_valid
                    && sh_bias_idx < PKG_ARRAY_COLS) begin
                    sh_bias[sh_bias_idx] = vif.cb_mon.bias_sram_data;
                    sh_bias_idx++;
                end

                // ----- Capture output when valid -----
                if (vif.cb_mon.output_valid) begin
                    item = br_seq_item::type_id::create("mon_item");

                    // Copy shadowed stimulus
                    item.enable_relu           = sh_enable_relu;
                    item.out_channels          = sh_out_channels;
                    item.conv_channel_start    = sh_ch_start;
                    item.conv_window_idx_start = sh_win_idx;
                    foreach (item.conv_data[r,c])
                        item.conv_data[r][c]   = sh_conv_data[r][c];
                    foreach (item.bias_values[c])
                        item.bias_values[c]    = sh_bias[c];

                    // Capture DUT outputs
                    foreach (item.output_data[r,c])
                        item.output_data[r][c] = vif.cb_mon.output_data[r][c];
                    item.output_channel_start    = vif.cb_mon.output_channel_start;
                    item.output_window_idx_start = vif.cb_mon.output_window_idx_start;
                    item.output_valid_seen        = 1'b1;

                    sh_capturing_bias = 0;
                    ap.write(item);

                    `uvm_info("BR_MON",
                        $sformatf("Observed output: %s", item.convert2string()),
                        UVM_MEDIUM)
                end
            end
        endtask

    endclass 


    // =========================================================================
    // 5. SCOREBOARD
    // =========================================================================
    // Receives items from monitor.
    // For each item:
    //   1. Runs ref model to compute expected outputs.
    //   2. Compares DUT output_data vs expected for every [r][c].
    //   3. Checks output_channel_start / output_window_idx_start passthrough.
    // =========================================================================
    class br_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(br_scoreboard)

        uvm_analysis_imp #(br_seq_item, br_scoreboard) analysis_export;

        br_ref_model ref_model;

        int unsigned checks_passed = 0;
        int unsigned checks_failed = 0;
        int unsigned items_checked = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            analysis_export = new("analysis_export", this);
            ref_model       = br_ref_model::type_id::create("ref_model");
        endfunction

        function void write(br_seq_item item);
            // Run reference model
            ref_model.predict(item);
            check_item(item);
        endfunction

        function void check_item(br_seq_item item);
            items_checked++;

            // ---- 1. Check every output pixel ----
            foreach (item.output_data[r,c]) begin
                if (item.output_data[r][c] !== item.exp_output_data[r][c]) begin
                    `uvm_error("BR_SB", $sformatf(
                        "output_data[%0d][%0d] mismatch: got=%0d exp=%0d | %s",
                        r, c,
                        $signed(item.output_data[r][c]),
                        $signed(item.exp_output_data[r][c]),
                        item.convert2string()))
                    checks_failed++;
                end else begin
                    checks_passed++;
                end
            end

            // ---- 2. Check channel_start passthrough ----
            if (item.output_channel_start !== item.conv_channel_start) begin
                `uvm_error("BR_SB", $sformatf(
                    "output_channel_start mismatch: got=%0d exp=%0d",
                    item.output_channel_start, item.conv_channel_start))
                checks_failed++;
            end else checks_passed++;

            // ---- 3. Check window_idx_start passthrough ----
            if (item.output_window_idx_start !== item.conv_window_idx_start) begin
                `uvm_error("BR_SB", $sformatf(
                    "output_window_idx_start mismatch: got=%0d exp=%0d",
                    item.output_window_idx_start, item.conv_window_idx_start))
                checks_failed++;
            end else checks_passed++;

            `uvm_info("BR_SB", $sformatf(
                "Item %0d done - passed=%0d failed=%0d | %s",
                items_checked, checks_passed, checks_failed,
                item.convert2string()), UVM_LOW)
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("BR_SB", "=============================================", UVM_NONE)
            `uvm_info("BR_SB", $sformatf("  TRANSACTIONS : %0d", items_checked),  UVM_NONE)
            `uvm_info("BR_SB", $sformatf("  CHECKS PASSED: %0d", checks_passed),  UVM_NONE)
            `uvm_info("BR_SB", $sformatf("  CHECKS FAILED: %0d", checks_failed),  UVM_NONE)
            `uvm_info("BR_SB", "=============================================", UVM_NONE)
            if (checks_failed > 0)
                `uvm_error("BR_SB", "*** TEST FAILED ***")
            else
                `uvm_info("BR_SB",  "*** TEST PASSED ***", UVM_NONE)
        endfunction

    endclass 


    // =========================================================================
    // 6. COVERAGE
    // =========================================================================
    class br_coverage extends uvm_subscriber #(br_seq_item);
        `uvm_component_utils(br_coverage)

        br_seq_item curr;

        // ---- ReLU enabled/disabled ----
        covergroup cg_relu;
            cp_relu: coverpoint curr.enable_relu {
                bins relu_off = {0};
                bins relu_on  = {1};
            }
        endgroup

        // ---- Channel tile position ----
        covergroup cg_channel_start;
            cp_ch: coverpoint curr.conv_channel_start {
                bins ch_first  = {0};
                bins ch_mid    = {[4:59]};
                bins ch_last   = {[60:116]};
            }
        endgroup

        // ---- Number of active channels ----
        covergroup cg_out_channels;
            cp_n: coverpoint curr.out_channels {
                bins n_tiny   = {[1:8]};
                bins n_small  = {[9:32]};
                bins n_medium = {[33:80]};
                bins n_large  = {[81:120]};
            }
        endgroup

        // ---- Padding scenario: some columns are padding ----
        covergroup cg_padding;
            // padding exists when conv_channel_start + ARRAY_COLS > out_channels
            cp_pad: coverpoint (int'(curr.conv_channel_start)
                                + PKG_ARRAY_COLS > int'(curr.out_channels)) {
                bins no_pad  = {0};
                bins has_pad = {1};
            }
        endgroup

        // ---- ReLU clipping: biased value crosses zero ----
        covergroup cg_relu_clip;
            cp_clip: coverpoint (curr.enable_relu
                                 && ($signed(curr.conv_data[0][0])
                                     + $signed(curr.bias_values[0])) < 0) {
                bins no_clip = {0};
                bins clipped = {1};
            }
        endgroup

        // ---- Cross: relu x padding ----
        covergroup cg_cross;
            cp_relu: coverpoint curr.enable_relu { bins off={0}; bins on={1}; }
            cp_pad:  coverpoint (int'(curr.conv_channel_start)
                                 + PKG_ARRAY_COLS > int'(curr.out_channels)) {
                bins no={0}; bins yes={1};
            }
            cross cp_relu, cp_pad;
        endgroup

        // ---- Window index distribution ----
        covergroup cg_window;
            cp_win: coverpoint curr.conv_window_idx_start {
                bins win_0    = {0};
                bins win_low  = {[1:127]};
                bins win_mid  = {[128:511]};
                bins win_high = {[512:1023]};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_relu         = new();
            cg_channel_start = new();
            cg_out_channels = new();
            cg_padding      = new();
            cg_relu_clip    = new();
            cg_cross        = new();
            cg_window       = new();
        endfunction

        function void write(br_seq_item t);
            curr = t;
            cg_relu.sample();
            cg_channel_start.sample();
            cg_out_channels.sample();
            cg_padding.sample();
            cg_relu_clip.sample();
            cg_cross.sample();
            cg_window.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("BR_COV", "---- Coverage Summary ----", UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  ReLU on/off     : %.1f%%",
                cg_relu.get_coverage()),          UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  Channel start   : %.1f%%",
                cg_channel_start.get_coverage()), UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  Out channels    : %.1f%%",
                cg_out_channels.get_coverage()),  UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  Padding cols    : %.1f%%",
                cg_padding.get_coverage()),       UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  ReLU clipping   : %.1f%%",
                cg_relu_clip.get_coverage()),     UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  ReLU x Padding  : %.1f%%",
                cg_cross.get_coverage()),         UVM_NONE)
            `uvm_info("BR_COV", $sformatf("  Window idx      : %.1f%%",
                cg_window.get_coverage()),        UVM_NONE)
            `uvm_info("BR_COV", "--------------------------", UVM_NONE)
        endfunction

    endclass 


    // =========================================================================
    // 7. AGENT
    // =========================================================================
    class br_agent extends uvm_agent;
        `uvm_component_utils(br_agent)

        uvm_sequencer #(br_seq_item) sequencer;
        br_driver                    driver;
        br_monitor                   monitor;

        uvm_analysis_port #(br_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor = br_monitor::type_id::create("monitor", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sequencer = uvm_sequencer #(br_seq_item)
                            ::type_id::create("sequencer", this);
                driver    = br_driver::type_id::create("driver", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            ap = monitor.ap;
            if (get_is_active() == UVM_ACTIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction

    endclass 


    // =========================================================================
    // 8. ENV
    // =========================================================================
    class br_env extends uvm_env;
        `uvm_component_utils(br_env)

        br_agent      agent;
        br_scoreboard scoreboard;
        br_coverage   coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent      = br_agent     ::type_id::create("agent",      this);
            scoreboard = br_scoreboard::type_id::create("scoreboard", this);
            coverage   = br_coverage  ::type_id::create("coverage",   this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.ap.connect(scoreboard.analysis_export);
            agent.ap.connect(coverage.analysis_export);
        endfunction

    endclass 


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


    // =========================================================================
    // 11. BASE TEST
    // =========================================================================
    class br_base_test extends uvm_test;
        `uvm_component_utils(br_base_test)

        br_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = br_env::type_id::create("env", this);
        endfunction

        function uvm_sequencer #(br_seq_item) get_sequencer();
            return env.agent.sequencer;
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction

    endclass 


    // =========================================================================
    // 12. TESTS
    // =========================================================================
    class br_smoke_test extends br_base_test;
        `uvm_component_utils(br_smoke_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_smoke_seq seq = br_smoke_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class br_relu_test extends br_base_test;
        `uvm_component_utils(br_relu_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_relu_seq seq = br_relu_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class br_padding_test extends br_base_test;
        `uvm_component_utils(br_padding_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_padding_seq seq = br_padding_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class br_window_test extends br_base_test;
        `uvm_component_utils(br_window_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_window_seq seq = br_window_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class br_back2back_test extends br_base_test;
        `uvm_component_utils(br_back2back_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_back2back_seq seq = br_back2back_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class br_rand_test extends br_base_test;
        `uvm_component_utils(br_rand_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_rand_seq seq = br_rand_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.num_items = 30;
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class br_regression_test extends br_base_test;
        `uvm_component_utils(br_regression_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            br_regression_seq seq = br_regression_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    // Full test: all directed suites then heavy random
    class br_full_test extends br_base_test;
        `uvm_component_utils(br_full_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction

        task run_phase(uvm_phase phase);
            br_smoke_seq     smoke = br_smoke_seq    ::type_id::create("smoke");
            br_relu_seq      relu  = br_relu_seq     ::type_id::create("relu");
            br_padding_seq   pad   = br_padding_seq  ::type_id::create("pad");
            br_window_seq    win   = br_window_seq   ::type_id::create("win");
            br_back2back_seq b2b   = br_back2back_seq::type_id::create("b2b");
            br_rand_seq      rnd   = br_rand_seq     ::type_id::create("rnd");

            phase.raise_objection(this);

            `uvm_info("BR_FULL", "=== PHASE 1: Smoke ===", UVM_NONE)
            smoke.start(get_sequencer());

            `uvm_info("BR_FULL", "=== PHASE 2: ReLU Boundary ===", UVM_NONE)
            relu.start(get_sequencer());

            `uvm_info("BR_FULL", "=== PHASE 3: Padding Columns ===", UVM_NONE)
            pad.start(get_sequencer());

            `uvm_info("BR_FULL", "=== PHASE 4: Window Idx Passthrough ===", UVM_NONE)
            win.start(get_sequencer());

            `uvm_info("BR_FULL", "=== PHASE 5: Back-to-Back ===", UVM_NONE)
            b2b.start(get_sequencer());

            `uvm_info("BR_FULL", "=== PHASE 6: Constrained Random (100) ===", UVM_NONE)
            rnd.num_items = 100;
            rnd.start(get_sequencer());

            phase.drop_objection(this);
            `uvm_info("BR_FULL", "=== FULL TEST COMPLETE ===", UVM_NONE)
        endtask

    endclass 

endpackage : br_pkg


// =============================================================================
// INTERFACE
// =============================================================================
interface br_if #(
    parameter int MAX_OUT_CHANNELS = 120,
    parameter int TILE_ROWS        = 4,
    parameter int ARRAY_COLS       = 4,
    parameter int DATA_WIDTH       = 32,
    parameter int BIAS_WIDTH       = 32,
    parameter int MAX_BURST_LEN    = 32
)(input logic clk);

    // Derived widths
    localparam int CH_W  = $clog2(MAX_OUT_CHANNELS);
    localparam int CHN_W = $clog2(MAX_OUT_CHANNELS + 1);
    localparam int BL_W  = $clog2(MAX_BURST_LEN + 1);
    localparam int WIN_W = 10;  // $clog2(1024)

    // ---- DUT inputs ----
    logic                             rst;
    logic                             enable_relu;
    logic [CHN_W-1:0]                out_channels;
    logic                             conv_valid;
    logic signed [DATA_WIDTH-1:0]    conv_data [TILE_ROWS][ARRAY_COLS];
    logic [CH_W-1:0]                 conv_channel_start;
    logic [WIN_W-1:0]                conv_window_idx_start;

    // ---- SRAM response inputs (driven by driver/TB, consumed by DUT) ----
    logic signed [BIAS_WIDTH-1:0]    bias_sram_data;
    logic                             bias_sram_valid;
    logic                             bias_sram_burst_done;

    // ---- DUT outputs ----
    logic [CH_W-1:0]                 bias_sram_addr;
    logic [BL_W-1:0]                 bias_sram_burst_len;
    logic                             bias_sram_read_req;
    logic                             output_valid;
    logic signed [DATA_WIDTH-1:0]    output_data [TILE_ROWS][ARRAY_COLS];
    logic [CH_W-1:0]                 output_channel_start;
    logic [WIN_W-1:0]                output_window_idx_start;

    // ---- Initial values ----
    initial begin
        rst                   = 1'b1;
        enable_relu           = 1'b0;
        out_channels          = '0;
        conv_valid            = 1'b0;
        conv_channel_start    = '0;
        conv_window_idx_start = '0;
        bias_sram_data        = '0;
        bias_sram_valid       = 1'b0;
        bias_sram_burst_done  = 1'b0;
        foreach (conv_data[r,c]) conv_data[r][c] = '0;
    end

    // ---- Clocking blocks ----
    clocking cb_drv @(posedge clk);
        default input #1 output #0;
        // Driven by driver
        output rst;
        output enable_relu, out_channels;
        output conv_valid, conv_channel_start, conv_window_idx_start;
        output conv_data;
        output bias_sram_data, bias_sram_valid, bias_sram_burst_done;
        // Sampled by driver (for protocol handshake)
        input  bias_sram_addr, bias_sram_burst_len, bias_sram_read_req;
        input  output_valid;
        input  output_data, output_channel_start, output_window_idx_start;
    endclocking

    clocking cb_mon @(posedge clk);
        default input #1;
        // Observe all signals
        input rst;
        input enable_relu, out_channels;
        input conv_valid, conv_channel_start, conv_window_idx_start;
        input conv_data;
        input bias_sram_addr, bias_sram_burst_len, bias_sram_read_req;
        input bias_sram_data, bias_sram_valid, bias_sram_burst_done;
        input output_valid;
        input output_data, output_channel_start, output_window_idx_start;
    endclocking

    modport drv_mp (clocking cb_drv, input clk);
    modport mon_mp (clocking cb_mon, input clk);

    // ---- SVA Assertions ----

    // conv_valid must be a single-cycle pulse
    property p_conv_valid_pulse;
        @(posedge clk) disable iff (rst)
        conv_valid |=> !conv_valid;
    endproperty
    ap_conv_valid_pulse: assert property (p_conv_valid_pulse)
        else $error("SVA: conv_valid held more than 1 cycle");

    // bias_sram_read_req must be a single-cycle pulse
    property p_req_pulse;
        @(posedge clk) disable iff (rst)
        bias_sram_read_req |=> !bias_sram_read_req;
    endproperty
    ap_req_pulse: assert property (p_req_pulse)
        else $error("SVA: bias_sram_read_req held more than 1 cycle");

    // output_valid must be a single-cycle pulse
    property p_output_valid_pulse;
        @(posedge clk) disable iff (rst)
        output_valid |=> !output_valid;
    endproperty
    ap_output_valid_pulse: assert property (p_output_valid_pulse)
        else $error("SVA: output_valid held more than 1 cycle");

    // bias_sram_burst_len must be > 0 when read_req is asserted
    property p_nonzero_burst;
        @(posedge clk) disable iff (rst)
        bias_sram_read_req |-> (bias_sram_burst_len > 0);
    endproperty
    ap_nonzero_burst: assert property (p_nonzero_burst)
        else $error("SVA: bias_sram_burst_len==0 on bias_sram_read_req");

    // output_channel_start must equal conv_channel_start when output_valid
    property p_channel_passthrough;
        @(posedge clk) disable iff (rst)
        output_valid |->
            (output_channel_start == $past(conv_channel_start,
                                           /* latency covered by state machine */ 1,
                                           1'b1));
    endproperty
    // Note: the exact past-depth is design-specific; scoreboard validates this precisely.
    // The SVA above is a lightweight sanity check.

endinterface 


// =============================================================================
// DUT (included verbatim so this is a single self-contained file)
// =============================================================================
module bias_add_relu_streaming #(
    parameter MAX_OUT_CHANNELS = 120,
    parameter TILE_ROWS        = 4,
    parameter ARRAY_COLS       = 4,
    parameter DATA_WIDTH       = 32,
    parameter BIAS_WIDTH       = 32,
    parameter MAX_BURST_LEN    = 32
)(
    input  logic clk,
    input  logic rst,
    input  logic enable_relu,

    // Runtime channel count
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,

    // INPUT FROM CONVOLUTION
    input  logic conv_valid,
    input  logic signed [DATA_WIDTH-1:0] conv_data [TILE_ROWS][ARRAY_COLS],
    input  logic [$clog2(MAX_OUT_CHANNELS)-1:0] conv_channel_start,
    input  logic [$clog2(1024)-1:0]             conv_window_idx_start,

    // BURST BIAS SRAM INTERFACE
    output logic [$clog2(MAX_OUT_CHANNELS)-1:0]    bias_sram_addr,
    output logic [$clog2(MAX_BURST_LEN+1)-1:0]    bias_sram_burst_len,
    output logic                                    bias_sram_read_req,
    input  logic signed [BIAS_WIDTH-1:0]           bias_sram_data,
    input  logic                                    bias_sram_valid,
    input  logic                                    bias_sram_burst_done,

    // OUTPUT
    output logic output_valid,
    output logic signed [DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(MAX_OUT_CHANNELS)-1:0] output_channel_start,
    output logic [$clog2(1024)-1:0]             output_window_idx_start
);

    typedef enum logic [2:0] {
        IDLE, REQUEST_BIAS_BURST, RECEIVING_BIAS, APPLYING_BIAS, OUTPUT_DONE
    } state_t;

    state_t state;

    // Buffered conv data
    logic signed [DATA_WIDTH-1:0]       conv_data_buf [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(MAX_OUT_CHANNELS)-1:0] conv_channel_start_buf;
    logic [$clog2(1024)-1:0]            conv_window_idx_start_buf;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels_buf;

    // Bias storage – only ARRAY_COLS values needed at a time
    logic signed [BIAS_WIDTH-1:0] bias_buf [ARRAY_COLS];
    logic [$clog2(ARRAY_COLS+1)-1:0] bias_count;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state                     <= IDLE;
            output_valid              <= 1'b0;
            bias_sram_read_req        <= 1'b0;
            bias_sram_addr            <= '0;
            bias_sram_burst_len       <= '0;
            bias_count                <= '0;
            conv_channel_start_buf    <= '0;
            conv_window_idx_start_buf <= '0;
            out_channels_buf          <= '0;
            output_channel_start      <= '0;
            output_window_idx_start   <= '0;
            for (int r = 0; r < TILE_ROWS; r++)
                for (int c = 0; c < ARRAY_COLS; c++) begin
                    conv_data_buf[r][c] <= '0;
                    output_data[r][c]   <= '0;
                end
            for (int c = 0; c < ARRAY_COLS; c++)
                bias_buf[c] <= '0;
        end else begin
            output_valid       <= 1'b0;
            bias_sram_read_req <= 1'b0;

            case (state)

                IDLE: begin
                    if (conv_valid) begin
                        conv_data_buf             <= conv_data;
                        conv_channel_start_buf    <= conv_channel_start;
                        conv_window_idx_start_buf <= conv_window_idx_start;
                        out_channels_buf          <= out_channels;
                        state                     <= REQUEST_BIAS_BURST;
                    end
                end

                REQUEST_BIAS_BURST: begin
                    automatic logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] remaining;
                    automatic logic [$clog2(ARRAY_COLS+1)-1:0]       num_needed;

                    remaining  = out_channels_buf - conv_channel_start_buf;
                    num_needed = (remaining < ARRAY_COLS) ?
                                 remaining[$clog2(ARRAY_COLS+1)-1:0] :
                                 $clog2(ARRAY_COLS+1)'(ARRAY_COLS);

                    bias_sram_addr      <= conv_channel_start_buf;
                    bias_sram_burst_len <= num_needed;
                    bias_sram_read_req  <= 1'b1;
                    bias_count          <= '0;
                    state               <= RECEIVING_BIAS;
                end

                RECEIVING_BIAS: begin
                    if (bias_sram_valid) begin
                        bias_buf[bias_count] <= bias_sram_data;
                        if (bias_count == bias_sram_burst_len - 1)
                            state <= APPLYING_BIAS;
                        else
                            bias_count <= bias_count + 1;
                    end
                    if (bias_sram_burst_done)
                        state <= APPLYING_BIAS;
                end

                APPLYING_BIAS: begin
                    for (int r = 0; r < TILE_ROWS; r++) begin
                        for (int c = 0; c < ARRAY_COLS; c++) begin
                            automatic logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] ch_idx;
                            automatic logic signed [DATA_WIDTH-1:0]           biased;

                            ch_idx = conv_channel_start_buf + c;

                            if (ch_idx < out_channels_buf) begin
                                biased = conv_data_buf[r][c] + bias_buf[c];
                                if (enable_relu && biased < 0)
                                    output_data[r][c] <= '0;
                                else
                                    output_data[r][c] <= biased;
                            end else begin
                                output_data[r][c] <= conv_data_buf[r][c];
                            end
                        end
                    end
                    output_channel_start    <= conv_channel_start_buf;
                    output_window_idx_start <= conv_window_idx_start_buf;
                    state                   <= OUTPUT_DONE;
                end

                OUTPUT_DONE: begin
                    output_valid <= 1'b1;
                    state        <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule 


// =============================================================================
// TESTBENCH TOP
// =============================================================================
`include "uvm_macros.svh"
import uvm_pkg::*;

module bias_relu_tb_top;
    import uvm_pkg::*;
    import br_pkg::*;

    // ---- Parameters (kept inside module to avoid file-scope order issues) ----
    localparam int TB_MAX_OUT_CHANNELS = 120;
    localparam int TB_TILE_ROWS        = 4;
    localparam int TB_ARRAY_COLS       = 4;
    localparam int TB_DATA_WIDTH       = 32;
    localparam int TB_BIAS_WIDTH       = 32;
    localparam int TB_MAX_BURST_LEN    = 32;

    // ---- Clock generation ----
    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;  // 100 MHz

    // ---- Interface instantiation ----
    br_if #(
        TB_MAX_OUT_CHANNELS,
        TB_TILE_ROWS,
        TB_ARRAY_COLS,
        TB_DATA_WIDTH,
        TB_BIAS_WIDTH,
        TB_MAX_BURST_LEN
    ) dut_if (.clk(clk));

    // ---- DUT instantiation ----
    bias_add_relu_streaming #(
        .MAX_OUT_CHANNELS (TB_MAX_OUT_CHANNELS),
        .TILE_ROWS        (TB_TILE_ROWS),
        .ARRAY_COLS       (TB_ARRAY_COLS),
        .DATA_WIDTH       (TB_DATA_WIDTH),
        .BIAS_WIDTH       (TB_BIAS_WIDTH),
        .MAX_BURST_LEN    (TB_MAX_BURST_LEN)
    ) dut (
        .clk                    (clk),
        .rst                    (dut_if.rst),
        .enable_relu            (dut_if.enable_relu),
        .out_channels           (dut_if.out_channels),
        .conv_valid             (dut_if.conv_valid),
        .conv_data              (dut_if.conv_data),
        .conv_channel_start     (dut_if.conv_channel_start),
        .conv_window_idx_start  (dut_if.conv_window_idx_start),
        .bias_sram_addr         (dut_if.bias_sram_addr),
        .bias_sram_burst_len    (dut_if.bias_sram_burst_len),
        .bias_sram_read_req     (dut_if.bias_sram_read_req),
        .bias_sram_data         (dut_if.bias_sram_data),
        .bias_sram_valid        (dut_if.bias_sram_valid),
        .bias_sram_burst_done   (dut_if.bias_sram_burst_done),
        .output_valid           (dut_if.output_valid),
        .output_data            (dut_if.output_data),
        .output_channel_start   (dut_if.output_channel_start),
        .output_window_idx_start(dut_if.output_window_idx_start)
    );

    // ---- Register virtual interface and kick off UVM ----
    initial begin
        uvm_config_db #(virtual br_if)::set(
            null, "uvm_test_top.*", "vif", dut_if);
        run_test("br_full_test");
    end

    // ---- Hard timeout ----
    initial begin
        #5_000_000;
        `uvm_fatal("BR_TB", "Hard timeout 5ms — simulation hung")
    end

endmodule 