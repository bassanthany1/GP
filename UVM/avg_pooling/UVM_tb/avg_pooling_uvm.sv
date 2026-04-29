`include "uvm_macros.svh"
import uvm_pkg::*;

// =========================================================================
// Interface
// =========================================================================
interface pool_if(input logic clk, input logic rst);
    logic [6:0]  in_channels;
    logic [4:0]  input_height;
    logic [4:0]  input_width;
    logic        wr_en;
    logic [15:0] wr_addr;
    logic signed [7:0] wr_data;
    logic        start_pool;
    logic        done;
    logic        rd_valid;
    logic signed [7:0] rd_data;
    logic [7:0]  rd_channel;
    logic [7:0]  rd_row;
    logic [7:0]  rd_col;
endinterface

// =========================================================================
// Sequence Item
// =========================================================================
class pool_seq_item extends uvm_sequence_item;
    rand logic signed [7:0] image_data []; 
    rand int ch, h, w; 

    `uvm_object_utils_begin(pool_seq_item)
        `uvm_field_array_int(image_data, UVM_DEFAULT)
        `uvm_field_int(ch, UVM_DEFAULT)
        `uvm_field_int(h, UVM_DEFAULT)
        `uvm_field_int(w, UVM_DEFAULT)
    `uvm_object_utils_end

    constraint c_dims {
        ch inside {[1:2]};   
        h  inside {4, 6, 8}; 
        w  inside {4, 6, 8};
        image_data.size() == ch * h * w;
    }

    function new(string name = "POOL_SEQ_ITEM"); super.new(name); endfunction
endclass

class pool_sequence extends uvm_sequence#(pool_seq_item);
    `uvm_object_utils(pool_sequence)
    function new(string name = "POOL_SEQUENCE"); super.new(name); endfunction
    virtual task body();
        pool_seq_item item = pool_seq_item::type_id::create("item");
        repeat(5) begin
            start_item(item);
            if(!item.randomize()) `uvm_error("SEQ", "Randomization failed")
            finish_item(item);
        end
    endtask
endclass

// =========================================================================
// Directed Closing Sequence
// =========================================================================
class pool_directed_sequence extends uvm_sequence#(pool_seq_item);
    `uvm_object_utils(pool_directed_sequence)
    function new(string name = "POOL_DIRECTED_SEQ"); super.new(name); endfunction
    virtual task body();
        int unsigned h_vals[3] = '{4, 6, 8};
        int unsigned w_vals[3] = '{4, 6, 8};
        foreach (h_vals[i]) begin
            foreach (w_vals[j]) begin
                pool_seq_item item = pool_seq_item::type_id::create("dir_item");
                start_item(item);
                if (!item.randomize() with {
                        ch == 2;
                        h  == h_vals[i];
                        w  == w_vals[j];
                        image_data.size() == ch * h * w;
                    })
                    `uvm_error("DIR_SEQ", "Directed randomization failed")
                finish_item(item);
            end
        end
    endtask
endclass

// =========================================================================
// Driver: Sends copy of transaction to Scoreboard
// =========================================================================
class pool_driver extends uvm_driver #(pool_seq_item);
    `uvm_component_utils(pool_driver)
    virtual pool_if vif;
    uvm_analysis_port #(pool_seq_item) drv_to_scb;

    function new(string name, uvm_component parent); 
        super.new(name, parent); 
        drv_to_scb = new("drv_to_scb", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if(!uvm_config_db#(virtual pool_if)::get(this,"","vif",vif))
            `uvm_fatal("DRV", "No interface");
    endfunction

    virtual task run_phase(uvm_phase phase);
        vif.wr_en <= 0; vif.start_pool <= 0;
        forever begin
            seq_item_port.get_next_item(req);
            drv_to_scb.write(req); // Send reference image to scoreboard
            
            vif.in_channels <= req.ch; vif.input_height <= req.h; vif.input_width <= req.w;
            @(posedge vif.clk);
            for(int i=0; i < req.image_data.size(); i++) begin
                vif.wr_en <= 1; vif.wr_addr <= i; vif.wr_data <= req.image_data[i];
                @(posedge vif.clk);
            end
            vif.wr_en <= 0;
            vif.start_pool <= 1; @(posedge vif.clk); vif.start_pool <= 0;
            wait(vif.done == 1); @(posedge vif.clk);
            seq_item_port.item_done();
        end
    endtask
endclass

// =========================================================================
// Monitor
// =========================================================================
class pool_monitor extends uvm_monitor;
    `uvm_component_utils(pool_monitor)
    uvm_analysis_port #(pool_seq_item) mon_to_scb;
    virtual pool_if vif;

    function new(string name, uvm_component parent); 
        super.new(name, parent); 
        mon_to_scb = new("mon_to_scb", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        void'(uvm_config_db#(virtual pool_if)::get(this,"","vif",vif));
    endfunction

    virtual task run_phase(uvm_phase phase);
        forever begin
            @(posedge vif.clk);
            if(vif.rd_valid) begin
                pool_seq_item item = pool_seq_item::type_id::create("mon_item");
                item.image_data = new[1];
                item.image_data[0] = vif.rd_data;
                item.ch = vif.rd_channel; item.h = vif.rd_row; item.w = vif.rd_col;
                mon_to_scb.write(item);
            end
        end
    endtask
endclass

// =========================================================================
// Scoreboard: Comparative Logic
// =========================================================================
`uvm_analysis_imp_decl(_drv)
`uvm_analysis_imp_decl(_mon)

class pool_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(pool_scoreboard)
    uvm_analysis_imp_drv #(pool_seq_item, pool_scoreboard) drv_exp;
    uvm_analysis_imp_mon #(pool_seq_item, pool_scoreboard) mon_exp;

    pool_seq_item ref_q[$];
    int match = 0, fail = 0;

    function new(string name, uvm_component parent); 
        super.new(name, parent); 
        drv_exp = new("drv_exp", this);
        mon_exp = new("mon_exp", this);
    endfunction

    function void write_drv(pool_seq_item data);
        pool_seq_item clone;
        $cast(clone, data.clone());
        ref_q.push_back(clone);
    endfunction

    function void write_mon(pool_seq_item data);
        if (ref_q.size() > 0) begin
            pool_seq_item inp = ref_q[0];
            logic signed [11:0] sum;
            logic signed [7:0]  expected;
            int b, tl, tr, bl, br;

            // Calculate address in flat array based on (Ch * H * W)
            b  = (data.ch * (inp.h * inp.w));
            tl = (data.h * 2) * inp.w + (data.w * 2);
            tr = tl + 1;
            bl = (data.h * 2 + 1) * inp.w + (data.w * 2);
            br = bl + 1;

            sum = inp.image_data[b+tl] + inp.image_data[b+tr] + 
                  inp.image_data[b+bl] + inp.image_data[b+br];
            expected = sum >>> 2; // Arithmetic shift for average

            if (data.image_data[0] == expected) begin
                `uvm_info("SCB", $sformatf("MATCH: Ch:%0d [%0d,%0d] Exp:%0d Obs:%0d", 
                          data.ch, data.h, data.w, expected, data.image_data[0]), UVM_LOW)
                match++;
            end else begin
                `uvm_error("SCB", $sformatf("FAIL: Ch:%0d [%0d,%0d] Exp:%0d Obs:%0d", 
                           data.ch, data.h, data.w, expected, data.image_data[0]))
                fail++;
            end

            // If current output pixel is the last for this image, pop the reference
            if (data.ch == inp.ch-1 && data.h == (inp.h/2)-1 && data.w == (inp.w/2)-1)
                void'(ref_q.pop_front());
        end
    endfunction

    function void report_phase(uvm_phase phase);
        if (fail == 0 && match > 0)
            $display("\n\n\t----------------------------\n\t---   STATUS: UVM PASS   ---\n\t----------------------------\n");
        else
            $display("\n\n\t----------------------------\n\t---   STATUS: UVM FAIL   ---\n\t----------------------------\n");
    endfunction
endclass

// =========================================================================
// Coverage Subscriber  
// =========================================================================
class pool_subscriber extends uvm_subscriber #(pool_seq_item);
    `uvm_component_utils(pool_subscriber)

    // ---- coverage fields sampled by covergroup ----
    int unsigned cov_channel;
    int unsigned cov_row;
    int unsigned cov_col;

    covergroup pool_coverage;
        cp_channel : coverpoint cov_channel {
            bins ch[] = {[0:1]};          // up to 2 channels (indices 0-1)
        }
        cp_row : coverpoint cov_row {
            bins row[] = {[0:3]};         // up to 4 output rows (indices 0-3)
        }
        cp_col : coverpoint cov_col {
            bins col[] = {[0:3]};         // up to 4 output cols (indices 0-3)
        }
        cx_ch_row  : cross cp_channel, cp_row;
        cx_row_col : cross cp_row,     cp_col;
    endgroup : pool_coverage

    function new(string name, uvm_component parent);
        super.new(name, parent);
        pool_coverage = new();            // instantiate covergroup
    endfunction

    // write() is called by the analysis port on every valid monitor transaction
    virtual function void write(pool_seq_item t);
        cov_channel = t.ch;
        cov_row     = t.h;
        cov_col     = t.w;
        pool_coverage.sample();
    endfunction

    // Print coverage report using $display so it is never filtered by
    // UVM verbosity settings and always appears in the transcript.
    virtual function void report_phase(uvm_phase phase);
        $display("\n\n\t----------------------------");
        $display(  "\t---   COVERAGE  REPORT   ---");
        $display(  "\t----------------------------");
        $display(  "\t  Overall          : %6.2f%%", pool_coverage.get_coverage());
        $display(  "\t  cp_channel       : %6.2f%%", pool_coverage.cp_channel.get_coverage());
        $display(  "\t  cp_row           : %6.2f%%", pool_coverage.cp_row.get_coverage());
        $display(  "\t  cp_col           : %6.2f%%", pool_coverage.cp_col.get_coverage());
        $display(  "\t  cx_ch_row (cross): %6.2f%%", pool_coverage.cx_ch_row.get_coverage());
        $display(  "\t  cx_row_col(cross): %6.2f%%", pool_coverage.cx_row_col.get_coverage());
        $display(  "\t----------------------------\n");
    endfunction
endclass

// =========================================================================
// Environment & Test Setup
// =========================================================================
class pool_agent extends uvm_agent;
    `uvm_component_utils(pool_agent)
    pool_driver drv; pool_monitor mon; uvm_sequencer #(pool_seq_item) sqr;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void build_phase(uvm_phase phase);
        drv = pool_driver::type_id::create("drv", this);
        mon = pool_monitor::type_id::create("mon", this);
        sqr = uvm_sequencer#(pool_seq_item)::type_id::create("sqr", this);
    endfunction
    virtual function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass

// pool_env: one new line in build_phase + one new line in connect_phase
class pool_env extends uvm_env;
    `uvm_component_utils(pool_env)
    pool_agent      agt;
    pool_scoreboard scb;
    pool_subscriber sub;                  // NEW

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    virtual function void build_phase(uvm_phase phase);
        agt = pool_agent::type_id::create("agt", this);
        scb = pool_scoreboard::type_id::create("scb", this);
        sub = pool_subscriber::type_id::create("sub", this);  // NEW
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        agt.mon.mon_to_scb.connect(scb.mon_exp);
        agt.drv.drv_to_scb.connect(scb.drv_exp);
        agt.mon.mon_to_scb.connect(sub.analysis_export);      // NEW
    endfunction
endclass

class pool_test extends uvm_test;
    `uvm_component_utils(pool_test)
    pool_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void build_phase(uvm_phase phase); env = pool_env::type_id::create("env", this); endfunction
    virtual task run_phase(uvm_phase phase);
        pool_sequence         rand_seq = pool_sequence::type_id::create("rand_seq");
        pool_directed_sequence dir_seq = pool_directed_sequence::type_id::create("dir_seq");
        phase.raise_objection(this);
        rand_seq.start(env.agt.sqr);   // random phase  (5 transactions)
        dir_seq.start(env.agt.sqr);    // closing phase (9 directed transactions)
        #1000; phase.drop_objection(this);
    endtask
endclass

// =========================================================================
// Top Module
// =========================================================================
module tb_top;
    logic clk = 0; logic rst;
    always #5 clk = ~clk;
    initial begin rst = 1; #25 rst = 0; end

    pool_if p_if(clk, rst);

    avg_pool_2x2_banked_internal_fixed #(.DATA_WIDTH(8)) dut (
        .clk(p_if.clk), .rst(p_if.rst), .in_channels(p_if.in_channels),
        .input_height(p_if.input_height), .input_width(p_if.input_width),
        .wr_en(p_if.wr_en), .wr_addr(p_if.wr_addr), .wr_data(p_if.wr_data),
        .start_pool(p_if.start_pool), .rd_valid(p_if.rd_valid), .rd_data(p_if.rd_data),
        .rd_channel(p_if.rd_channel), .rd_row(p_if.rd_row), .rd_col(p_if.rd_col), .done(p_if.done)
    );

    initial begin
        uvm_config_db#(virtual pool_if)::set(null, "*", "vif", p_if);
        run_test("pool_test");
    end
endmodule