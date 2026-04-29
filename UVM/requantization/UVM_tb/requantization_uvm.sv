/*`include "uvm_macros.svh"
import uvm_pkg::*;

// =========================================================================
// Parameters
// Change these two defines (or pass +define+SYS_ROW=N) to resize the grid.
// =========================================================================
`ifndef SYS_ROW
  `define SYS_ROW 4
`endif
`ifndef SYS_COL
  `define SYS_COL 4
`endif

// =========================================================================
// Interface
// =========================================================================
interface requant_if #(
    parameter SYS_ROW = `SYS_ROW,
    parameter SYS_COL = `SYS_COL
)(
    input logic clk,
    input logic rst
);
    logic        start;
    logic [31:0]          requant_scale;
    logic [5:0]           requant_shift;
    logic signed [7:0]    ZP_next;
    logic signed [31:0]   sys_out     [0:SYS_ROW-1][0:SYS_COL-1];
    logic signed [7:0]    requant_out [0:SYS_ROW-1][0:SYS_COL-1];
endinterface

// =========================================================================
// Sequence Item (parameterized base)
// =========================================================================
class requant_seq_item extends uvm_sequence_item;

    // Flat 1-D arrays — compatible with uvm_field_sarray_int
    rand logic signed [31:0] sys_out_flat    [`SYS_ROW * `SYS_COL];
    rand logic [31:0]        requant_scale;
    rand logic [5:0]         requant_shift;
    rand logic signed [7:0]  ZP_next;

    // Observed output (set by monitor, not randomised)
    logic signed [7:0] requant_out_flat [`SYS_ROW * `SYS_COL];

    `uvm_object_utils_begin(requant_seq_item)
        `uvm_field_sarray_int(sys_out_flat,    UVM_DEFAULT)
        `uvm_field_int       (requant_scale,    UVM_DEFAULT)
        `uvm_field_int       (requant_shift,    UVM_DEFAULT)
        `uvm_field_int       (ZP_next,          UVM_DEFAULT)
        `uvm_field_sarray_int(requant_out_flat, UVM_DEFAULT)
    `uvm_object_utils_end

    // Convenience accessors — readable 2-D indexing over flat storage
    function automatic logic signed [31:0] get_sys_out(int r, int c);
        return sys_out_flat[r * `SYS_COL + c];
    endfunction
    function automatic void set_rq_out(int r, int c, logic signed [7:0] val);
        requant_out_flat[r * `SYS_COL + c] = val;
    endfunction
    function automatic logic signed [7:0] get_rq_out(int r, int c);
        return requant_out_flat[r * `SYS_COL + c];
    endfunction

    // -----------------------------------------------------------------------
    // Constraints
    // -----------------------------------------------------------------------
    // Scale and shift kept modest so the non-saturating window is reachable.
    // Max scale 255, max shift 15 → the safe sys_out window (see below) is
    // always at least ±1, keeping the solver happy.
    constraint c_scale { requant_scale inside {[1:32'h0000_00FF]}; }
    constraint c_shift { requant_shift inside {[0:15]}; }

    // ZP stays well away from ±128 so there is room for the accumulated
    // value to land in [-128,127] without saturating.
    constraint c_ZP_non_sat { ZP_next inside {[-64:64]}; }

    // Default range constraint — kept wide, used for saturation tests.
    // Disabled (soft or inline override) for non-saturating transactions.
    constraint c_sys_out_range {
        foreach (sys_out_flat[i]) {
            sys_out_flat[i] inside {
                [32'sh8000_0000 : 32'sh8000_00FF],
                [32'shFFFF_FF00 : 32'shFFFF_FFFF],
                [32'sh0000_0001 : 32'sh0000_00FF],
                [32'sh7FFF_FF00 : 32'sh7FFF_FFFF]
            };
        }
    }

    // -----------------------------------------------------------------------
    // Non-saturating post-randomize helper
    //
    // Called by the sequence after randomize() to back-calculate the largest
    // sys_out magnitude whose requantised result is guaranteed to stay inside
    // [-128 - ZP, 127 - ZP] before zero-point addition, i.e.:
    //
    //   |shift_res| <= 127 - |ZP|
    //   |(sys_out * scale) >> shift| <= 127 - |ZP|
    //   |sys_out| <= (127 - |ZP|) * 2^shift / scale
    //
    // sys_out is then randomised uniformly within [-limit, +limit].
    // -----------------------------------------------------------------------
    function void set_nonsaturating_inputs();
        longint unsigned limit;
        int zp_abs;
        int headroom;

        zp_abs  = (ZP_next < 0) ? -int'(ZP_next) : int'(ZP_next);
        headroom = 127 - zp_abs;   // how many int8 steps we have from 0

        // limit = headroom << shift / scale  (integer division, conservative)
        limit = (longint'(headroom) <<< requant_shift) / longint'(requant_scale);

        // Clamp to int32 range and ensure at least 1 so randomisation works
        if (limit > 32'h7FFF_FFFE) limit = 32'h7FFF_FFFE;
        if (limit < 1)             limit = 1;

        // Overwrite every sys_out element with a non-zero value in [-limit, +limit].
        // Retry if the draw lands on 0 (probability 1/(2*limit+1), very rare
        // for large limits but guaranteed possible when limit==1).
        foreach (sys_out_flat[i]) begin
            longint signed lo  = -longint'(limit);
            longint signed val;
            int            tries;
            tries = 0;
            do begin
                val = lo + longint'($urandom_range(0, int'(2*limit)));
                tries++;
            end while (val == 0 && tries < 100);
            // If all retries exhausted (limit==1, both candidates are ±1, very
            // unlikely but safe), default to +1.
            if (val == 0) val = 1;
            sys_out_flat[i] = val;
        end
    endfunction

    function new(string name = "REQUANT_SEQ_ITEM"); super.new(name); endfunction
endclass

// =========================================================================
// Sequence
//
// Transaction mix:
//   Phase A — Saturation tests  : extreme sys_out values, standard constraints.
//   Phase B — Non-saturating    : safe sys_out range back-calculated from
//                                 scale/shift/ZP so all outputs land in int8.
//   Phase C — Corner cases      : shift=0, scale=1, ZP boundaries, fully random.
// =========================================================================
class requant_sequence extends uvm_sequence #(requant_seq_item);
    `uvm_object_utils(requant_sequence)
    function new(string name = "REQUANT_SEQUENCE"); super.new(name); endfunction

    virtual task body();
        requant_seq_item item = requant_seq_item::type_id::create("item");

        // ------------------------------------------------------------------
        // Phase A: Saturation transactions (c_sys_out_range active)
        // ------------------------------------------------------------------
        repeat(4) begin
            start_item(item);
            if (!item.randomize())
                `uvm_error("SEQ", "Randomization failed (saturation phase)")
            finish_item(item);
        end

        // ------------------------------------------------------------------
        // Phase B: Non-saturating transactions
        // Disable c_sys_out_range before randomize() — constraint_mode()
        // must be called on the object directly, never inside a with{} block.
        // ------------------------------------------------------------------
        repeat(16) begin
            start_item(item);
            item.c_sys_out_range.constraint_mode(0);
            if (!item.randomize())
                `uvm_error("SEQ", "Randomization failed (non-sat phase)")
            item.c_sys_out_range.constraint_mode(1);
            item.set_nonsaturating_inputs();
            finish_item(item);
        end

        // ------------------------------------------------------------------
        // Phase C: Corner cases (non-saturating inputs)
        // ------------------------------------------------------------------

        // shift = 0 — rounding bias is zero, output = (sys_out * scale) + ZP
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { requant_shift == 0; })
            `uvm_error("SEQ", "Randomization failed (shift=0 corner)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // scale = 1 — near-identity scaling
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { requant_scale == 1; })
            `uvm_error("SEQ", "Randomization failed (scale=1 corner)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ZP = 0 — zero-point adds nothing, clean pipeline check
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { ZP_next == 8'sd0; })
            `uvm_error("SEQ", "Randomization failed (ZP=0 corner)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ZP = +63 — positive zero-point, still non-saturating
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { ZP_next == 8'sd63; })
            `uvm_error("SEQ", "Randomization failed (ZP=63 corner)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ZP = -63 — negative zero-point, still non-saturating
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { ZP_next == -8'sd63; })
            `uvm_error("SEQ", "Randomization failed (ZP=-63 corner)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // shift = 15 — maximum right-shift
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { requant_shift == 15; })
            `uvm_error("SEQ", "Randomization failed (shift=15 corner)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // All-zero inputs — output must equal ZP (clamped); ZP=0 so output=0
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { ZP_next == 8'sd0; })
            `uvm_error("SEQ", "Randomization failed (all-zero corner)")
        item.c_sys_out_range.constraint_mode(1);
        foreach (item.sys_out_flat[i]) item.sys_out_flat[i] = 32'sd0;
        finish_item(item);

    endtask
endclass

// =========================================================================
// Driver
// =========================================================================
class requant_driver extends uvm_driver #(requant_seq_item);
    `uvm_component_utils(requant_driver)

    virtual requant_if #(`SYS_ROW, `SYS_COL) vif;
    uvm_analysis_port #(requant_seq_item) drv_to_scb;

    localparam int PIPE_DEPTH = 5;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        drv_to_scb = new("drv_to_scb", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual requant_if #(`SYS_ROW, `SYS_COL))::get(
                this, "", "vif", vif))
            `uvm_fatal("DRV", "No interface found in config DB")
    endfunction

    virtual task run_phase(uvm_phase phase);
        vif.start         <= 0;
        vif.requant_scale <= 32'd1;
        vif.requant_shift <= 6'd0;
        vif.ZP_next       <= 8'd0;
        for (int r = 0; r < `SYS_ROW; r++)
            for (int c = 0; c < `SYS_COL; c++)
                vif.sys_out[r][c] <= 32'd0;

        @(negedge vif.rst);
        @(posedge vif.clk);

        forever begin
            requant_seq_item req;
            seq_item_port.get_next_item(req);

            // Send reference copy to scoreboard before driving DUT
            drv_to_scb.write(req);

            // Drive DUT inputs (flat → 2-D interface)
            vif.requant_scale <= req.requant_scale;
            vif.requant_shift <= req.requant_shift;
            vif.ZP_next       <= req.ZP_next;
            for (int r = 0; r < `SYS_ROW; r++)
                for (int c = 0; c < `SYS_COL; c++)
                    vif.sys_out[r][c] <= req.get_sys_out(r, c);

            // Assert start for one cycle
            @(posedge vif.clk);
            vif.start <= 1;
            @(posedge vif.clk);
            vif.start <= 0;

            // Wait for pipeline to flush
            repeat(PIPE_DEPTH) @(posedge vif.clk);

            seq_item_port.item_done();
        end
    endtask
endclass

// =========================================================================
// Monitor
// =========================================================================
class requant_monitor extends uvm_monitor;
    `uvm_component_utils(requant_monitor)

    virtual requant_if #(`SYS_ROW, `SYS_COL) vif;
    uvm_analysis_port #(requant_seq_item) mon_to_scb;

    localparam int PIPE_DEPTH = 5;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        mon_to_scb = new("mon_to_scb", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        void'(uvm_config_db #(virtual requant_if #(`SYS_ROW, `SYS_COL))::get(
                this, "", "vif", vif));
    endfunction

    virtual task run_phase(uvm_phase phase);
        forever begin
            @(posedge vif.clk iff vif.start === 1'b1);
            repeat(PIPE_DEPTH) @(posedge vif.clk);

            begin
                requant_seq_item item = requant_seq_item::type_id::create("mon_item");
                for (int r = 0; r < `SYS_ROW; r++)
                    for (int c = 0; c < `SYS_COL; c++)
                        item.set_rq_out(r, c, vif.requant_out[r][c]);
                mon_to_scb.write(item);
            end
        end
    endtask
endclass

// =========================================================================
// Scoreboard
// =========================================================================
`uvm_analysis_imp_decl(_drv)
`uvm_analysis_imp_decl(_mon)

class requant_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(requant_scoreboard)

    uvm_analysis_imp_drv #(requant_seq_item, requant_scoreboard) drv_exp;
    uvm_analysis_imp_mon #(requant_seq_item, requant_scoreboard) mon_exp;

    requant_seq_item ref_q[$];
    int match = 0, fail = 0;


    longint signed prev_mult_res [`SYS_ROW * `SYS_COL];

    function new(string name, uvm_component parent);
        super.new(name, parent);
        drv_exp = new("drv_exp", this);
        mon_exp = new("mon_exp", this);
        foreach (prev_mult_res[i]) prev_mult_res[i] = 0;
    endfunction

    // Driver port — push cloned stimulus onto reference queue
    function void write_drv(requant_seq_item data);
        requant_seq_item clone;
        $cast(clone, data.clone());
        ref_q.push_back(clone);
    endfunction

    // Monitor port — run golden model and compare
    //
    // Accurate pipeline (single always_ff, non-blocking assignments):
    //   Stage 1 : mult_res_reg   <= buffer * scale              (current)
    //             round_bias_reg <= f(mult_res_reg_PREV)        (PREVIOUS!)
    //             shift_reg2     <= shift_reg
    //   Stage 2 : shift_res_reg  <= (mult_res_reg + round_bias_reg) >>> shift_reg2
    //   Stage 3 : final_res_reg  <= shift_res_reg + ZP
    //   Stage 4 : requant_out    <= saturate(final_res_reg)
    function void write_mon(requant_seq_item data);
        if (ref_q.size() == 0) begin
            `uvm_error("SCB", "Monitor output received with empty reference queue")
            return;
        end

        begin
            requant_seq_item inp = ref_q.pop_front();

            for (int r = 0; r < `SYS_ROW; r++) begin
                for (int c = 0; c < `SYS_COL; c++) begin
                    int             idx = r * `SYS_COL + c;
                    longint signed  mult_res;
                    longint signed  round_bias;
                    int    signed   shift_res;
                    int    signed   final_res;
                    logic  signed [7:0] expected;

                    // Stage 1: current multiply result
                    mult_res = longint'(inp.get_sys_out(r, c))
                             * longint'({1'b0, inp.requant_scale});

                    // Stage 2: bias sign uses PREVIOUS mult_res_reg value
                    if (inp.requant_shift == 0) begin
                        round_bias = 0;
                    end else begin
                        if (prev_mult_res[idx] >= 0)
                            round_bias = (64'sd1 <<< (inp.requant_shift - 1));
                        else
                            round_bias = (64'sd1 <<< (inp.requant_shift - 1)) - 64'sd1;
                    end

                    // Update shadow register for next transaction
                    prev_mult_res[idx] = mult_res;

                    // Stage 3: arithmetic right-shift
                    shift_res = int'((mult_res + round_bias) >>> inp.requant_shift);

                    // Stage 4: add zero-point
                    final_res = shift_res + int'(inp.ZP_next);

                    // Stage 5: saturate
                    if      (final_res > 32'sd127)  expected =  8'sd127;
                    else if (final_res < -32'sd128)  expected = -8'sd128;
                    else                              expected = final_res[7:0];

                    if (data.get_rq_out(r, c) === expected) begin
                        `uvm_info("SCB",
                            $sformatf("MATCH [%0d][%0d] scale=%0d shift=%0d zp=%0d | in=%0d exp=%0d obs=%0d",
                                r, c, inp.requant_scale, inp.requant_shift, inp.ZP_next,
                                inp.get_sys_out(r,c), expected, data.get_rq_out(r,c)),
                            UVM_LOW)
                        match++;
                    end else begin
                        `uvm_error("SCB",
                            $sformatf("FAIL  [%0d][%0d] scale=%0d shift=%0d zp=%0d | in=%0d exp=%0d obs=%0d",
                                r, c, inp.requant_scale, inp.requant_shift, inp.ZP_next,
                                inp.get_sys_out(r,c), expected, data.get_rq_out(r,c)))
                        fail++;
                    end
                end
            end
        end
    endfunction

    function void report_phase(uvm_phase phase);
        $display("\n\t================================");
        $display("\t  Scoreboard Summary");
        $display("\t  Total checks : %0d", match + fail);
        $display("\t  Passed       : %0d", match);
        $display("\t  Failed       : %0d", fail);
        $display("\t================================");
        if (fail == 0 && match > 0)
            $display("\n\n\t----------------------------\n\t---   STATUS: UVM PASS   ---\n\t----------------------------\n");
        else
            $display("\n\n\t----------------------------\n\t---   STATUS: UVM FAIL   ---\n\t----------------------------\n");
    endfunction
endclass

// =========================================================================
// Agent
// =========================================================================
class requant_agent extends uvm_agent;
    `uvm_component_utils(requant_agent)

    requant_driver  drv;
    requant_monitor mon;
    uvm_sequencer #(requant_seq_item) sqr;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    virtual function void build_phase(uvm_phase phase);
        drv = requant_driver ::type_id::create("drv", this);
        mon = requant_monitor::type_id::create("mon", this);
        sqr = uvm_sequencer#(requant_seq_item)::type_id::create("sqr", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass

// =========================================================================
// Environment
// =========================================================================
class requant_env extends uvm_env;
    `uvm_component_utils(requant_env)

    requant_agent      agt;
    requant_scoreboard scb;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    virtual function void build_phase(uvm_phase phase);
        agt = requant_agent     ::type_id::create("agt", this);
        scb = requant_scoreboard::type_id::create("scb", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        agt.mon.mon_to_scb.connect(scb.mon_exp);
        agt.drv.drv_to_scb.connect(scb.drv_exp);
    endfunction
endclass

// =========================================================================
// Test
// =========================================================================
class requant_test extends uvm_test;
    `uvm_component_utils(requant_test)

    requant_env env;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    virtual function void build_phase(uvm_phase phase);
        env = requant_env::type_id::create("env", this);
    endfunction

    virtual task run_phase(uvm_phase phase);
        requant_sequence seq = requant_sequence::type_id::create("seq");
        phase.raise_objection(this);
        seq.start(env.agt.sqr);
        #500;
        phase.drop_objection(this);
    endtask
endclass

// =========================================================================
// Top Module
// =========================================================================
module tb_top;

    localparam int SYS_ROW = `SYS_ROW;
    localparam int SYS_COL = `SYS_COL;

    logic clk = 0;
    logic rst;

    always #5 clk = ~clk;
    initial begin rst = 1; #25 rst = 0; end

    requant_if #(SYS_ROW, SYS_COL) r_if (clk, rst);

    requantization_block #(
        .sys_row (SYS_ROW),
        .sys_col (SYS_COL)
    ) dut (
        .clk          (r_if.clk),
        .rst          (r_if.rst),
        .start        (r_if.start),
        .requant_scale(r_if.requant_scale),
        .requant_shift(r_if.requant_shift),
        .ZP_next      (r_if.ZP_next),
        .sys_out      (r_if.sys_out),
        .requant_out  (r_if.requant_out)
    );

    initial begin
        uvm_config_db #(virtual requant_if #(SYS_ROW, SYS_COL))::set(
            null, "*", "vif", r_if);
        run_test("requant_test");
    end

endmodule*/
`include "uvm_macros.svh"
import uvm_pkg::*;

// =========================================================================
// Parameters
// Change these two defines (or pass +define+SYS_ROW=N) to resize the grid.
// =========================================================================
`ifndef SYS_ROW
  `define SYS_ROW 4
`endif
`ifndef SYS_COL
  `define SYS_COL 4
