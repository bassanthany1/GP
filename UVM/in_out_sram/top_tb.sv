// =============================================================================
// fmap_sram_tb.sv
// Full UVM Verification for feature_map_sram_5port
// Pattern: single-package, plain uvm_analysis_imp, no tagged imps.
//
// Compile:  vlog fmap_sram_tb.sv
// Run:      vsim -c fmap_sram_tb_top +UVM_TESTNAME=fm_full_test -do "run -all"
//
// Tests available:
//   fm_smoke_test          - basic write-then-read on all 3 ports
//   fm_multiport_test      - all 3 ports reading simultaneously
//   fm_conflict_test       - bank conflict detection (write vs read same bank)
//   fm_no_conflict_test    - write + reads on different banks (no conflict)
//   fm_addr_sweep_test     - full address space 0..863
//   fm_bank_boundary_test  - addresses that cross bank boundaries
//   fm_rand_test           - constrained-random write/read mix
//   fm_regression_test     - full directed regression
//   fm_full_test           - everything (default)
// =============================================================================


// =============================================================================
// PACKAGE
// =============================================================================
package fmap_sram_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // -------------------------------------------------------------------------
    // Parameters – must match DUT
    // -------------------------------------------------------------------------
    localparam int PKG_DATA_WIDTH     = 8;
    localparam int PKG_TOTAL_ELEMENTS = 864;
    localparam int PKG_NUM_PORTS      = 3;

    // Derived – mirrors DUT's localparam expressions exactly
    localparam int PKG_BANK_DEPTH      = (PKG_TOTAL_ELEMENTS + 2) / 3;   // 288
    localparam int PKG_ADDR_WIDTH      = $clog2(PKG_TOTAL_ELEMENTS);      // 10
    localparam int PKG_BANK_ADDR_WIDTH = $clog2(PKG_BANK_DEPTH);          //  9

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


    // =========================================================================
    // 3. DRIVER
    // =========================================================================
    // Drives one item per DUT clock cycle (writes OR reads).
    // For write items:   asserts wr_en for 1 cycle, deasserts, updates ref.
    // For read items:    drives rd_req/rd_addr, optionally also wr_en
    //                    (conflict injection), then waits 1 cycle for outputs.
    // =========================================================================
    class fm_driver extends uvm_driver #(fm_seq_item);
        `uvm_component_utils(fm_driver)

        virtual fm_if vif;
        fm_ref_model drv_ref;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv_ref = fm_ref_model::type_id::create("drv_ref");
            if (!uvm_config_db #(virtual fm_if)::get(this, "", "vif", vif))
                `uvm_fatal("FM_DRV", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            fm_seq_item item;
            apply_reset();
            forever begin
                seq_item_port.get_next_item(item);
                if (item.is_write) drive_write(item);
                else               drive_read(item);
                seq_item_port.item_done();
            end
        endtask

        // ---- Reset ----
        task apply_reset();
            vif.cb_drv.rst    <= 1'b1;
            vif.cb_drv.wr_en  <= 1'b0;
            vif.cb_drv.wr_addr <= '0;
            vif.cb_drv.wr_data <= '0;
            for (int p = 0; p < PKG_NUM_PORTS; p++) begin
                vif.cb_drv.rd_req [p] <= 1'b0;
                vif.cb_drv.rd_addr[p] <= '0;
            end
            repeat (5) @(vif.cb_drv);
            vif.cb_drv.rst <= 1'b0;
            repeat (2) @(vif.cb_drv);
        endtask

        // ---- Write transaction ----
        // Cycle 0: drive addr+data, wr_en low
        // Cycle 1: assert wr_en
        // Cycle 2: deassert wr_en, update ref model
        task drive_write(fm_seq_item item);
            // Cycle 0: setup
            vif.cb_drv.wr_addr <= item.wr_addr;
            vif.cb_drv.wr_data <= item.wr_data;
            vif.cb_drv.wr_en   <= 1'b0;
            deassert_reads();
            @(vif.cb_drv);

            // Cycle 1: commit
            vif.cb_drv.wr_en <= 1'b1;
            @(vif.cb_drv);

            // Cycle 2: deassert
            vif.cb_drv.wr_en <= 1'b0;
            @(vif.cb_drv);

            // Update shadow
            drv_ref.write(int'(item.wr_addr), item.wr_data);

            `uvm_info("FM_DRV",
                $sformatf("Drove: %s", item.convert2string()), UVM_HIGH)
        endtask

        // ---- Read transaction ----
        // Cycle 0: drive rd_req/rd_addr (+ optional concurrent wr_en).
        //          Compute expected values from current shadow state.
        // Cycle 1: deassert everything; monitor captures outputs this cycle.
        // Cycle 2: idle gap.
        task drive_read(fm_seq_item item);
            // Snapshot expected BEFORE driving
            drv_ref.predict_read(item);

            // Cycle 0: assert stimulus
            for (int p = 0; p < PKG_NUM_PORTS; p++) begin
                vif.cb_drv.rd_req [p] <= item.rd_req[p];
                vif.cb_drv.rd_addr[p] <= item.rd_addr[p];
            end

            if (item.wr_en_during_read) begin
                vif.cb_drv.wr_en   <= 1'b1;
                vif.cb_drv.wr_addr <= item.wr_addr_during_read;
                vif.cb_drv.wr_data <= item.wr_data_during_read;
            end else begin
                vif.cb_drv.wr_en <= 1'b0;
            end
            @(vif.cb_drv);

            // Cycle 1: deassert – monitor sees rd_valid/rd_data this cycle
            deassert_reads();
            vif.cb_drv.wr_en <= 1'b0;

            // If concurrent write happened, update shadow AFTER the read snapshot
            // (write takes effect on clock edge, read data comes from pre-write value)
            if (item.wr_en_during_read)
                drv_ref.write(int'(item.wr_addr_during_read),
                              item.wr_data_during_read);
            @(vif.cb_drv);

            // Cycle 2: idle
            @(vif.cb_drv);

            `uvm_info("FM_DRV",
                $sformatf("Drove: %s", item.convert2string()), UVM_MEDIUM)
        endtask

        task deassert_reads();
            for (int p = 0; p < PKG_NUM_PORTS; p++)
                vif.cb_drv.rd_req[p] <= 1'b0;
        endtask

    endclass 


    // =========================================================================
    // 4. MONITOR
    // =========================================================================
    // Watches the interface every clock edge.
    //
    // Observed write: publishes item with is_write=1 for scoreboard ref update.
    // Observed read:  when any rd_req is seen, waits one more cycle for the
    //                 registered outputs (rd_valid / rd_data / bank_conflict),
    //                 then publishes item with all observed fields filled.
    // =========================================================================
    class fm_monitor extends uvm_monitor;
        `uvm_component_utils(fm_monitor)

        virtual fm_if vif;
        uvm_analysis_port #(fm_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual fm_if)::get(this, "", "vif", vif))
                `uvm_fatal("FM_MON", "Cannot get vif")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                fm_seq_item item;
                @(vif.cb_mon);

                if (vif.cb_mon.rst) continue;

                // ---- Observe write ----
if (vif.cb_mon.wr_en && !$isunknown(vif.cb_mon.wr_addr)) begin
    // Check if any read request is active in this cycle
    bit any_read = 0;
    for (int p = 0; p < PKG_NUM_PORTS; p++)
        if (vif.cb_mon.rd_req[p]) any_read = 1;
    // Only create a write item if there is no concurrent read
    if (!any_read) begin
        item          = fm_seq_item::type_id::create("mon_wr");
        item.is_write = 1;
        item.wr_addr  = vif.cb_mon.wr_addr;
        item.wr_data  = vif.cb_mon.wr_data;
        ap.write(item);
        `uvm_info("FM_MON", $sformatf("Observed: %s", item.convert2string()), UVM_HIGH)
    end
end

                // ---- Observe read request ----
                // A read cycle is any cycle where at least one rd_req is high
                // AND wr_en is NOT also high (to avoid double-counting conflict
                // cycles as separate write items – the conflict data is captured
                // inside the read item itself).
                begin
                    bit any_req = 0;
                    for (int p = 0; p < PKG_NUM_PORTS; p++)
                        if (vif.cb_mon.rd_req[p]) any_req = 1;

                    if (any_req) begin
                        // Capture stimulus fields
                        item          = fm_seq_item::type_id::create("mon_rd");
                        item.is_write = 0;
                        for (int p = 0; p < PKG_NUM_PORTS; p++) begin
                            item.rd_req [p] = vif.cb_mon.rd_req [p];
                            item.rd_addr[p] = vif.cb_mon.rd_addr[p];
                        end
                        // Capture concurrent write fields (for conflict scenario)
                        item.wr_en_during_read    = vif.cb_mon.wr_en;
                        item.wr_addr_during_read  = vif.cb_mon.wr_addr;
                        item.wr_data_during_read  = vif.cb_mon.wr_data;

                        // bank_conflict is COMBINATIONAL: capture it NOW on the
                        // stimulus cycle, before advancing the clock.
                        item.obs_bank_conflict = vif.cb_mon.bank_conflict;

                        // Wait one cycle for registered outputs (rd_valid / rd_data)
                        @(vif.cb_mon);

                        // Capture DUT registered outputs
                        for (int p = 0; p < PKG_NUM_PORTS; p++) begin
                            item.obs_rd_data [p] = vif.cb_mon.rd_data [p];
                            item.obs_rd_valid[p] = vif.cb_mon.rd_valid[p];
                        end
                        // bank_conflict already captured above (do NOT re-sample)

                        ap.write(item);
                        `uvm_info("FM_MON",
                            $sformatf("Observed: %s conflict=%0b",
                                item.convert2string(), item.obs_bank_conflict),
                            UVM_MEDIUM)
                    end
                end
            end
        endtask

    endclass 


    // =========================================================================
    // 5. SCOREBOARD
    // =========================================================================
    // Receives ALL items from the monitor via a single plain analysis_imp.
    //
    // Write items  -> update internal shadow memory.
    // Read  items  -> run ref model and compare:
    //                  a) rd_valid per port
    //                  b) rd_data  per port (only when rd_valid expected)
    //                  c) bank_conflict flag
    // =========================================================================
    class fm_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(fm_scoreboard)

        uvm_analysis_imp #(fm_seq_item, fm_scoreboard) analysis_export;

        fm_ref_model ref_model;

        int unsigned checks_passed  = 0;
        int unsigned checks_failed  = 0;
        int unsigned reads_checked  = 0;
        int unsigned writes_tracked = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            analysis_export = new("analysis_export", this);
            ref_model       = fm_ref_model::type_id::create("ref_model");
        endfunction

        function void write(fm_seq_item item);
    if (item.is_write) begin
        ref_model.write(int'(item.wr_addr), item.wr_data);
        writes_tracked++;
    end else begin
        check_read(item);
    end
endfunction 


function void check_read(fm_seq_item item);
    reads_checked++;

    // Scoreboard predicts from its own shadow (NOT relying on driver's exp_* fields)
    ref_model.predict_read(item);

    for (int p = 0; p < PKG_NUM_PORTS; p++) begin
        // rd_valid
        if (item.obs_rd_valid[p] !== logic'(item.exp_rd_valid[p])) begin
            `uvm_error("FM_SB", $sformatf("[Rd#%0d] rd_valid[%0d] mismatch: got=%0b exp=%0b | %s",
    reads_checked, p, item.obs_rd_valid[p], item.exp_rd_valid[p],
    item.convert2string()))
            checks_failed++;
        end else checks_passed++;

        // rd_data
        if (item.rd_req[p]) begin
            bit port_conflict = 0;
            if (item.wr_en_during_read) begin
                int unsigned wr_bank = int'(item.wr_addr_during_read) % 3;
                int unsigned rd_bank = int'(item.rd_addr[p]) % 3;
                port_conflict = (wr_bank == rd_bank);
            end
            if (!port_conflict) begin
                if (item.obs_rd_data[p] !== item.exp_rd_data[p]) begin
                    `uvm_error("FM_SB", $sformatf("[Rd#%0d] rd_data[%0d] mismatch: got=%0d exp=%0d addr=%0d | %s",
    reads_checked, p, $signed(item.obs_rd_data[p]),
    $signed(item.exp_rd_data[p]), item.rd_addr[p],
    item.convert2string()))
                    checks_failed++;
                end else checks_passed++;
            end
        end
    end

    // bank_conflict
    if (item.obs_bank_conflict !== logic'(item.exp_bank_conflict)) begin

        `uvm_error("FM_SB", $sformatf("[Rd#%0d] bank_conflict mismatch: got=%0b exp=%0b | %s",
    reads_checked, item.obs_bank_conflict, item.exp_bank_conflict,
    item.convert2string()))
        checks_failed++;
    end else checks_passed++;

    // Apply concurrent write to shadow AFTER the read check
    if (item.wr_en_during_read)
        ref_model.write(int'(item.wr_addr_during_read), item.wr_data_during_read);

    `uvm_info("FM_SB", $sformatf("Read %0d done - passed=%0d failed=%0d",
              reads_checked, checks_passed, checks_failed), UVM_LOW)
endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("FM_SB", "=============================================", UVM_NONE)
            `uvm_info("FM_SB", $sformatf("  WRITES TRACKED : %0d", writes_tracked), UVM_NONE)
            `uvm_info("FM_SB", $sformatf("  READS  CHECKED : %0d", reads_checked),  UVM_NONE)
            `uvm_info("FM_SB", $sformatf("  CHECKS PASSED  : %0d", checks_passed),  UVM_NONE)
            `uvm_info("FM_SB", $sformatf("  CHECKS FAILED  : %0d", checks_failed),  UVM_NONE)
            `uvm_info("FM_SB", "=============================================", UVM_NONE)
            if (checks_failed > 0)
                `uvm_error("FM_SB", "*** TEST FAILED ***")
            else
                `uvm_info("FM_SB",  "*** TEST PASSED ***", UVM_NONE)
        endfunction

    endclass 


    // =========================================================================
    // 6. COVERAGE
    // =========================================================================
    class fm_coverage extends uvm_subscriber #(fm_seq_item);
        `uvm_component_utils(fm_coverage)

        fm_seq_item curr;

        // ---- Write address distribution ----
        covergroup cg_wr_addr;
            cp_wa: coverpoint curr.wr_addr {
                bins addr_lo  = {[0:287]};    // bank0 region
                bins addr_mid = {[288:575]};  // bank1 region
                bins addr_hi  = {[576:863]};  // bank2 region
            }
        endgroup

        // ---- Read address per port ----
        covergroup cg_rd_addr;
            cp_p0: coverpoint curr.rd_addr[0] {
                bins a_lo={[0:287]}; bins a_mid={[288:575]}; bins a_hi={[576:863]};
            }
            cp_p1: coverpoint curr.rd_addr[1] {
                bins a_lo={[0:287]}; bins a_mid={[288:575]}; bins a_hi={[576:863]};
            }
            cp_p2: coverpoint curr.rd_addr[2] {
                bins a_lo={[0:287]}; bins a_mid={[288:575]}; bins a_hi={[576:863]};
            }
        endgroup

        // ---- Port activity combinations ----
        covergroup cg_port_req;
            cp_req: coverpoint {curr.rd_req[2], curr.rd_req[1], curr.rd_req[0]} {
                // bins none   = {3'b000};
                bins p0     = {3'b001};
                bins p1     = {3'b010};
                bins p2     = {3'b100};
                bins p01    = {3'b011};
                bins p02    = {3'b101};
                bins p12    = {3'b110};
                bins all3   = {3'b111};
            }
        endgroup

        // ---- Bank conflict ----
        covergroup cg_conflict;
            cp_cf: coverpoint curr.obs_bank_conflict {
                bins no_conflict = {0};
                bins conflict    = {1};
            }
        endgroup

        covergroup cg_bank_pattern;
    // Which bank does each active port access?
    cp_b0: coverpoint (curr.rd_req[0] ? int'(curr.rd_addr[0]) % 3 : 3) {
        bins bank0={0}; bins bank1={1}; bins bank2={2}; bins inactive={3};
    }
    cp_b1: coverpoint (curr.rd_req[1] ? int'(curr.rd_addr[1]) % 3 : 3) {
        bins bank0={0}; bins bank1={1}; bins bank2={2}; bins inactive={3};
    }
    cp_b2: coverpoint (curr.rd_req[2] ? int'(curr.rd_addr[2]) % 3 : 3) {
        bins bank0={0}; bins bank1={1}; bins bank2={2}; bins inactive={3};
    }
    cross cp_b0, cp_b1, cp_b2 {
        // Ignore: all three inactive (impossible — monitor requires at least one active)
        ignore_bins all_inactive = binsof(cp_b0.inactive)
                                && binsof(cp_b1.inactive)
                                && binsof(cp_b2.inactive);
    }
endgroup

        // ---- Write-during-read conflict injection ----
        covergroup cg_wr_during_rd;
            cp_wdr: coverpoint curr.wr_en_during_read {
                bins normal    = {0};
                bins wr_during = {1};
            }
        endgroup

        // ---- Address extremes ----
        covergroup cg_addr_extremes;
            cp_wr: coverpoint curr.wr_addr {
                bins addr_zero = {0};
                bins addr_max  = {PKG_TOTAL_ELEMENTS-1};
                bins addr_mid  = {[1:PKG_TOTAL_ELEMENTS-2]};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_wr_addr      = new();
            cg_rd_addr      = new();
            cg_port_req     = new();
            cg_conflict     = new();
            cg_bank_pattern = new();
            cg_wr_during_rd = new();
            cg_addr_extremes = new();
        endfunction

        function void write(fm_seq_item t);
            curr = t;
            if (t.is_write) begin
                cg_wr_addr.sample();
                cg_addr_extremes.sample();
            end else begin
                cg_rd_addr.sample();
                cg_port_req.sample();
                cg_conflict.sample();
                cg_bank_pattern.sample();
                cg_wr_during_rd.sample();
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("FM_COV", "---- Coverage Summary ----", UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Wr addr zones   : %.1f%%",
                cg_wr_addr.get_coverage()),       UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Rd addr zones   : %.1f%%",
                cg_rd_addr.get_coverage()),       UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Port req combos : %.1f%%",
                cg_port_req.get_coverage()),      UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Bank conflict   : %.1f%%",
                cg_conflict.get_coverage()),      UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Bank pattern    : %.1f%%",
                cg_bank_pattern.get_coverage()),  UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Wr during rd    : %.1f%%",
                cg_wr_during_rd.get_coverage()),  UVM_NONE)
            `uvm_info("FM_COV", $sformatf("  Addr extremes   : %.1f%%",
                cg_addr_extremes.get_coverage()), UVM_NONE)
            `uvm_info("FM_COV", "--------------------------", UVM_NONE)
        endfunction

    endclass 


    // =========================================================================
    // 7. AGENT
    // =========================================================================
    class fm_agent extends uvm_agent;
        `uvm_component_utils(fm_agent)

        uvm_sequencer #(fm_seq_item) sequencer;
        fm_driver                    driver;
        fm_monitor                   monitor;

        uvm_analysis_port #(fm_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor = fm_monitor::type_id::create("monitor", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sequencer = uvm_sequencer #(fm_seq_item)
                            ::type_id::create("sequencer", this);
                driver    = fm_driver::type_id::create("driver", this);
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
    class fm_env extends uvm_env;
        `uvm_component_utils(fm_env)

        fm_agent      agent;
        fm_scoreboard scoreboard;
        fm_coverage   coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent      = fm_agent     ::type_id::create("agent",      this);
            scoreboard = fm_scoreboard::type_id::create("scoreboard", this);
            coverage   = fm_coverage  ::type_id::create("coverage",   this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.ap.connect(scoreboard.analysis_export);
            agent.ap.connect(coverage.analysis_export);
        endfunction

    endclass 


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


    // =========================================================================
    // 11. BASE TEST
    // =========================================================================
    class fm_base_test extends uvm_test;
        `uvm_component_utils(fm_base_test)

        fm_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = fm_env::type_id::create("env", this);
        endfunction

        function uvm_sequencer #(fm_seq_item) get_sequencer();
            return env.agent.sequencer;
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            uvm_top.print_topology();
        endfunction

    endclass 


    // =========================================================================
    // 12. TESTS
    // =========================================================================
    class fm_smoke_test extends fm_base_test;
        `uvm_component_utils(fm_smoke_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_smoke_seq seq = fm_smoke_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_multiport_test extends fm_base_test;
        `uvm_component_utils(fm_multiport_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_multiport_seq seq = fm_multiport_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_conflict_test extends fm_base_test;
        `uvm_component_utils(fm_conflict_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_conflict_seq seq = fm_conflict_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_no_conflict_test extends fm_base_test;
        `uvm_component_utils(fm_no_conflict_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_no_conflict_seq seq = fm_no_conflict_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_addr_sweep_test extends fm_base_test;
        `uvm_component_utils(fm_addr_sweep_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_addr_sweep_seq seq = fm_addr_sweep_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_bank_boundary_test extends fm_base_test;
        `uvm_component_utils(fm_bank_boundary_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_bank_boundary_seq seq = fm_bank_boundary_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_rand_test extends fm_base_test;
        `uvm_component_utils(fm_rand_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_rand_seq seq = fm_rand_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.num_writes = 30; seq.num_reads = 60;
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    class fm_regression_test extends fm_base_test;
        `uvm_component_utils(fm_regression_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        task run_phase(uvm_phase phase);
            fm_regression_seq seq = fm_regression_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(get_sequencer());
            phase.drop_objection(this);
        endtask
    endclass

    // Full test – all suites in order, heavy random at end
    class fm_full_test extends fm_base_test;
        `uvm_component_utils(fm_full_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction

        task run_phase(uvm_phase phase);
            fm_smoke_seq         smoke  = fm_smoke_seq        ::type_id::create("smoke");
            fm_multiport_seq     mport  = fm_multiport_seq    ::type_id::create("mport");
            fm_conflict_seq      conf   = fm_conflict_seq     ::type_id::create("conf");
            fm_no_conflict_seq   noconf = fm_no_conflict_seq  ::type_id::create("noconf");
            fm_addr_sweep_seq    sweep  = fm_addr_sweep_seq   ::type_id::create("sweep");
            fm_bank_boundary_seq bndry  = fm_bank_boundary_seq::type_id::create("bndry");
            fm_bank_pattern_seq  pat    = fm_bank_pattern_seq ::type_id::create("pat");   // NEW
            fm_rand_seq          rnd    = fm_rand_seq         ::type_id::create("rnd");

            phase.raise_objection(this);

            `uvm_info("FM_FULL", "=== PHASE 1: Smoke ===", UVM_NONE)
            smoke.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 2: Multi-Port Combinations ===", UVM_NONE)
            mport.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 3: Bank Conflict Detection ===", UVM_NONE)
            conf.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 4: No-Conflict Verification ===", UVM_NONE)
            noconf.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 5: Full Address Sweep ===", UVM_NONE)
            sweep.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 6: Bank Boundary Addresses ===", UVM_NONE)
            bndry.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 7: Exhaustive Bank Pattern ===", UVM_NONE)
            pat.start(get_sequencer());

            `uvm_info("FM_FULL", "=== PHASE 8: Random (100w / 200r) ===", UVM_NONE)
            rnd.num_writes = 100; rnd.num_reads = 200;
            rnd.start(get_sequencer());

            phase.drop_objection(this);
            `uvm_info("FM_FULL", "=== FULL TEST COMPLETE ===", UVM_NONE)
        endtask

    endclass 

endpackage 


// =============================================================================
// INTERFACE
// =============================================================================
interface fm_if #(
    parameter int DATA_WIDTH     = 8,
    parameter int TOTAL_ELEMENTS = 864,
    parameter int NUM_PORTS      = 3
)(input logic clk);

    localparam int ADDR_W = $clog2(TOTAL_ELEMENTS);   // 10

    // ---- Write port ----
    logic                             rst;
    logic                             wr_en;
    logic [ADDR_W-1:0]               wr_addr;
    logic signed [DATA_WIDTH-1:0]    wr_data;

    // ---- Read ports ----
    logic                            rd_req  [NUM_PORTS];
    logic [ADDR_W-1:0]              rd_addr [NUM_PORTS];
    logic signed [DATA_WIDTH-1:0]   rd_data [NUM_PORTS];
    logic                            rd_valid[NUM_PORTS];

    // ---- Conflict flag ----
    logic                            bank_conflict;

    // ---- Initial values ----
    initial begin
        rst    = 1'b1;
        wr_en  = 1'b0;
        wr_addr = '0;
        wr_data = '0;
        for (int p = 0; p < NUM_PORTS; p++) begin
            rd_req [p] = 1'b0;
            rd_addr[p] = '0;
        end
    end

    // ---- Clocking blocks ----
    clocking cb_drv @(posedge clk);
        default input #1 output #0;
        output rst;
        output wr_en, wr_addr, wr_data;
        output rd_req, rd_addr;
        input  rd_data, rd_valid;
        input  bank_conflict;
    endclocking

    clocking cb_mon @(posedge clk);
        default input #1;
        input rst;
        input wr_en, wr_addr, wr_data;
        input rd_req, rd_addr;
        input rd_data, rd_valid;
        input bank_conflict;
    endclocking

    modport drv_mp (clocking cb_drv, input clk);
    modport mon_mp (clocking cb_mon, input clk);

    // ---- SVA Assertions ----

    // rd_valid[p] must be exactly the registered version of rd_req[p]
    // (checked for each port independently)
    generate
        for (genvar p = 0; p < NUM_PORTS; p++) begin : g_sva
            property p_valid_follows_req;
                @(posedge clk) disable iff (rst)
                $rose(rd_req[p]) |=> rd_valid[p];
            endproperty
            ap_valid_follows: assert property (p_valid_follows_req)
                else $error("SVA: rd_valid[%0d] did not follow rd_req[%0d]", p, p);

            property p_valid_deasserts;
                @(posedge clk) disable iff (rst)
                !rd_req[p] |=> !rd_valid[p];
            endproperty
            ap_valid_deasserts: assert property (p_valid_deasserts)
                else $error("SVA: rd_valid[%0d] did not deassert after rd_req[%0d]", p, p);
        end
    endgenerate

    // bank_conflict can only be asserted when wr_en is high
    property p_conflict_needs_wr;
        @(posedge clk) disable iff (rst)
        bank_conflict |-> wr_en;
    endproperty
    ap_conflict_wr: assert property (p_conflict_needs_wr)
        else $error("SVA: bank_conflict asserted without wr_en");

    // wr_addr must be in range
    property p_wr_addr_range;
        @(posedge clk) disable iff (rst)
        wr_en |-> (wr_addr < TOTAL_ELEMENTS);
    endproperty
    ap_wr_range: assert property (p_wr_addr_range)
        else $error("SVA: wr_addr out of range");

endinterface 


// =============================================================================
// DUT
// =============================================================================
module feature_map_sram_5port #(
    parameter DATA_WIDTH     = 8,
    parameter TOTAL_ELEMENTS = 864,
    parameter NUM_PORTS      = 3
)(
    input  logic clk,
    input  logic rst,

    input  logic                              wr_en,
    input  logic [$clog2(TOTAL_ELEMENTS)-1:0] wr_addr,
    input  logic signed [DATA_WIDTH-1:0]      wr_data,

    input  logic                              rd_req  [NUM_PORTS],
    input  logic [$clog2(TOTAL_ELEMENTS)-1:0] rd_addr [NUM_PORTS],
    output logic signed [DATA_WIDTH-1:0]      rd_data [NUM_PORTS],
    output logic                              rd_valid[NUM_PORTS],

    output logic bank_conflict
);
    localparam BANK_DEPTH      = (TOTAL_ELEMENTS + 2) / 3;
    localparam BANK_ADDR_WIDTH = $clog2(BANK_DEPTH);

    logic signed [DATA_WIDTH-1:0] bank0 [0:BANK_DEPTH-1];
    logic signed [DATA_WIDTH-1:0] bank1 [0:BANK_DEPTH-1];
    logic signed [DATA_WIDTH-1:0] bank2 [0:BANK_DEPTH-1];

    logic [1:0]                  wr_bank;
    logic [BANK_ADDR_WIDTH-1:0]  wr_baddr;

    assign wr_bank  = wr_addr % 3;
    assign wr_baddr = wr_addr / 3;

    always_ff @(posedge clk) begin
        if (wr_en) begin
            case (wr_bank)
                2'd0: bank0[wr_baddr] <= wr_data;
                2'd1: bank1[wr_baddr] <= wr_data;
                2'd2: bank2[wr_baddr] <= wr_data;
                default: ;
            endcase
        end
    end

    logic [1:0]                 rb [NUM_PORTS];
    logic [BANK_ADDR_WIDTH-1:0] rba[NUM_PORTS];

    assign rb[0] = rd_addr[0] % 3; assign rba[0] = rd_addr[0] / 3;
    assign rb[1] = rd_addr[1] % 3; assign rba[1] = rd_addr[1] / 3;
    assign rb[2] = rd_addr[2] % 3; assign rba[2] = rd_addr[2] / 3;

    always_ff @(posedge clk) begin
        if (rst) begin rd_valid[0] <= 0; rd_data[0] <= 0; end
        else begin
            rd_valid[0] <= rd_req[0];
            if (rd_req[0]) begin
                case (rb[0])
                    2'd0: rd_data[0] <= bank0[rba[0]];
                    2'd1: rd_data[0] <= bank1[rba[0]];
                    2'd2: rd_data[0] <= bank2[rba[0]];
                    default: rd_data[0] <= 0;
                endcase
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin rd_valid[1] <= 0; rd_data[1] <= 0; end
        else begin
            rd_valid[1] <= rd_req[1];
            if (rd_req[1]) begin
                case (rb[1])
                    2'd0: rd_data[1] <= bank0[rba[1]];
                    2'd1: rd_data[1] <= bank1[rba[1]];
                    2'd2: rd_data[1] <= bank2[rba[1]];
                    default: rd_data[1] <= 0;
                endcase
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin rd_valid[2] <= 0; rd_data[2] <= 0; end
        else begin
            rd_valid[2] <= rd_req[2];
            if (rd_req[2]) begin
                case (rb[2])
                    2'd0: rd_data[2] <= bank0[rba[2]];
                    2'd1: rd_data[2] <= bank1[rba[2]];
                    2'd2: rd_data[2] <= bank2[rba[2]];
                    default: rd_data[2] <= 0;
                endcase
            end
        end
    end

    assign bank_conflict = wr_en & (
        (rd_req[0] & (rb[0] == wr_bank)) |
        (rd_req[1] & (rb[1] == wr_bank)) |
        (rd_req[2] & (rb[2] == wr_bank))
    );

endmodule 


// =============================================================================
// TESTBENCH TOP
// =============================================================================
`include "uvm_macros.svh"
import uvm_pkg::*;

module fmap_sram_tb_top;
    import uvm_pkg::*;
    import fmap_sram_pkg::*;

    // ---- Parameters ----
    localparam int TB_DATA_WIDTH     = 8;
    localparam int TB_TOTAL_ELEMENTS = 864;
    localparam int TB_NUM_PORTS      = 3;

    // ---- Clock ----
    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ---- Interface ----
    fm_if #(TB_DATA_WIDTH, TB_TOTAL_ELEMENTS, TB_NUM_PORTS) dut_if (.clk(clk));

    // ---- DUT ----
    feature_map_sram_5port #(
        .DATA_WIDTH     (TB_DATA_WIDTH),
        .TOTAL_ELEMENTS (TB_TOTAL_ELEMENTS),
        .NUM_PORTS      (TB_NUM_PORTS)
    ) dut (
        .clk          (clk),
        .rst          (dut_if.rst),
        .wr_en        (dut_if.wr_en),
        .wr_addr      (dut_if.wr_addr),
        .wr_data      (dut_if.wr_data),
        .rd_req       (dut_if.rd_req),
        .rd_addr      (dut_if.rd_addr),
        .rd_data      (dut_if.rd_data),
        .rd_valid     (dut_if.rd_valid),
        .bank_conflict(dut_if.bank_conflict)
    );

    // ---- UVM kickoff ----
    initial begin
        uvm_config_db #(virtual fm_if #(
            TB_DATA_WIDTH, TB_TOTAL_ELEMENTS, TB_NUM_PORTS))
        ::set(null, "uvm_test_top.*", "vif", dut_if);
        run_test("fm_full_test");
    end

    // ---- Hard timeout ----
    initial begin
        #50_000_000;
        `uvm_fatal("FM_TB", "Hard timeout 50ms — simulation hung")
    end

endmodule 