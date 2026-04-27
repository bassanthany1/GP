// =============================================================================
// bias_sram_tb.sv
// Full UVM Verification for bias_sram_lenet5
// Pattern: mirrors wf_sram_tb exactly – everything in one package,
//          plain uvm_analysis_imp only, no tagged imps needed.
//
// Compile:  vlog bias_sram_tb.sv
// Run:      vsim -c bias_sram_tb_top +UVM_TESTNAME=bs_sram_smoke_test -do "run -all"
// =============================================================================


// =============================================================================
// PACKAGE
// =============================================================================
package bs_sram_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // -------------------------------------------------------------------------
    // Parameters  (must match DUT generics)
    // -------------------------------------------------------------------------
    localparam int PKG_DATA_WIDTH    = 32;
    localparam int PKG_MAX_BURST_LEN = 16;
    localparam int PKG_MAX_BIASES    = 120;
    localparam int PKG_TOTAL_BIASES  = 236;
    // BRAM_DEPTH = 2**$clog2(TOTAL_BIASES+1) = 2**8 = 256
    localparam int PKG_BRAM_DEPTH    = 256;
    localparam int PKG_PIPE_LATENCY  = 3;

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


    // =========================================================================
    // 2. REFERENCE MODEL
    // =========================================================================
    class bs_sram_ref_model extends uvm_object;
        `uvm_object_utils(bs_sram_ref_model)

        logic signed [PKG_DATA_WIDTH-1:0] bram [PKG_BRAM_DEPTH];

        function new(string name = "bs_sram_ref_model");
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

    endclass :


    // =========================================================================
    // 3. DRIVER
    // =========================================================================
    class bs_sram_driver extends uvm_driver #(bs_sram_seq_item);
        `uvm_component_utils(bs_sram_driver)

        virtual bs_sram_if #(
            PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
            PKG_MAX_BIASES, PKG_TOTAL_BIASES
        ).drv_mp vif;

        bs_sram_ref_model drv_ref;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv_ref = bs_sram_ref_model::type_id::create("drv_ref");
            if (!uvm_config_db #(virtual bs_sram_if #(
                    PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
                    PKG_MAX_BIASES, PKG_TOTAL_BIASES))
                ::get(this, "", "vif", vif))
                `uvm_fatal("BS_DRV", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            bs_sram_seq_item item;
            apply_reset();
            forever begin
                seq_item_port.get_next_item(item);
                if (item.is_write) drive_write(item);
                else               drive_read(item);
                seq_item_port.item_done();
            end
        endtask

        task apply_reset();
            vif.cb_drv.rst          <= 1'b1;
            vif.cb_drv.write_enable <= 1'b0;
            vif.cb_drv.read_request <= 1'b0;
            vif.cb_drv.layer_offset <= '0;
            vif.cb_drv.write_addr   <= '0;
            vif.cb_drv.write_data   <= '0;
            vif.cb_drv.read_addr    <= '0;
            vif.cb_drv.burst_length <= '0;
            repeat (5) @(vif.cb_drv);
            vif.cb_drv.rst <= 1'b0;
            repeat (3) @(vif.cb_drv);
        endtask

        task drive_write(bs_sram_seq_item item);
            // Cycle 0: drive address/data, keep write_enable low
            vif.cb_drv.layer_offset <= item.layer_offset;
            vif.cb_drv.write_addr   <= item.write_addr;
            vif.cb_drv.write_data   <= item.write_data;
            vif.cb_drv.write_enable <= 1'b0;
            @(vif.cb_drv);

            // Cycle 1: assert write_enable
            vif.cb_drv.write_enable <= 1'b1;
            @(vif.cb_drv);

            // Cycle 2: deassert
            vif.cb_drv.write_enable <= 1'b0;
            @(vif.cb_drv);

            // Update ref model
            drv_ref.write_beat(int'(item.write_addr), item.write_data);

            `uvm_info("BS_DRV", $sformatf("Drove: %s", item.convert2string()), UVM_HIGH)
        endtask

        task drive_read(bs_sram_seq_item item);
            int unsigned abs_addr;
            abs_addr = int'(item.layer_offset) + int'(item.read_addr);

            // Snapshot expected data BEFORE driving (ref model state at req time)
            drv_ref.predict_burst(abs_addr, int'(item.burst_length),
                                  item.expected_beats);

            // Cycle 0: drive address fields, keep read_request low
            vif.cb_drv.layer_offset <= item.layer_offset;
            vif.cb_drv.read_addr    <= item.read_addr;
            vif.cb_drv.burst_length <= item.burst_length;
            vif.cb_drv.read_request <= 1'b0;
            @(vif.cb_drv);

            // Cycle 1: assert read_request (single cycle pulse)
            vif.cb_drv.read_request <= 1'b1;
            @(vif.cb_drv);

            // Cycle 2: deassert, now wait for burst_complete via monitor
            vif.cb_drv.read_request <= 1'b0;

            // Wait for burst_complete — monitor will capture data independently
            do @(vif.cb_drv); while (!vif.cb_drv.burst_complete);

            @(vif.cb_drv); // idle cycle

            `uvm_info("BS_DRV", $sformatf("Drove: %s", item.convert2string()), UVM_MEDIUM)
        endtask

    endclass 


    // =========================================================================
    // 4. MONITOR
    // =========================================================================
    class bs_sram_monitor extends uvm_monitor;
        `uvm_component_utils(bs_sram_monitor)

        virtual bs_sram_if #(
            PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
            PKG_MAX_BIASES, PKG_TOTAL_BIASES
        ).mon_mp vif;

        uvm_analysis_port #(bs_sram_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual bs_sram_if #(
                    PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
                    PKG_MAX_BIASES, PKG_TOTAL_BIASES))
                ::get(this, "", "vif", vif))
                `uvm_fatal("BS_MON", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                bs_sram_seq_item item;
                @(vif.cb_mon);

                if (vif.cb_mon.rst) continue;

                // ---- Observe write ----
                if (vif.cb_mon.write_enable) begin
                    if ($isunknown(vif.cb_mon.write_addr)) continue;
                    item              = bs_sram_seq_item::type_id::create("mon_wr");
                    item.is_write     = 1;
                    item.write_addr   = vif.cb_mon.write_addr;
                    item.write_data   = vif.cb_mon.write_data;
                    item.layer_offset = vif.cb_mon.layer_offset;
                    ap.write(item);
                    `uvm_info("BS_MON", $sformatf("Observed: %s", item.convert2string()), UVM_HIGH)
                end

                // ---- Observe read request ----
                else if (vif.cb_mon.read_request) begin
                    if ($isunknown(vif.cb_mon.burst_length)) continue;

                    item              = bs_sram_seq_item::type_id::create("mon_rd");
                    item.is_write     = 0;
                    item.read_addr    = vif.cb_mon.read_addr;
                    item.layer_offset = vif.cb_mon.layer_offset;
                    item.burst_length = vif.cb_mon.burst_length;

                    // Collect beats until burst_complete
                    collect_burst(item);

                    ap.write(item);
                    `uvm_info("BS_MON", $sformatf("Observed: %s beats=%0d",
                        item.convert2string(), item.read_beats.size()), UVM_MEDIUM)
                end
            end
        endtask

        task collect_burst(bs_sram_seq_item item);
            int unsigned watchdog  = 0;
            int unsigned max_cycles = PKG_PIPE_LATENCY + PKG_MAX_BURST_LEN + 8;
            item.burst_complete_seen = 0;

            forever begin
                @(vif.cb_mon);
                watchdog++;

                if (vif.cb_mon.rst) return;

                if (vif.cb_mon.read_valid)
                    item.read_beats.push_back(vif.cb_mon.read_data);

                if (vif.cb_mon.burst_complete) begin
                    item.burst_complete_seen = 1;
                    return;
                end

                if (watchdog > max_cycles) begin
                    `uvm_error("BS_MON", $sformatf(
                        "Watchdog: %0d beats, no burst_complete after %0d cycles",
                        item.read_beats.size(), watchdog))
                    return;
                end
            end
        endtask

    endclass 


    // =========================================================================
    // 5. SCOREBOARD
    // =========================================================================
    class bs_sram_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(bs_sram_scoreboard)

        uvm_analysis_imp #(bs_sram_seq_item, bs_sram_scoreboard) analysis_export;

        bs_sram_ref_model ref_model;

        int unsigned checks_passed  = 0;
        int unsigned checks_failed  = 0;
        int unsigned bursts_checked = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            analysis_export = new("analysis_export", this);
            ref_model = bs_sram_ref_model::type_id::create("ref_model");
        endfunction

        function void write(bs_sram_seq_item item);
            if (item.is_write) begin
                ref_model.write_beat(int'(item.write_addr), item.write_data);
                `uvm_info("BS_SB", $sformatf("REF update: %s", item.convert2string()), UVM_HIGH)
            end else begin
                check_burst(item);
            end
        endfunction

        function void check_burst(bs_sram_seq_item item);
            int unsigned exp_len       = int'(item.burst_length);
            int unsigned got_len       = item.read_beats.size();
            int unsigned exp_beats_len = item.expected_beats.size();

            bursts_checked++;

            // 1. Beat count
            if (got_len !== exp_len) begin
                `uvm_error("BS_SB", $sformatf(
                    "Beat count mismatch: exp=%0d got=%0d | %s",
                    exp_len, got_len, item.convert2string()))
                checks_failed++;
            end else checks_passed++;

            // 2. Data values (compare against driver's snapshot)
            begin
                int unsigned check_len = (got_len < exp_beats_len) ? got_len : exp_beats_len;
                for (int i = 0; i < int'(check_len); i++) begin
                    if (item.read_beats[i] !== item.expected_beats[i]) begin
                        `uvm_error("BS_SB", $sformatf(
                            "Data mismatch beat[%0d]: got=%0d exp=%0d | %s",
                            i, $signed(item.read_beats[i]),
                            $signed(item.expected_beats[i]),
                            item.convert2string()))
                        checks_failed++;
                    end else checks_passed++;
                end
            end

            // 3. burst_complete
            if (!item.burst_complete_seen) begin
                `uvm_error("BS_SB", $sformatf(
                    "burst_complete never seen for len=%0d", exp_len))
                checks_failed++;
            end else checks_passed++;

            `uvm_info("BS_SB", $sformatf(
                "Burst %0d done - passed=%0d failed=%0d",
                bursts_checked, checks_passed, checks_failed), UVM_LOW)
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("BS_SB", "=============================================", UVM_NONE)
            `uvm_info("BS_SB", $sformatf("  BURSTS  : %0d", bursts_checked), UVM_NONE)
            `uvm_info("BS_SB", $sformatf("  PASSED  : %0d", checks_passed),  UVM_NONE)
            `uvm_info("BS_SB", $sformatf("  FAILED  : %0d", checks_failed),  UVM_NONE)
            `uvm_info("BS_SB", "=============================================", UVM_NONE)
            if (checks_failed > 0)
                `uvm_error("BS_SB", "*** TEST FAILED ***")
            else
                `uvm_info("BS_SB", "*** TEST PASSED ***", UVM_NONE)
        endfunction

    endclass


    // =========================================================================
    // 6. COVERAGE
    // =========================================================================
    class bs_sram_coverage extends uvm_subscriber #(bs_sram_seq_item);
        `uvm_component_utils(bs_sram_coverage)

        bs_sram_seq_item curr;

        covergroup cg_burst_length;
            cp_len: coverpoint curr.burst_length {
                bins len_1       = {1};
                bins len_small   = {[2:7]};
                bins len_medium  = {[8:12]};
                bins len_large   = {[13:15]};
                bins len_max     = {16};
            }
        endgroup

        covergroup cg_layer_offset;
            cp_offset: coverpoint curr.layer_offset {
                bins offset_zero  = {0};
                bins offset_small = {[1:59]};
                bins offset_mid   = {[60:118]};
                bins offset_large = {[119:236]};
            }
        endgroup

        covergroup cg_burst_complete;
            cp_done: coverpoint curr.burst_complete_seen {
                bins seen = {1};
            }
        endgroup

        covergroup cg_addr_cross;
            cp_off: coverpoint curr.layer_offset {
                bins off_0    = {0};
                bins off_mid  = {[1:118]};
                bins off_high = {[119:236]};
            }
            cp_len: coverpoint curr.burst_length {
                bins len_short = {[1:4]};
                bins len_med   = {[5:12]};
                bins len_long  = {[13:16]};
            }
            cross cp_off, cp_len;
        endgroup

        // LeNet-5 specific: cover the 6 bias layers
        // C1=6, S2=6, C3=16, S4=16, C5=120, F6=84
        // stored as offsets: 0,6,12,28,44,164 (cumulative)
        covergroup cg_lenet_layers;
            cp_layer: coverpoint curr.layer_offset {
                bins c1_offset  = {0};
                bins s2_offset  = {6};
                bins c3_offset  = {12};
                bins s4_offset  = {28};
                bins c5_offset  = {44};
                bins f6_offset  = {164};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_burst_length  = new();
            cg_layer_offset  = new();
            cg_burst_complete = new();
            cg_addr_cross    = new();
            cg_lenet_layers  = new();
        endfunction

        function void write(bs_sram_seq_item t);
            curr = t;
            cg_burst_length.sample();
            cg_layer_offset.sample();
            cg_burst_complete.sample();
            cg_addr_cross.sample();
            cg_lenet_layers.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("BS_COV", "---- Coverage Summary ----", UVM_NONE)
            `uvm_info("BS_COV", $sformatf("  Burst length  : %.1f%%",
                cg_burst_length.get_coverage()),   UVM_NONE)
            `uvm_info("BS_COV", $sformatf("  Layer offset  : %.1f%%",
                cg_layer_offset.get_coverage()),   UVM_NONE)
            `uvm_info("BS_COV", $sformatf("  Burst done    : %.1f%%",
                cg_burst_complete.get_coverage()), UVM_NONE)
            `uvm_info("BS_COV", $sformatf("  Addr cross    : %.1f%%",
                cg_addr_cross.get_coverage()),     UVM_NONE)
            `uvm_info("BS_COV", $sformatf("  LeNet layers  : %.1f%%",
                cg_lenet_layers.get_coverage()),   UVM_NONE)
            `uvm_info("BS_COV", "--------------------------", UVM_NONE)
        endfunction

    endclass 

    // =========================================================================
    // 7. AGENT
    // =========================================================================
    class bs_sram_agent extends uvm_agent;
        `uvm_component_utils(bs_sram_agent)

        uvm_sequencer #(bs_sram_seq_item) sequencer;
        bs_sram_driver                    driver;
        bs_sram_monitor                   monitor;

        uvm_analysis_port #(bs_sram_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor = bs_sram_monitor::type_id::create("monitor", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sequencer = uvm_sequencer #(bs_sram_seq_item)
                            ::type_id::create("sequencer", this);
                driver    = bs_sram_driver::type_id::create("driver", this);
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
    class bs_sram_env extends uvm_env;
        `uvm_component_utils(bs_sram_env)

        bs_sram_agent      agent;
        bs_sram_scoreboard scoreboard;
        bs_sram_coverage   coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent      = bs_sram_agent     ::type_id::create("agent",      this);
            scoreboard = bs_sram_scoreboard::type_id::create("scoreboard", this);
            coverage   = bs_sram_coverage  ::type_id::create("coverage",   this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.ap.connect(scoreboard.analysis_export);
            agent.ap.connect(coverage.analysis_export);
        endfunction

    endclass 


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


    // =========================================================================
    // 11. BASE TEST
    // =========================================================================
    class bs_sram_base_test extends uvm_test;
        `uvm_component_utils(bs_sram_base_test)

        bs_sram_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = bs_sram_env::type_id::create("env", this);
        endfunction

        function uvm_sequencer #(bs_sram_seq_item) get_sequencer();
            return env.agent.sequencer;
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction

    endclass 


    // =========================================================================
    // 12. TESTS
    // =========================================================================

    class bs_sram_smoke_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_smoke_seq seq = bs_sram_smoke_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_offset_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_offset_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_offset_seq seq = bs_sram_offset_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_burst_len_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_burst_len_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_burst_len_seq seq = bs_sram_burst_len_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_wr_rd_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_wr_rd_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_wr_rd_seq seq = bs_sram_wr_rd_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_b2b_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_b2b_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_b2b_read_seq seq = bs_sram_b2b_read_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_signed_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_signed_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_signed_seq seq = bs_sram_signed_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_rand_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_rand_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_rand_seq seq = bs_sram_rand_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.num_pairs = 20;
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_lenet_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_lenet_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_lenet_seq seq = bs_sram_lenet_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    class bs_sram_regression_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_regression_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            bs_sram_regression_seq seq = bs_sram_regression_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass 

    // --------------------------------------------------------------------------
    // Full test: all directed phases + random
    // --------------------------------------------------------------------------
    class bs_sram_full_test extends bs_sram_base_test;
        `uvm_component_utils(bs_sram_full_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        task run_phase(uvm_phase phase);
            bs_sram_smoke_seq     smoke = bs_sram_smoke_seq    ::type_id::create("smoke");
            bs_sram_offset_seq    off   = bs_sram_offset_seq   ::type_id::create("off");
            bs_sram_burst_len_seq blen  = bs_sram_burst_len_seq::type_id::create("blen");
            bs_sram_wr_rd_seq     wrrd  = bs_sram_wr_rd_seq    ::type_id::create("wrrd");
            bs_sram_b2b_read_seq  b2b   = bs_sram_b2b_read_seq ::type_id::create("b2b");
            bs_sram_signed_seq    sgn   = bs_sram_signed_seq   ::type_id::create("sgn");
            bs_sram_lenet_seq     lenet = bs_sram_lenet_seq    ::type_id::create("lenet");
            bs_sram_rand_seq      rnd   = bs_sram_rand_seq     ::type_id::create("rnd");

            phase.raise_objection(this);

            `uvm_info("BS_FULL", "=== PHASE 1: Smoke ===", UVM_NONE)
            smoke.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 2: Layer Offset (LeNet-5 layers) ===", UVM_NONE)
            off.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 3: Burst Length Stress ===", UVM_NONE)
            blen.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 4: Write-Read Interleaved ===", UVM_NONE)
            wrrd.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 5: Back-to-Back Reads ===", UVM_NONE)
            b2b.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 6: Signed Corner Cases ===", UVM_NONE)
            sgn.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 7: LeNet-5 Integration ===", UVM_NONE)
            lenet.start(get_sequencer());

            `uvm_info("BS_FULL", "=== PHASE 8: Random (100 pairs) ===", UVM_NONE)
            rnd.num_pairs = 100;
            rnd.start(get_sequencer());

            // Drain pipeline
            repeat (PKG_PIPE_LATENCY + 8) @(posedge env.agent.monitor.vif.cb_mon);

            phase.drop_objection(this);

            `uvm_info("BS_FULL", "=== FULL TEST COMPLETE ===", UVM_NONE)
        endtask

    endclass 

endpackage 


// =============================================================================
// INTERFACE
// =============================================================================
interface bs_sram_if #(
    parameter int DATA_WIDTH    = 32,
    parameter int MAX_BURST_LEN = 16,
    parameter int MAX_BIASES    = 120,
    parameter int TOTAL_BIASES  = 236
)(input logic clk);

    logic                                         rst;
    logic [$clog2(TOTAL_BIASES+1)-1:0]            layer_offset;
    logic [$clog2(TOTAL_BIASES)-1:0]              write_addr;
    logic signed [DATA_WIDTH-1:0]                 write_data;
    logic                                         write_enable;
    logic [$clog2(MAX_BIASES)-1:0]                read_addr;
    logic [$clog2(MAX_BURST_LEN+1)-1:0]           burst_length;
    logic                                         read_request;
    logic signed [DATA_WIDTH-1:0]                 read_data;
    logic                                         read_valid;
    logic                                         burst_complete;

    initial begin
        rst          = 1'b1;
        layer_offset = '0;
        write_addr   = '0;
        write_data   = '0;
        write_enable = 1'b0;
        read_addr    = '0;
        burst_length = '0;
        read_request = 1'b0;
    end

    clocking cb_drv @(posedge clk);
        default input #1 output #0;
        output rst;
        output layer_offset;
        output write_addr, write_data, write_enable;
        output read_addr, burst_length, read_request;
        input  read_data, read_valid, burst_complete;
    endclocking

    clocking cb_mon @(posedge clk);
        default input #1;
        input rst;
        input layer_offset;
        input write_addr, write_data, write_enable;
        input read_addr, burst_length, read_request;
        input read_data, read_valid, burst_complete;
    endclocking

    modport drv_mp (clocking cb_drv, input clk);
    modport mon_mp (clocking cb_mon, input clk);

    // ------------------------------------------------------------------
    // SVA assertions
    // ------------------------------------------------------------------
    property p_req_single_cycle;
        @(posedge clk) read_request |=> !read_request;
    endproperty
    ap_req_single: assert property (p_req_single_cycle)
        else $error("SVA: read_request held >1 cycle");

    property p_complete_single_cycle;
        @(posedge clk) burst_complete |=> !burst_complete;
    endproperty
    ap_complete_single: assert property (p_complete_single_cycle)
        else $error("SVA: burst_complete held >1 cycle");

    property p_no_collision;
        @(posedge clk) !(write_enable && read_request);
    endproperty
    ap_no_collision: assert property (p_no_collision)
        else $error("SVA: write_enable and read_request both asserted");

    property p_nonzero_burst;
        @(posedge clk) read_request |-> (burst_length > 0);
    endproperty
    ap_nonzero: assert property (p_nonzero_burst)
        else $error("SVA: burst_length==0 on read_request");

    property p_burst_len_in_range;
        @(posedge clk) read_request |-> (burst_length <= MAX_BURST_LEN);
    endproperty
    ap_burst_range: assert property (p_burst_len_in_range)
        else $error("SVA: burst_length exceeds MAX_BURST_LEN");

endinterface 


// =============================================================================
// DUT  (verbatim copy of bias_sram_lenet5 from the spec)
// =============================================================================
module bias_sram_lenet5_dut #(
    parameter DATA_WIDTH    = 32,
    parameter MAX_BURST_LEN = 16,
    parameter MAX_BIASES    = 120,
    parameter TOTAL_BIASES  = 236
)(
    input  logic clk,
    input  logic rst,
    input  logic [$clog2(TOTAL_BIASES+1)-1:0] layer_offset,
    input  logic [$clog2(TOTAL_BIASES)-1:0]   write_addr,
    input  logic signed [DATA_WIDTH-1:0]      write_data,
    input  logic                              write_enable,
    input  logic [$clog2(MAX_BIASES)-1:0]     read_addr,
    input  logic [$clog2(MAX_BURST_LEN+1)-1:0] burst_length,
    input  logic                              read_request,
    output logic signed [DATA_WIDTH-1:0]      read_data,
    output logic                              read_valid,
    output logic                              burst_complete
);

    localparam BRAM_DEPTH = 2 ** $clog2(TOTAL_BIASES + 1);
    localparam ADDR_WIDTH = $clog2(BRAM_DEPTH);

    (* ram_style = "block" *)
    logic signed [DATA_WIDTH-1:0] bias_bram [BRAM_DEPTH];

    logic [ADDR_WIDTH-1:0] bram_addr;
    logic [ADDR_WIDTH-1:0] absolute_read_addr;
    logic [ADDR_WIDTH-1:0] current_read_addr;
    logic [$clog2(MAX_BURST_LEN+1)-1:0] burst_counter;
    logic [$clog2(MAX_BURST_LEN+1)-1:0] burst_target;
    logic burst_active;
    logic [1:0] valid_pipe;
    logic burst_complete_reg;

    typedef enum logic [1:0] {
        S_IDLE  = 2'd0,
        S_LATCH = 2'd1,
        S_BURST = 2'd2
    } state_t;
    state_t state;

    always_comb begin
        absolute_read_addr = layer_offset + read_addr;
    end

    always_comb begin
        if (write_enable) bram_addr = write_addr;
        else              bram_addr = current_read_addr;
    end

    always_ff @(posedge clk) begin
        if (write_enable) bias_bram[bram_addr] <= write_data;
        read_data <= bias_bram[bram_addr];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state              <= S_IDLE;
            burst_active       <= 1'b0;
            burst_counter      <= '0;
            burst_target       <= '0;
            current_read_addr  <= '0;
            valid_pipe         <= 2'b00;
            burst_complete_reg <= 1'b0;
        end else begin
            valid_pipe         <= {valid_pipe[0], 1'b0};
            burst_complete_reg <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (read_request && !write_enable) begin
                        current_read_addr <= absolute_read_addr;
                        burst_target      <= burst_length;
                        burst_counter     <= 1;
                        burst_active      <= 1'b1;
                        state             <= S_LATCH;
                    end
                end
                S_LATCH: begin
                    valid_pipe[0] <= 1'b1;
                    state         <= S_BURST;
                end
                S_BURST: begin
                    if (burst_counter < burst_target) begin
                        current_read_addr <= current_read_addr + 1;
                        burst_counter     <= burst_counter + 1;
                        valid_pipe[0]     <= 1'b1;
                    end else begin
                        valid_pipe[0]      <= 1'b0;
                        burst_active       <= 1'b0;
                        burst_complete_reg <= 1'b1;
                        burst_counter      <= '0;
                        state              <= S_IDLE;
                    end
                end
            endcase

            if (write_enable) begin
                state         <= S_IDLE;
                burst_active  <= 1'b0;
                valid_pipe    <= 2'b00;
                burst_counter <= '0;
            end
        end
    end

    assign read_valid     = valid_pipe[1];
    assign burst_complete = burst_complete_reg;

endmodule 


// =============================================================================
// TESTBENCH TOP
// =============================================================================
`include "uvm_macros.svh"
import uvm_pkg::*;

localparam int PKG_DATA_WIDTH    = 32;
localparam int PKG_MAX_BURST_LEN = 16;
localparam int PKG_MAX_BIASES    = 120;
localparam int PKG_TOTAL_BIASES  = 236;
localparam int PKG_PIPE_LATENCY  = 3;

module bs_sram_tb_top;
    import uvm_pkg::*;
    import bs_sram_pkg::*;

    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    bs_sram_if #(
        PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
        PKG_MAX_BIASES, PKG_TOTAL_BIASES
    ) dut_if (.clk(clk));

    bias_sram_lenet5_dut #(
        .DATA_WIDTH    (PKG_DATA_WIDTH),
        .MAX_BURST_LEN (PKG_MAX_BURST_LEN),
        .MAX_BIASES    (PKG_MAX_BIASES),
        .TOTAL_BIASES  (PKG_TOTAL_BIASES)
    ) dut (
        .clk            (clk),
        .rst            (dut_if.rst),
        .layer_offset   (dut_if.layer_offset),
        .write_addr     (dut_if.write_addr),
        .write_data     (dut_if.write_data),
        .write_enable   (dut_if.write_enable),
        .read_addr      (dut_if.read_addr),
        .burst_length   (dut_if.burst_length),
        .read_request   (dut_if.read_request),
        .read_data      (dut_if.read_data),
        .read_valid     (dut_if.read_valid),
        .burst_complete (dut_if.burst_complete)
    );

    initial begin
        uvm_config_db #(virtual bs_sram_if #(
            PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
            PKG_MAX_BIASES, PKG_TOTAL_BIASES))
        ::set(null, "uvm_test_top.*", "vif", dut_if);
        run_test("bs_sram_full_test");
    end

    initial begin
        #5_000_000;
        `uvm_fatal("BS_TB", "Hard timeout 5ms")
    end

endmodule 