`endif

// =========================================================================
// Interface
// =========================================================================
interface requant_if #(
    parameter SYS_ROW = `SYS_ROW,
    parameter SYS_COL = `SYS_COL
)(
    input logic clk,
    input logic rst
);
    logic        start;
    logic [31:0]          requant_scale;
    logic [5:0]           requant_shift;
    logic signed [7:0]    ZP_next;
    logic signed [31:0]   sys_out     [0:SYS_ROW-1][0:SYS_COL-1];
    logic signed [7:0]    requant_out [0:SYS_ROW-1][0:SYS_COL-1];
endinterface

// =========================================================================
// Sequence Item (parameterized base)
// =========================================================================
class requant_seq_item extends uvm_sequence_item;

    // Flat 1-D arrays — compatible with uvm_field_sarray_int
    rand logic signed [31:0] sys_out_flat    [`SYS_ROW * `SYS_COL];
    rand logic [31:0]        requant_scale;
    rand logic [5:0]         requant_shift;
    rand logic signed [7:0]  ZP_next;

    // Observed output (set by monitor, not randomised)
    logic signed [7:0] requant_out_flat [`SYS_ROW * `SYS_COL];

    `uvm_object_utils_begin(requant_seq_item)
        `uvm_field_sarray_int(sys_out_flat,    UVM_DEFAULT)
        `uvm_field_int       (requant_scale,    UVM_DEFAULT)
        `uvm_field_int       (requant_shift,    UVM_DEFAULT)
        `uvm_field_int       (ZP_next,          UVM_DEFAULT)
        `uvm_field_sarray_int(requant_out_flat, UVM_DEFAULT)
    `uvm_object_utils_end

    // Convenience accessors — readable 2-D indexing over flat storage
    function automatic logic signed [31:0] get_sys_out(int r, int c);
        return sys_out_flat[r * `SYS_COL + c];
    endfunction
    function automatic void set_rq_out(int r, int c, logic signed [7:0] val);
        requant_out_flat[r * `SYS_COL + c] = val;
    endfunction
    function automatic logic signed [7:0] get_rq_out(int r, int c);
        return requant_out_flat[r * `SYS_COL + c];
    endfunction

    // -----------------------------------------------------------------------
    // Constraints
    // -----------------------------------------------------------------------
    constraint c_scale { requant_scale inside {[1:32'h0000_00FF]}; }
    constraint c_shift { requant_shift inside {[0:15]}; }
    constraint c_ZP_non_sat { ZP_next inside {[-64:64]}; }
    constraint c_sys_out_range {
        foreach (sys_out_flat[i]) {
            sys_out_flat[i] inside {
                [32'sh8000_0000 : 32'sh8000_00FF],
                [32'shFFFF_FF00 : 32'shFFFF_FFFF],
                [32'sh0000_0001 : 32'sh0000_00FF],
                [32'sh7FFF_FF00 : 32'sh7FFF_FFFF]
            };
        }
    }

    // -----------------------------------------------------------------------
    // Non-saturating post-randomize helper
    // -----------------------------------------------------------------------
    function void set_nonsaturating_inputs();
        longint unsigned limit;
        int zp_abs;
        int headroom;

        zp_abs   = (ZP_next < 0) ? -int'(ZP_next) : int'(ZP_next);
        headroom = 127 - zp_abs;

        limit = (longint'(headroom) <<< requant_shift) / longint'(requant_scale);

        if (limit > 32'h7FFF_FFFE) limit = 32'h7FFF_FFFE;
        if (limit < 1)             limit = 1;

        foreach (sys_out_flat[i]) begin
            longint signed lo  = -longint'(limit);
            longint signed val;
            int            tries;
            tries = 0;
            do begin
                val = lo + longint'($urandom_range(0, int'(2*limit)));
                tries++;
            end while (val == 0 && tries < 100);
            if (val == 0) val = 1;
            sys_out_flat[i] = val;
        end
    endfunction

    function new(string name = "REQUANT_SEQ_ITEM"); super.new(name); endfunction
endclass

// =========================================================================
// Sequence
//
// Transaction mix:
//   Phase A — Saturation tests  : extreme sys_out values, standard constraints.
//   Phase B — Non-saturating    : safe sys_out range back-calculated from
//                                 scale/shift/ZP so all outputs land in int8.
//   Phase C — Corner cases      : shift=0, scale=1, ZP boundaries, fully random.
// =========================================================================
class requant_sequence extends uvm_sequence #(requant_seq_item);
    `uvm_object_utils(requant_sequence)
    function new(string name = "REQUANT_SEQUENCE"); super.new(name); endfunction

    virtual task body();
        requant_seq_item item = requant_seq_item::type_id::create("item");

        // ------------------------------------------------------------------
        // Phase A: Saturation transactions (c_sys_out_range active)
        // ------------------------------------------------------------------
        repeat(4) begin
            start_item(item);
            if (!item.randomize())
                `uvm_error("SEQ", "Randomization failed (saturation phase)")
            finish_item(item);
        end

        // ------------------------------------------------------------------
        // Phase B: Non-saturating transactions
        // ------------------------------------------------------------------
        repeat(16) begin
            start_item(item);
            item.c_sys_out_range.constraint_mode(0);
            if (!item.randomize())
                `uvm_error("SEQ", "Randomization failed (non-sat phase)")
            item.c_sys_out_range.constraint_mode(1);
            item.set_nonsaturating_inputs();
            finish_item(item);
        end

        // ------------------------------------------------------------------
        // Phase C: Corner cases (non-saturating inputs)
        // ------------------------------------------------------------------

        // shift = 0
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { requant_shift == 0; })
            `uvm_error("SEQ", "Randomization failed (shift=0 corner)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // scale = 1
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { requant_scale == 1; })
            `uvm_error("SEQ", "Randomization failed (scale=1 corner)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ZP = 0
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { ZP_next == 8'sd0; })
            `uvm_error("SEQ", "Randomization failed (ZP=0 corner)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ZP = +63
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { ZP_next == 8'sd63; })
            `uvm_error("SEQ", "Randomization failed (ZP=63 corner)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ZP = -63
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { ZP_next == -8'sd63; })
            `uvm_error("SEQ", "Randomization failed (ZP=-63 corner)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // shift = 15
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { requant_shift == 15; })
            `uvm_error("SEQ", "Randomization failed (shift=15 corner)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // All-zero inputs
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with { ZP_next == 8'sd0; })
            `uvm_error("SEQ", "Randomization failed (all-zero corner)")
        item.c_sys_out_range.constraint_mode(1);
        foreach (item.sys_out_flat[i]) item.sys_out_flat[i] = 32'sd0;
        finish_item(item);

    endtask
endclass

// =========================================================================
// Directed Closing Sequence
//
// Targets the 6 cross bins that random + corner phases cannot guarantee:
//
// cx_shift_scale gaps (4 bins):
//   shift_zero × scale_low  : shift=0,  scale in [2:127]
//   shift_zero × scale_high : shift=0,  scale in [128:255]
//   shift_max  × scale_low  : shift=15, scale in [2:127]
//   shift_max  × scale_high : shift=15, scale in [128:255]
//
// cx_zp_sat gaps (2 bins):
//   zp_neg × pos_sat : ZP < 0, INT32_MAX inputs  → clamp to +127
//   zp_pos × neg_sat : ZP > 0, INT32_MIN inputs  → clamp to -128
// =========================================================================
class requant_directed_sequence extends uvm_sequence #(requant_seq_item);
    `uvm_object_utils(requant_directed_sequence)
    function new(string name = "REQUANT_DIRECTED_SEQ"); super.new(name); endfunction

    virtual task body();
        requant_seq_item item;

        // cx_shift_scale: shift=0 x scale_low
        item = requant_seq_item::type_id::create("dir_s0_slow");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                requant_shift == 0;
                requant_scale inside {[2:127]};
            })
            `uvm_error("DIR_SEQ", "Randomization failed (shift=0 scale_low)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // cx_shift_scale: shift=0 x scale_high
        item = requant_seq_item::type_id::create("dir_s0_shigh");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                requant_shift == 0;
                requant_scale inside {[128:255]};
            })
            `uvm_error("DIR_SEQ", "Randomization failed (shift=0 scale_high)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // cx_shift_scale: shift=15 x scale_low
        item = requant_seq_item::type_id::create("dir_s15_slow");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                requant_shift == 15;
                requant_scale inside {[2:127]};
            })
            `uvm_error("DIR_SEQ", "Randomization failed (shift=15 scale_low)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // cx_shift_scale: shift=15 x scale_high
        item = requant_seq_item::type_id::create("dir_s15_shigh");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                requant_shift == 15;
                requant_scale inside {[128:255]};
            })
            `uvm_error("DIR_SEQ", "Randomization failed (shift=15 scale_high)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // cx_zp_sat: zp_neg x pos_sat
        // ZP < 0, all sys_out = INT32_MAX so multiply overflows → clamp +127
        item = requant_seq_item::type_id::create("dir_zpneg_psat");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                ZP_next        < 0;
                requant_scale inside {[1:255]};
                requant_shift inside {[0:15]};
            })
            `uvm_error("DIR_SEQ", "Randomization failed (zp_neg pos_sat)")
        item.c_sys_out_range.constraint_mode(1);
        foreach (item.sys_out_flat[i])
            item.sys_out_flat[i] = 32'sh7FFF_FFFF;
        finish_item(item);

        // cx_zp_sat: zp_pos x neg_sat
        // ZP > 0, all sys_out = INT32_MIN so multiply overflows → clamp -128
        item = requant_seq_item::type_id::create("dir_zppos_nsat");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                ZP_next        > 0;
                requant_scale inside {[1:255]};
                requant_shift inside {[0:15]};
            })
            `uvm_error("DIR_SEQ", "Randomization failed (zp_pos neg_sat)")
        item.c_sys_out_range.constraint_mode(1);
        foreach (item.sys_out_flat[i])
            item.sys_out_flat[i] = 32'sh8000_0000;
        finish_item(item);

    endtask
endclass

// =========================================================================
// Coverage-Closing Sequence
//
// Targets the remaining cx_zp_sat and cx_shift_scale cross bins that
// neither the random sequence nor the directed sequence can guarantee:
//
// cx_zp_sat remaining gaps (4 bins):
//   zp_zero × pos_sat : ZP=0, large positive sys_out  → clamp to +127
//   zp_zero × neg_sat : ZP=0, large negative sys_out  → clamp to -128
//   zp_neg  × no_sat  : ZP < 0, small sys_out         → no saturation
//   zp_pos  × no_sat  : ZP > 0, small sys_out         → no saturation
//
// cx_shift_scale remaining gaps (6 bins):
//   shift_low  × scale_min  : shift in [1:7],  scale=1
//   shift_low  × scale_low  : shift in [1:7],  scale in [2:127]
//   shift_low  × scale_high : shift in [1:7],  scale in [128:255]
//   shift_mid  × scale_min  : shift in [8:14], scale=1
//   shift_mid  × scale_low  : shift in [8:14], scale in [2:127]
//   shift_mid  × scale_high : shift in [8:14], scale in [128:255]
//
// The 2 remaining cx_shift_scale bins (shift_zero×scale_min and
// shift_max×scale_min) are also added for completeness.
// =========================================================================
class requant_coverage_closing_sequence extends uvm_sequence #(requant_seq_item);
    `uvm_object_utils(requant_coverage_closing_sequence)
    function new(string name = "REQUANT_COV_CLOSING_SEQ"); super.new(name); endfunction

    virtual task body();
        requant_seq_item item;

        // ------------------------------------------------------------------
        // cx_zp_sat: zp_zero × pos_sat
        // ZP=0, INT32_MAX inputs → scale*sys_out overflows → clamp +127
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_zp0_psat");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                ZP_next       == 8'sd0;
                requant_scale inside {[1:255]};
                requant_shift inside {[0:15]};
            })
            `uvm_error("COV_SEQ", "Randomization failed (zp_zero pos_sat)")
        item.c_sys_out_range.constraint_mode(1);
        foreach (item.sys_out_flat[i])
            item.sys_out_flat[i] = 32'sh7FFF_FFFF;
        finish_item(item);

        // ------------------------------------------------------------------
        // cx_zp_sat: zp_zero × neg_sat
        // ZP=0, INT32_MIN inputs → scale*sys_out overflows → clamp -128
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_zp0_nsat");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                ZP_next       == 8'sd0;
                requant_scale inside {[1:255]};
                requant_shift inside {[0:15]};
            })
            `uvm_error("COV_SEQ", "Randomization failed (zp_zero neg_sat)")
        item.c_sys_out_range.constraint_mode(1);
        foreach (item.sys_out_flat[i])
            item.sys_out_flat[i] = 32'sh8000_0000;
        finish_item(item);

        // ------------------------------------------------------------------
        // cx_zp_sat: zp_neg × no_sat
        // ZP < 0, small positive sys_out, small scale/shift → no saturation
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_zpneg_nosat");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                ZP_next       inside {[-10:-1]};
                requant_scale == 1;
                requant_shift inside {[1:7]};
            })
            `uvm_error("COV_SEQ", "Randomization failed (zp_neg no_sat)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ------------------------------------------------------------------
        // cx_zp_sat: zp_pos × no_sat
        // ZP > 0, small negative sys_out, small scale/shift → no saturation
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_zppos_nosat");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                ZP_next       inside {[1:10]};
                requant_scale == 1;
                requant_shift inside {[1:7]};
            })
            `uvm_error("COV_SEQ", "Randomization failed (zp_pos no_sat)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ------------------------------------------------------------------
        // cx_shift_scale: shift_zero × scale_min (shift=0, scale=1)
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_s0_smin");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                requant_shift == 0;
                requant_scale == 1;
            })
            `uvm_error("COV_SEQ", "Randomization failed (shift=0 scale=1)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ------------------------------------------------------------------
        // cx_shift_scale: shift_low × scale_min (shift in [1:7], scale=1)
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_slow_smin");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                requant_shift inside {[1:7]};
                requant_scale == 1;
            })
            `uvm_error("COV_SEQ", "Randomization failed (shift_low scale_min)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ------------------------------------------------------------------
        // cx_shift_scale: shift_low × scale_low (shift in [1:7], scale in [2:127])
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_slow_slow");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                requant_shift inside {[1:7]};
                requant_scale inside {[2:127]};
            })
            `uvm_error("COV_SEQ", "Randomization failed (shift_low scale_low)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ------------------------------------------------------------------
        // cx_shift_scale: shift_low × scale_high (shift in [1:7], scale in [128:255])
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_slow_shigh");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                requant_shift inside {[1:7]};
                requant_scale inside {[128:255]};
            })
            `uvm_error("COV_SEQ", "Randomization failed (shift_low scale_high)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ------------------------------------------------------------------
        // cx_shift_scale: shift_mid × scale_min (shift in [8:14], scale=1)
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_smid_smin");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                requant_shift inside {[8:14]};
                requant_scale == 1;
            })
            `uvm_error("COV_SEQ", "Randomization failed (shift_mid scale_min)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ------------------------------------------------------------------
        // cx_shift_scale: shift_mid × scale_low (shift in [8:14], scale in [2:127])
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_smid_slow");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                requant_shift inside {[8:14]};
                requant_scale inside {[2:127]};
            })
            `uvm_error("COV_SEQ", "Randomization failed (shift_mid scale_low)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ------------------------------------------------------------------
        // cx_shift_scale: shift_mid × scale_high (shift in [8:14], scale in [128:255])
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_smid_shigh");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                requant_shift inside {[8:14]};
                requant_scale inside {[128:255]};
            })
            `uvm_error("COV_SEQ", "Randomization failed (shift_mid scale_high)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ------------------------------------------------------------------
        // cx_shift_scale: shift_max × scale_min (shift=15, scale=1)
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_smax_smin");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                requant_shift == 15;
                requant_scale == 1;
            })
            `uvm_error("COV_SEQ", "Randomization failed (shift_max scale_min)")
        item.c_sys_out_range.constraint_mode(1);
        item.set_nonsaturating_inputs();
        finish_item(item);

        // ------------------------------------------------------------------
        // Bonus: sweep all 3 ZP categories × all 3 saturation outcomes
        // with mixed-sign sys_out to ensure cp_input_sign is fully covered
        // across all contexts.
        //
        // zp_neg × no_sat with negative inputs (ensure neg_input × no_sat)
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_zpneg_nosat_neginput");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                ZP_next       inside {[-5:-1]};
                requant_scale == 1;
                requant_shift inside {[1:4]};
            })
            `uvm_error("COV_SEQ", "Randomization failed (zp_neg no_sat neg_input)")
        item.c_sys_out_range.constraint_mode(1);
        // Force all inputs negative and small enough not to saturate
        foreach (item.sys_out_flat[i])
            item.sys_out_flat[i] = -32'sd5;
        finish_item(item);

        // ------------------------------------------------------------------
        // zp_pos × no_sat with positive inputs (ensure pos_input × no_sat)
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_zppos_nosat_posinput");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                ZP_next       inside {[1:5]};
                requant_scale == 1;
                requant_shift inside {[1:4]};
            })
            `uvm_error("COV_SEQ", "Randomization failed (zp_pos no_sat pos_input)")
        item.c_sys_out_range.constraint_mode(1);
        // Force all inputs positive and small enough not to saturate
        foreach (item.sys_out_flat[i])
            item.sys_out_flat[i] = 32'sd5;
        finish_item(item);

        // ------------------------------------------------------------------
        // zp_zero × no_sat with both signs in the same transaction
        // sys_out_flat is half positive / half negative, scale=1, small shift
        // ------------------------------------------------------------------
        item = requant_seq_item::type_id::create("cov_zp0_nosat_mixed");
        start_item(item);
        item.c_sys_out_range.constraint_mode(0);
        if (!item.randomize() with {
                ZP_next       == 8'sd0;
                requant_scale == 1;
                requant_shift inside {[1:4]};
            })
            `uvm_error("COV_SEQ", "Randomization failed (zp_zero no_sat mixed)")
        item.c_sys_out_range.constraint_mode(1);
        foreach (item.sys_out_flat[i])
            item.sys_out_flat[i] = (i % 2 == 0) ? 32'sd10 : -32'sd10;
        finish_item(item);

    endtask
