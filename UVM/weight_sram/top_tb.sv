// =============================================================================
// top_tb.sv
// Full UVM Verification for weight_sram_lenet5_actual
// Pattern: same as systolic_pkg - everything in one package,
//          plain uvm_analysis_imp only, no tagged imps needed.
//
// Compile:  vlog top_tb.sv
// Run:      vsim -c wf_sram_tb_top +UVM_TESTNAME=wf_sram_smoke_test -do "run -all"
// =============================================================================



// =============================================================================
// PACKAGE
// =============================================================================
package wf_sram_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int PKG_DATA_WIDTH    = 8;
    localparam int PKG_MAX_BURST_LEN = 512;
    localparam int PKG_MAX_WEIGHTS   = 30720;
    localparam int PKG_TOTAL_WEIGHTS = 44190;
    localparam int PKG_BRAM_DEPTH    = 65536;
    localparam int PKG_PIPE_LATENCY  = 3;

    // =========================================================================
    // 1. SEQUENCE ITEM
    // =========================================================================
    // One item covers BOTH write and read transactions.
    // is_write=1 -> write beat
    // is_write=0 -> burst read request
    // This is the same "one item type" approach used in systolic.
    // =========================================================================
    class wf_sram_seq_item extends uvm_sequence_item;
        `uvm_object_utils(wf_sram_seq_item)

        // Transaction type
        bit is_write;

        // Write fields
        rand logic [$clog2(PKG_TOTAL_WEIGHTS)-1:0]   write_addr;
        rand logic signed [PKG_DATA_WIDTH-1:0]       write_data;

        // Read fields
        rand logic [$clog2(PKG_MAX_WEIGHTS)-1:0]     read_addr;
        rand logic [$clog2(PKG_MAX_BURST_LEN+1)-1:0] burst_length;

        // Common
        rand logic [$clog2(PKG_TOTAL_WEIGHTS+1)-1:0] layer_offset;

        // Response (filled by monitor)
        logic signed [PKG_DATA_WIDTH-1:0] read_beats[$];
        bit                               burst_complete_seen;

        // Expected (filled by driver from ref model)
        logic signed [PKG_DATA_WIDTH-1:0] expected_beats[$];

        constraint c_write_addr   { write_addr   < PKG_TOTAL_WEIGHTS; }
        constraint c_read_addr    { read_addr    < PKG_MAX_WEIGHTS; }
        constraint c_burst_length { burst_length inside {[1:PKG_MAX_BURST_LEN]}; }
        constraint c_no_overflow  {
            !is_write ->
            (layer_offset + read_addr + burst_length) <= PKG_TOTAL_WEIGHTS;
        }

        // function new(string name = "wf_sram_seq_item");
        //     super.new(name);
        // endfunction

        function string convert2string();
            if (is_write)
                return $sformatf("WR addr=0x%05x data=%0d offset=%0d",
                    write_addr, $signed(write_data), layer_offset);
            else
                return $sformatf("RD addr=0x%04x offset=%0d len=%0d",
                    read_addr, layer_offset, burst_length);
        endfunction

    endclass 


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


    // =========================================================================
    // 3. DRIVER
    // =========================================================================
    class wf_sram_driver extends uvm_driver #(wf_sram_seq_item);
        `uvm_component_utils(wf_sram_driver)

        virtual wf_sram_if #(
            PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
            PKG_MAX_WEIGHTS, PKG_TOTAL_WEIGHTS
        ).drv_mp vif;

        // Driver keeps its own ref model to snapshot expected data at req time
        wf_sram_ref_model drv_ref;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv_ref = wf_sram_ref_model::type_id::create("drv_ref");
            if (!uvm_config_db #(virtual wf_sram_if #(
                    PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
                    PKG_MAX_WEIGHTS, PKG_TOTAL_WEIGHTS))
                ::get(this, "", "vif", vif))
                `uvm_fatal("WF_DRV", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            wf_sram_seq_item item;
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

        task drive_write(wf_sram_seq_item item);
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

            `uvm_info("WF_DRV", $sformatf("Drove: %s", item.convert2string()), UVM_HIGH)
        endtask

        task drive_read(wf_sram_seq_item item);
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

            // Cycle 2: deassert, now wait for valid_out via monitor
            vif.cb_drv.read_request <= 1'b0;

            // Wait for burst_complete — monitor will capture data independently
            do @(vif.cb_drv); while (!vif.cb_drv.burst_complete);

            @(vif.cb_drv); // idle cycle

            `uvm_info("WF_DRV", $sformatf("Drove: %s", item.convert2string()), UVM_MEDIUM)
        endtask

    endclass 


    // =========================================================================
    // 4. MONITOR
    // =========================================================================
    // Watches the interface. On each read_request, collects all read_valid
    // beats until burst_complete. Fills item.read_beats and publishes via ap.
    // For writes, just observes and re-broadcasts for scoreboard ref update.
    // =========================================================================
    class wf_sram_monitor extends uvm_monitor;
        `uvm_component_utils(wf_sram_monitor)

        virtual wf_sram_if #(
            PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
            PKG_MAX_WEIGHTS, PKG_TOTAL_WEIGHTS
        ).mon_mp vif;

        uvm_analysis_port #(wf_sram_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual wf_sram_if #(
                    PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
                    PKG_MAX_WEIGHTS, PKG_TOTAL_WEIGHTS))
                ::get(this, "", "vif", vif))
                `uvm_fatal("WF_MON", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                wf_sram_seq_item item;
                @(vif.cb_mon);

                if (vif.cb_mon.rst) continue;

                // ---- Observe write ----
                if (vif.cb_mon.write_enable) begin
                    if ($isunknown(vif.cb_mon.write_addr)) continue;
                    item            = wf_sram_seq_item::type_id::create("mon_wr");
                    item.is_write   = 1;
                    item.write_addr = vif.cb_mon.write_addr;
                    item.write_data = vif.cb_mon.write_data;
                    item.layer_offset = vif.cb_mon.layer_offset;
                    ap.write(item);
                    `uvm_info("WF_MON", $sformatf("Observed: %s", item.convert2string()), UVM_HIGH)
                end

                // ---- Observe read request ----
                else if (vif.cb_mon.read_request) begin
                    if ($isunknown(vif.cb_mon.burst_length)) continue;

                    item              = wf_sram_seq_item::type_id::create("mon_rd");
                    item.is_write     = 0;
                    item.read_addr    = vif.cb_mon.read_addr;
                    item.layer_offset = vif.cb_mon.layer_offset;
                    item.burst_length = vif.cb_mon.burst_length;

                    // Collect beats until burst_complete
                    collect_burst(item);

                    ap.write(item);
                    `uvm_info("WF_MON", $sformatf("Observed: %s beats=%0d",
                        item.convert2string(), item.read_beats.size()), UVM_MEDIUM)
                end
            end
        endtask

        task collect_burst(wf_sram_seq_item item);
            int unsigned watchdog = 0;
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
                    `uvm_error("WF_MON", $sformatf(
                        "Watchdog: %0d beats, no burst_complete after %0d cycles",
                        item.read_beats.size(), watchdog))
                    return;
                end
            end
        endtask

    endclass 

    // =========================================================================
    // 7. AGENT
    // =========================================================================
    class wf_sram_agent extends uvm_agent;
        `uvm_component_utils(wf_sram_agent)

        uvm_sequencer #(wf_sram_seq_item) sequencer;
        wf_sram_driver                    driver;
        wf_sram_monitor                   monitor;

        uvm_analysis_port #(wf_sram_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor = wf_sram_monitor::type_id::create("monitor", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sequencer = uvm_sequencer #(wf_sram_seq_item)
                            ::type_id::create("sequencer", this);
                driver    = wf_sram_driver::type_id::create("driver", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            ap = monitor.ap;
            if (get_is_active() == UVM_ACTIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction

    endclass 

    // =========================================================================
    // 5. SCOREBOARD
    // =========================================================================
    // Receives ALL transactions from monitor via single plain analysis_imp.
    // Writes  -> update internal ref model
    // Reads   -> compare observed beats vs expected (from item.expected_beats
    //            which the driver filled before driving)
    // =========================================================================
    class wf_sram_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(wf_sram_scoreboard)

        // Single plain imp - no tagged imps needed
        uvm_analysis_imp #(wf_sram_seq_item, wf_sram_scoreboard) analysis_export;

        wf_sram_ref_model ref_model;

        int unsigned checks_passed = 0;
        int unsigned checks_failed = 0;
        int unsigned bursts_checked = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            analysis_export = new("analysis_export", this);
            ref_model = wf_sram_ref_model::type_id::create("ref_model");
        endfunction

        // Called by monitor's ap.write() for every observed transaction
        function void write(wf_sram_seq_item item);
            if (item.is_write) begin
                // Update scoreboard ref model to stay in sync with driver's
                ref_model.write_beat(int'(item.write_addr), item.write_data);
                `uvm_info("WF_SB", $sformatf("REF update: %s", item.convert2string()), UVM_HIGH)
            end else begin
                check_burst(item);
            end
        endfunction

        function void check_burst(wf_sram_seq_item item);
            int unsigned exp_len = int'(item.burst_length);
            int unsigned got_len = item.read_beats.size();
            int unsigned exp_beats_len = item.expected_beats.size();

            bursts_checked++;

            // 1. Beat count
            if (got_len !== exp_len) begin
                `uvm_error("WF_SB", $sformatf(
                    "Beat count mismatch: exp=%0d got=%0d | %s",
                    exp_len, got_len, item.convert2string()))
                checks_failed++;
            end else checks_passed++;

            // 2. Data values (compare against driver's snapshot)
            begin
                int unsigned check_len = (got_len < exp_beats_len) ? got_len : exp_beats_len;
                for (int i = 0; i < int'(check_len); i++) begin
                    if (item.read_beats[i] !== item.expected_beats[i]) begin
                        `uvm_error("WF_SB", $sformatf(
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
                `uvm_error("WF_SB", $sformatf(
                    "burst_complete never seen for len=%0d", exp_len))
                checks_failed++;
            end else checks_passed++;

            `uvm_info("WF_SB", $sformatf(
                "Burst %0d done - passed=%0d failed=%0d",
                bursts_checked, checks_passed, checks_failed), UVM_LOW)
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("WF_SB", "=============================================", UVM_NONE)
            `uvm_info("WF_SB", $sformatf("  BURSTS  : %0d", bursts_checked), UVM_NONE)
            `uvm_info("WF_SB", $sformatf("  PASSED  : %0d", checks_passed),  UVM_NONE)
            `uvm_info("WF_SB", $sformatf("  FAILED  : %0d", checks_failed),  UVM_NONE)
            `uvm_info("WF_SB", "=============================================", UVM_NONE)
            if (checks_failed > 0)
                `uvm_error("WF_SB", "*** TEST FAILED ***")
            else
                `uvm_info("WF_SB", "*** TEST PASSED ***", UVM_NONE)
        endfunction

    endclass 


    // =========================================================================
    // 6. COVERAGE
    // =========================================================================
    class wf_sram_coverage extends uvm_subscriber #(wf_sram_seq_item);
        `uvm_component_utils(wf_sram_coverage)

        wf_sram_seq_item curr;

        covergroup cg_burst_length;
            cp_len: coverpoint curr.burst_length {
                bins len_1       = {1};
                bins len_small   = {[2:15]};
                bins len_medium  = {[16:63]};
                bins len_large   = {[64:255]};
                bins len_max_ish = {[256:512]};
            }
        endgroup

        covergroup cg_layer_offset;
            cp_offset: coverpoint curr.layer_offset {
                bins offset_zero  = {0};
                bins offset_small = {[1:1000]};
                bins offset_med   = {[1001:10000]};
                bins offset_large = {[10001:44190]};
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
                bins off_mid  = {[1:22095]};
                bins off_high = {[22096:44190]};
            }
            cp_len: coverpoint curr.burst_length {
                bins len_short = {[1:15]};
                bins len_med   = {[16:127]};
                bins len_long  = {[128:512]};
            }
            cross cp_off, cp_len;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_burst_length  = new();
            cg_layer_offset  = new();
            cg_burst_complete = new();
            cg_addr_cross    = new();
        endfunction

        // uvm_subscriber provides analysis_export and calls write() automatically
        function void write(wf_sram_seq_item t);
            // m_resp = t ;
            curr = t;
            // if (!item.is_write) begin
                cg_burst_length.sample();
                cg_layer_offset.sample();
                cg_burst_complete.sample();
                cg_addr_cross.sample();
            // end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("WF_COV", "---- Coverage Summary ----", UVM_NONE)
            `uvm_info("WF_COV", $sformatf("  Burst length : %.1f%%",
                cg_burst_length.get_coverage()),  UVM_NONE)
            `uvm_info("WF_COV", $sformatf("  Layer offset : %.1f%%",
                cg_layer_offset.get_coverage()),  UVM_NONE)
            `uvm_info("WF_COV", $sformatf("  Burst done   : %.1f%%",
                cg_burst_complete.get_coverage()), UVM_NONE)
            `uvm_info("WF_COV", $sformatf("  Addr cross   : %.1f%%",
                cg_addr_cross.get_coverage()),    UVM_NONE)
            `uvm_info("WF_COV", "--------------------------", UVM_NONE)
        endfunction

    endclass 



    // =========================================================================
    // 8. ENV
    // =========================================================================
    class wf_sram_env extends uvm_env;
        `uvm_component_utils(wf_sram_env)

        wf_sram_agent      agent;
        wf_sram_scoreboard scoreboard;
        wf_sram_coverage   coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent      = wf_sram_agent     ::type_id::create("agent",      this);
            scoreboard = wf_sram_scoreboard::type_id::create("scoreboard", this);
            coverage   = wf_sram_coverage  ::type_id::create("coverage",   this);
        endfunction

        function void connect_phase(uvm_phase phase);
            // Single fan-out: monitor -> scoreboard AND coverage
            agent.ap.connect(scoreboard.analysis_export);
            agent.ap.connect(coverage.analysis_export);
        endfunction

    endclass 


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


    // =========================================================================
    // 11. BASE TEST
    // =========================================================================
    class wf_sram_base_test extends uvm_test;
        `uvm_component_utils(wf_sram_base_test)

        wf_sram_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = wf_sram_env::type_id::create("env", this);
        endfunction

        function uvm_sequencer #(wf_sram_seq_item) get_sequencer();
            return env.agent.sequencer;
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction

    endclass 

    // =========================================================================
    // 12. TESTS
    // =========================================================================
    class wf_sram_smoke_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_smoke_seq seq = wf_sram_smoke_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_offset_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_offset_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_offset_seq seq = wf_sram_offset_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_burst_len_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_burst_len_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_burst_len_seq seq = wf_sram_burst_len_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_wr_rd_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_wr_rd_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_wr_rd_seq seq = wf_sram_wr_rd_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_b2b_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_b2b_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_b2b_read_seq seq = wf_sram_b2b_read_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_rand_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_rand_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_rand_seq seq = wf_sram_rand_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.num_pairs = 20;
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_lenet_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_lenet_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_lenet_seq seq = wf_sram_lenet_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_regression_test extends wf_sram_base_test;
        `uvm_component_utils(wf_sram_regression_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            wf_sram_regression_seq seq = wf_sram_regression_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class wf_sram_full_test extends wf_sram_base_test;
    `uvm_component_utils(wf_sram_full_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
        // --- Phase 1: Directed corners ---
        wf_sram_smoke_seq     smoke = wf_sram_smoke_seq    ::type_id::create("smoke");
        wf_sram_offset_seq    off   = wf_sram_offset_seq   ::type_id::create("off");
        wf_sram_burst_len_seq blen  = wf_sram_burst_len_seq::type_id::create("blen");
        wf_sram_wr_rd_seq     wrrd  = wf_sram_wr_rd_seq    ::type_id::create("wrrd");
        wf_sram_b2b_read_seq  b2b   = wf_sram_b2b_read_seq ::type_id::create("b2b");
        wf_sram_lenet_seq     lenet = wf_sram_lenet_seq    ::type_id::create("lenet");
        // --- Phase 2: Constrained random ---
        wf_sram_rand_seq      rnd   = wf_sram_rand_seq     ::type_id::create("rnd");

        phase.raise_objection(this);

        `uvm_info("WF_FULL", "=== PHASE 1: Smoke ===", UVM_NONE)
        smoke.start(get_sequencer());

        `uvm_info("WF_FULL", "=== PHASE 2: Layer Offset ===", UVM_NONE)
        off.start(get_sequencer());

        `uvm_info("WF_FULL", "=== PHASE 3: Burst Length Stress ===", UVM_NONE)
        blen.start(get_sequencer());

        `uvm_info("WF_FULL", "=== PHASE 4: Write-Read Interleaved ===", UVM_NONE)
        wrrd.start(get_sequencer());

        `uvm_info("WF_FULL", "=== PHASE 5: Back-to-Back Reads ===", UVM_NONE)
        b2b.start(get_sequencer());

        `uvm_info("WF_FULL", "=== PHASE 6: LeNet-5 Integration ===", UVM_NONE)
        lenet.start(get_sequencer());

        `uvm_info("WF_FULL", "=== PHASE 7: Random (100 pairs) ===", UVM_NONE)
        rnd.num_pairs = 100;
        rnd.start(get_sequencer());

        // Drain pipeline before dropping objection
        repeat (PKG_PIPE_LATENCY + 8) @(posedge env.agent.monitor.vif.cb_mon);

        phase.drop_objection(this);

        `uvm_info("WF_FULL", "=== FULL TEST COMPLETE ===", UVM_NONE)
    endtask

endclass 

endpackage : wf_sram_pkg

// =============================================================================
// INTERFACE
// =============================================================================
interface wf_sram_if #(
    parameter int DATA_WIDTH    = 8,
    parameter int MAX_BURST_LEN = 512,
    parameter int MAX_WEIGHTS   = 30720,
    parameter int TOTAL_WEIGHTS = 44190
)(input logic clk);

    logic                                        rst;
    logic [$clog2(TOTAL_WEIGHTS+1)-1:0]          layer_offset;
    logic [$clog2(TOTAL_WEIGHTS)-1:0]            write_addr;
    logic signed [DATA_WIDTH-1:0]                write_data;
    logic                                        write_enable;
    logic [$clog2(MAX_WEIGHTS)-1:0]              read_addr;
    logic [$clog2(MAX_BURST_LEN+1)-1:0]          burst_length;
    logic                                        read_request;
    logic signed [DATA_WIDTH-1:0]                read_data;
    logic                                        read_valid;
    logic                                        burst_complete;

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

    // SVA assertions
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

endinterface 


// =============================================================================
// DUT
// =============================================================================
module weight_sram_lenet5_actual #(
    parameter DATA_WIDTH    = 8,
    parameter MAX_BURST_LEN = 512,
    parameter MAX_WEIGHTS   = 30720,
    parameter TOTAL_WEIGHTS = 44190
)(
    input  logic clk,
    input  logic rst,
    input  logic [$clog2(TOTAL_WEIGHTS+1)-1:0] layer_offset,
    input  logic [$clog2(TOTAL_WEIGHTS)-1:0]   write_addr,
    input  logic signed [DATA_WIDTH-1:0]       write_data,
    input  logic                               write_enable,
    input  logic [$clog2(MAX_WEIGHTS)-1:0]     read_addr,
    input  logic [$clog2(MAX_BURST_LEN+1)-1:0] burst_length,
    input  logic                               read_request,
    output logic signed [DATA_WIDTH-1:0]       read_data,
    output logic                               read_valid,
    output logic                               burst_complete
);

    localparam BRAM_DEPTH = 65536;
    localparam ADDR_WIDTH = $clog2(BRAM_DEPTH);

    (* ram_style = "block" *)
    logic signed [DATA_WIDTH-1:0] weight_bram [BRAM_DEPTH];

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

    always_comb absolute_read_addr = layer_offset + read_addr;
    always_comb bram_addr = write_enable ? write_addr : current_read_addr;

    always_ff @(posedge clk) begin
        if (write_enable) weight_bram[bram_addr] <= write_data;
        read_data <= weight_bram[bram_addr];
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
// `timescale 1ns/1ps
`include "uvm_macros.svh"
import uvm_pkg::* ;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int PKG_DATA_WIDTH    = 8;
    localparam int PKG_MAX_BURST_LEN = 512;
    localparam int PKG_MAX_WEIGHTS   = 30720;
    localparam int PKG_TOTAL_WEIGHTS = 44190;
    localparam int PKG_BRAM_DEPTH    = 65536;
    localparam int PKG_PIPE_LATENCY  = 3;

module wf_sram_tb_top;
    import uvm_pkg::* ;
    import wf_sram_pkg::* ;

    

    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    wf_sram_if #(
        PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
        PKG_MAX_WEIGHTS, PKG_TOTAL_WEIGHTS
    ) dut_if (.clk(clk));

    weight_sram_lenet5_actual #(
        .DATA_WIDTH    (PKG_DATA_WIDTH),
        .MAX_BURST_LEN (PKG_MAX_BURST_LEN),
        .MAX_WEIGHTS   (PKG_MAX_WEIGHTS),
        .TOTAL_WEIGHTS (PKG_TOTAL_WEIGHTS)
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
        uvm_config_db #(virtual wf_sram_if #(
            PKG_DATA_WIDTH, PKG_MAX_BURST_LEN,
            PKG_MAX_WEIGHTS, PKG_TOTAL_WEIGHTS))
        ::set(null, "uvm_test_top.*", "vif", dut_if);
        run_test("wf_sram_full_test");
    end

    initial begin
        #10_000_000;
        `uvm_fatal("WF_TB", "Hard timeout 10ms")
    end

endmodule 