endclass

// =========================================================================
// Driver
// =========================================================================
class requant_driver extends uvm_driver #(requant_seq_item);
    `uvm_component_utils(requant_driver)

    virtual requant_if #(`SYS_ROW, `SYS_COL) vif;
    uvm_analysis_port #(requant_seq_item) drv_to_scb;

    localparam int PIPE_DEPTH = 5;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        drv_to_scb = new("drv_to_scb", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual requant_if #(`SYS_ROW, `SYS_COL))::get(
                this, "", "vif", vif))
            `uvm_fatal("DRV", "No interface found in config DB")
    endfunction

    virtual task run_phase(uvm_phase phase);
        vif.start         <= 0;
        vif.requant_scale <= 32'd1;
        vif.requant_shift <= 6'd0;
        vif.ZP_next       <= 8'd0;
        for (int r = 0; r < `SYS_ROW; r++)
            for (int c = 0; c < `SYS_COL; c++)
                vif.sys_out[r][c] <= 32'd0;

        @(negedge vif.rst);
        @(posedge vif.clk);

        forever begin
            requant_seq_item req;
            seq_item_port.get_next_item(req);

            drv_to_scb.write(req);

            vif.requant_scale <= req.requant_scale;
            vif.requant_shift <= req.requant_shift;
            vif.ZP_next       <= req.ZP_next;
            for (int r = 0; r < `SYS_ROW; r++)
                for (int c = 0; c < `SYS_COL; c++)
                    vif.sys_out[r][c] <= req.get_sys_out(r, c);

            @(posedge vif.clk);
            vif.start <= 1;
            @(posedge vif.clk);
            vif.start <= 0;

            repeat(PIPE_DEPTH) @(posedge vif.clk);

            seq_item_port.item_done();
        end
    endtask
endclass

// =========================================================================
// Monitor
// =========================================================================
class requant_monitor extends uvm_monitor;
    `uvm_component_utils(requant_monitor)

    virtual requant_if #(`SYS_ROW, `SYS_COL) vif;
    uvm_analysis_port #(requant_seq_item) mon_to_scb;

    localparam int PIPE_DEPTH = 5;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        mon_to_scb = new("mon_to_scb", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        void'(uvm_config_db #(virtual requant_if #(`SYS_ROW, `SYS_COL))::get(
                this, "", "vif", vif));
    endfunction

    virtual task run_phase(uvm_phase phase);
        forever begin
            @(posedge vif.clk iff vif.start === 1'b1);
            repeat(PIPE_DEPTH) @(posedge vif.clk);

            begin
                requant_seq_item item = requant_seq_item::type_id::create("mon_item");
                for (int r = 0; r < `SYS_ROW; r++)
                    for (int c = 0; c < `SYS_COL; c++)
                        item.set_rq_out(r, c, vif.requant_out[r][c]);
                mon_to_scb.write(item);
            end
        end
    endtask
endclass

// =========================================================================
// Scoreboard
// =========================================================================
`uvm_analysis_imp_decl(_drv)
`uvm_analysis_imp_decl(_mon)

class requant_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(requant_scoreboard)

    uvm_analysis_imp_drv #(requant_seq_item, requant_scoreboard) drv_exp;
    uvm_analysis_imp_mon #(requant_seq_item, requant_scoreboard) mon_exp;

    requant_seq_item ref_q[$];
    int match = 0, fail = 0;

    longint signed prev_mult_res [`SYS_ROW * `SYS_COL];

    function new(string name, uvm_component parent);
        super.new(name, parent);
        drv_exp = new("drv_exp", this);
        mon_exp = new("mon_exp", this);
        foreach (prev_mult_res[i]) prev_mult_res[i] = 0;
    endfunction

    function void write_drv(requant_seq_item data);
        requant_seq_item clone;
        $cast(clone, data.clone());
        ref_q.push_back(clone);
    endfunction

    function void write_mon(requant_seq_item data);
        if (ref_q.size() == 0) begin
            `uvm_error("SCB", "Monitor output received with empty reference queue")
            return;
        end

        begin
            requant_seq_item inp = ref_q.pop_front();

            for (int r = 0; r < `SYS_ROW; r++) begin
                for (int c = 0; c < `SYS_COL; c++) begin
                    int             idx = r * `SYS_COL + c;
                    longint signed  mult_res;
                    longint signed  round_bias;
                    int    signed   shift_res;
                    int    signed   final_res;
                    logic  signed [7:0] expected;

                    mult_res = longint'(inp.get_sys_out(r, c))
                             * longint'({1'b0, inp.requant_scale});

                    if (inp.requant_shift == 0) begin
                        round_bias = 0;
                    end else begin
                        if (prev_mult_res[idx] >= 0)
                            round_bias = (64'sd1 <<< (inp.requant_shift - 1));
                        else
                            round_bias = (64'sd1 <<< (inp.requant_shift - 1)) - 64'sd1;
                    end

                    prev_mult_res[idx] = mult_res;

                    shift_res = int'((mult_res + round_bias) >>> inp.requant_shift);
                    final_res = shift_res + int'(inp.ZP_next);

                    if      (final_res > 32'sd127)  expected =  8'sd127;
                    else if (final_res < -32'sd128)  expected = -8'sd128;
                    else                              expected = final_res[7:0];

                    if (data.get_rq_out(r, c) === expected) begin
                        `uvm_info("SCB",
                            $sformatf("MATCH [%0d][%0d] scale=%0d shift=%0d zp=%0d | in=%0d exp=%0d obs=%0d",
                                r, c, inp.requant_scale, inp.requant_shift, inp.ZP_next,
                                inp.get_sys_out(r,c), expected, data.get_rq_out(r,c)),
                            UVM_LOW)
                        match++;
                    end else begin
                        `uvm_error("SCB",
                            $sformatf("FAIL  [%0d][%0d] scale=%0d shift=%0d zp=%0d | in=%0d exp=%0d obs=%0d",
                                r, c, inp.requant_scale, inp.requant_shift, inp.ZP_next,
                                inp.get_sys_out(r,c), expected, data.get_rq_out(r,c)))
                        fail++;
                    end
                end
            end
        end
    endfunction

    function void report_phase(uvm_phase phase);
        $display("\n\t================================");
        $display("\t  Scoreboard Summary");
        $display("\t  Total checks : %0d", match + fail);
        $display("\t  Passed       : %0d", match);
        $display("\t  Failed       : %0d", fail);
        $display("\t================================");
        if (fail == 0 && match > 0)
            $display("\n\n\t----------------------------\n\t---   STATUS: UVM PASS   ---\n\t----------------------------\n");
        else
            $display("\n\n\t----------------------------\n\t---   STATUS: UVM FAIL   ---\n\t----------------------------\n");
    endfunction
endclass

// =========================================================================
// Coverage Subscriber
//
// Architecture: unified sampling
// -----------------------------------------------------------------------
// The previous split-sampling design had a race: write_drv2 sampled
// cov_sat_cat=0 (its reset value) because the output hadn't arrived yet,
// and write_mon2 sampled stale stimulus fields already overwritten by the
// next transaction's write_drv2.  Result: cross bins that span stimulus +
// response were never correctly populated.
//
// Fix: write_drv2 clones and queues the stimulus item.  write_mon2 pops
// the matching stimulus from that queue so both sides are present at the
// same instant, then does one unified sample() per grid element with all
// five sampling variables correctly set.
//
// Coverpoints:
//   cp_shift      — shift ∈ {0} / {1-7} / {8-14} / {15}
//   cp_scale      — scale = 1 (min) / 2-127 (low) / 128-255 (high)
//   cp_zp         — ZP_next < 0 / == 0 / > 0
//   cp_sat        — output = no_sat / pos_sat (+127) / neg_sat (-128)
//   cp_input_sign — sys_out element positive / negative
//
// Crosses:
//   cx_shift_scale — shift bucket × scale category  (12 bins)
//   cx_zp_sat      — ZP region × saturation outcome  (9 bins)
// =========================================================================
`uvm_analysis_imp_decl(_drv2)
`uvm_analysis_imp_decl(_mon2)

class requant_subscriber extends uvm_component;
    `uvm_component_utils(requant_subscriber)

    uvm_analysis_imp_drv2 #(requant_seq_item, requant_subscriber) drv_ap;
    uvm_analysis_imp_mon2 #(requant_seq_item, requant_subscriber) mon_ap;

    // Stimulus queue — write_drv2 pushes clones; write_mon2 pops them
    requant_seq_item stim_q[$];

    // -----------------------------------------------------------------------
    // Sampling variables — all set together in write_mon2 before sample()
    // -----------------------------------------------------------------------
    int unsigned cov_shift;
    int          cov_scale_cat;   // 0=min(1)  1=low(2-127)  2=high(128-255)
    int          cov_zp_cat;      // 0=neg      1=zero        2=pos
    int          cov_sat_cat;     // 0=no_sat   1=pos_sat     2=neg_sat
    int          cov_input_sign;  // 0=positive  1=negative

    // -----------------------------------------------------------------------
    // Covergroup
    // -----------------------------------------------------------------------
    covergroup requant_coverage;

        cp_shift : coverpoint cov_shift {
            bins shift_zero = {0};
            bins shift_low  = {[1:7]};
            bins shift_mid  = {[8:14]};
            bins shift_max  = {15};
        }

        cp_scale : coverpoint cov_scale_cat {
            bins scale_min  = {0};
            bins scale_low  = {1};
            bins scale_high = {2};
        }

        cp_zp : coverpoint cov_zp_cat {
            bins zp_neg  = {0};
            bins zp_zero = {1};
            bins zp_pos  = {2};
        }

        cp_sat : coverpoint cov_sat_cat {
            bins no_sat  = {0};
            bins pos_sat = {1};
            bins neg_sat = {2};
        }

        cp_input_sign : coverpoint cov_input_sign {
            bins pos_input = {0};
            bins neg_input = {1};
        }

        cx_shift_scale : cross cp_shift, cp_scale;
        cx_zp_sat      : cross cp_zp,   cp_sat;

    endgroup : requant_coverage

    function new(string name, uvm_component parent);
        super.new(name, parent);
        drv_ap = new("drv_ap", this);
        mon_ap = new("mon_ap", this);
        requant_coverage = new();
    endfunction

    // -----------------------------------------------------------------------
    // write_drv2 — buffer the stimulus clone; do NOT sample here.
    // Sampling before the output arrives would lock crosses to cov_sat_cat=0.
    // -----------------------------------------------------------------------
    function void write_drv2(requant_seq_item t);
        requant_seq_item clone;
        $cast(clone, t.clone());
        stim_q.push_back(clone);
    endfunction

    // -----------------------------------------------------------------------
    // write_mon2 — called after the pipeline flushes.
    // Pop the matching stimulus, set ALL sampling variables, then sample
    // once per grid element so cp_input_sign sees both signs within a
    // single mixed-sign transaction.
    // -----------------------------------------------------------------------
    function void write_mon2(requant_seq_item t);
        requant_seq_item stim;

        if (stim_q.size() == 0) begin
            `uvm_error("COV", "write_mon2: stimulus queue empty")
            return;
        end
        stim = stim_q.pop_front();

        // ---- stimulus-side fields (same for every element) ----
        cov_shift = stim.requant_shift;

        if      (stim.requant_scale == 1)              cov_scale_cat = 0;
        else if (stim.requant_scale inside {[2:127]})  cov_scale_cat = 1;
        else                                            cov_scale_cat = 2;

        if      (stim.ZP_next  < 0)  cov_zp_cat = 0;
        else if (stim.ZP_next == 0)  cov_zp_cat = 1;
        else                          cov_zp_cat = 2;

        // ---- per-element sample: output + input sign both known here ----
        for (int i = 0; i < `SYS_ROW * `SYS_COL; i++) begin

            // saturation outcome from observed output
            if      (t.requant_out_flat[i] ===  8'sd127) cov_sat_cat = 1;
            else if (t.requant_out_flat[i] === -8'sd128) cov_sat_cat = 2;
            else                                           cov_sat_cat = 0;

            // input sign for this element
            cov_input_sign = (stim.sys_out_flat[i] < 0) ? 1 : 0;

            // One unified sample — every coverpoint and cross sees
            // consistent, fully-populated variables
            requant_coverage.sample();
        end
    endfunction

    // -----------------------------------------------------------------------
    // Coverage report
    // -----------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        $display("\n\n\t----------------------------");
        $display(  "\t---   COVERAGE  REPORT   ---");
        $display(  "\t----------------------------");
        $display(  "\t  Overall            : %6.2f%%", requant_coverage.get_coverage());
        $display(  "\t  cp_shift           : %6.2f%%", requant_coverage.cp_shift.get_coverage());
        $display(  "\t  cp_scale           : %6.2f%%", requant_coverage.cp_scale.get_coverage());
        $display(  "\t  cp_zp              : %6.2f%%", requant_coverage.cp_zp.get_coverage());
        $display(  "\t  cp_sat             : %6.2f%%", requant_coverage.cp_sat.get_coverage());
        $display(  "\t  cp_input_sign      : %6.2f%%", requant_coverage.cp_input_sign.get_coverage());
        $display(  "\t  cx_shift_scale     : %6.2f%%", requant_coverage.cx_shift_scale.get_coverage());
        $display(  "\t  cx_zp_sat          : %6.2f%%", requant_coverage.cx_zp_sat.get_coverage());
        $display(  "\t----------------------------\n");
    endfunction

endclass

// =========================================================================
// Agent
// =========================================================================
class requant_agent extends uvm_agent;
    `uvm_component_utils(requant_agent)

    requant_driver  drv;
    requant_monitor mon;
    uvm_sequencer #(requant_seq_item) sqr;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    virtual function void build_phase(uvm_phase phase);
        drv = requant_driver ::type_id::create("drv", this);
        mon = requant_monitor::type_id::create("mon", this);
        sqr = uvm_sequencer#(requant_seq_item)::type_id::create("sqr", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass

// =========================================================================
// Environment
// =========================================================================
class requant_env extends uvm_env;
    `uvm_component_utils(requant_env)

    requant_agent      agt;
    requant_scoreboard scb;
    requant_subscriber sub;                   // NEW

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    virtual function void build_phase(uvm_phase phase);
        agt = requant_agent     ::type_id::create("agt", this);
        scb = requant_scoreboard::type_id::create("scb", this);
        sub = requant_subscriber::type_id::create("sub", this);  // NEW
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        agt.mon.mon_to_scb.connect(scb.mon_exp);
        agt.drv.drv_to_scb.connect(scb.drv_exp);
        agt.drv.drv_to_scb.connect(sub.drv_ap);   // NEW — stimulus → subscriber
        agt.mon.mon_to_scb.connect(sub.mon_ap);    // NEW — response → subscriber
    endfunction
endclass

// =========================================================================
// Test
// =========================================================================
class requant_test extends uvm_test;
    `uvm_component_utils(requant_test)

    requant_env env;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    virtual function void build_phase(uvm_phase phase);
        env = requant_env::type_id::create("env", this);
    endfunction

    virtual task run_phase(uvm_phase phase);
        requant_sequence                 rand_seq = requant_sequence::type_id::create("rand_seq");
        requant_directed_sequence         dir_seq = requant_directed_sequence::type_id::create("dir_seq");
        requant_coverage_closing_sequence cov_seq = requant_coverage_closing_sequence::type_id::create("cov_seq");
        phase.raise_objection(this);
        rand_seq.start(env.agt.sqr);   // random + corner phase (original)
        dir_seq.start(env.agt.sqr);    // directed closing phase (6 transactions)
        cov_seq.start(env.agt.sqr);    // coverage closing phase (12 transactions)
        #500;
        phase.drop_objection(this);
    endtask
endclass

// =========================================================================
// Top Module
// =========================================================================
module tb_top;

    localparam int SYS_ROW = `SYS_ROW;
    localparam int SYS_COL = `SYS_COL;

    logic clk = 0;
    logic rst;

    always #5 clk = ~clk;
    initial begin rst = 1; #25 rst = 0; end

    requant_if #(SYS_ROW, SYS_COL) r_if (clk, rst);

    requantization_block #(
        .sys_row (SYS_ROW),
        .sys_col (SYS_COL)
    ) dut (
        .clk          (r_if.clk),
        .rst          (r_if.rst),
        .start        (r_if.start),
        .requant_scale(r_if.requant_scale),
        .requant_shift(r_if.requant_shift),
        .ZP_next      (r_if.ZP_next),
        .sys_out      (r_if.sys_out),
        .requant_out  (r_if.requant_out)
    );

    initial begin
        uvm_config_db #(virtual requant_if #(SYS_ROW, SYS_COL))::set(
            null, "*", "vif", r_if);
        run_test("requant_test");
    end

endmodule