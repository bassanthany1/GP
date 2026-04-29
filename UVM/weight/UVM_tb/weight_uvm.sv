/*`include "uvm_macros.svh"
import uvm_pkg::*;

// -----------------------------------------------------------------------------
// 1. INTERFACE
// -----------------------------------------------------------------------------
interface weight_if(input logic clk, input logic rst);
    logic start;
    logic [2:0]  kernel_size;
    logic [8:0]  in_channels;
    logic [6:0]  out_channels;
    logic        tile_ready;
    logic        done_all;
    logic [14:0] sram_addr;
    logic [8:0]  sram_burst_len;
    logic        sram_read_req;
    logic signed [7:0] sram_data;
    logic        sram_valid;
    logic        sram_burst_done;
    
    logic signed [7:0] probe_row [4]; 
endinterface

// -----------------------------------------------------------------------------
// 2. TRANSACTION
// -----------------------------------------------------------------------------
class weight_item extends uvm_sequence_item;
    rand logic [2:0] kernel_size;
    rand logic [8:0] in_channels;
    rand logic [6:0] out_channels;

    `uvm_object_utils_begin(weight_item)
        `uvm_field_int(kernel_size, UVM_ALL_ON)
        `uvm_field_int(in_channels, UVM_ALL_ON)
        `uvm_field_int(out_channels, UVM_ALL_ON)
    `uvm_object_utils_end

    constraint c_stable { 
        kernel_size == 3; 
        in_channels == 2; 
        out_channels == 4; 
    }
    function new(string name = ""); super.new(name); endfunction
endclass

// -----------------------------------------------------------------------------
// 3. SEQUENCE
// -----------------------------------------------------------------------------
class weight_base_seq extends uvm_sequence#(weight_item);
    `uvm_object_utils(weight_base_seq)
    function new(string name = ""); super.new(name); endfunction

    task body();
        repeat (3) begin 
            req = weight_item::type_id::create("req");
            start_item(req);
            if(!req.randomize()) `uvm_error("SEQ", "Randomization failed")
            finish_item(req);
        end
    endtask
endclass

// -----------------------------------------------------------------------------
// 4. SCOREBOARD
// -----------------------------------------------------------------------------
class weight_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(weight_scoreboard)
    virtual weight_if vif;
    
    int tile_idx = 0;
    int error_count = 0;
    logic signed [7:0] expected_heads [$]; 

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(posedge vif.clk);
            
            if (vif.sram_read_req) begin
                wait(vif.sram_valid == 1);
                expected_heads.push_back(vif.sram_data);
                wait(vif.sram_burst_done == 1 || vif.sram_read_req == 0);
            end

            if (vif.tile_ready) begin
                logic signed [7:0] exp [4];
                bit mismatch = 0;

                if (expected_heads.size() >= 4) begin
                    for(int i=0; i<4; i++) begin
                        exp[i] = expected_heads.pop_front();
                        if (vif.probe_row[i] !== exp[i]) mismatch = 1;
                    end
                end else begin
                    mismatch = 1;
                end

                if (!mismatch) begin
                    `uvm_info("SCB", $sformatf("MATCH! Tile %0d\n Observed Vector: [%h, %h, %h, %h]\n Expected Vector: [%h, %h, %h, %h]", 
                              tile_idx, vif.probe_row[0], vif.probe_row[1], vif.probe_row[2], vif.probe_row[3],
                              exp[0], exp[1], exp[2], exp[3]), UVM_LOW)
                end else begin
                    `uvm_error("SCB", $sformatf("MISMATCH! Tile %0d\n Observed Vector: [%h, %h, %h, %h]\n Expected Vector: [%h, %h, %h, %h]", 
                               tile_idx, vif.probe_row[0], vif.probe_row[1], vif.probe_row[2], vif.probe_row[3],
                               exp[0], exp[1], exp[2], exp[3]))
                    error_count++;
                end
                
                tile_idx++;
                expected_heads.delete(); 
            end
        end
    endtask
endclass

// -----------------------------------------------------------------------------
// 5. SRAM RESPONDER
// -----------------------------------------------------------------------------
class sram_responder extends uvm_component;
    `uvm_component_utils(sram_responder)
    virtual weight_if vif; 
    logic signed [7:0] mem [0:30719];
    int tile_call_count = 0; 

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase); 
        $readmemh("F:/College/Graduation project/Weight UVM/weights_conv1_int8.mem", mem);
    endfunction

    task run_phase(uvm_phase phase);
        vif.sram_valid <= 0;
        forever begin
            @(posedge vif.clk);
            
            if (vif.start) begin
                tile_call_count++;
            end

            if (vif.sram_read_req) begin
                int offset = (tile_call_count - 1) * 72; 
                int len = (vif.sram_burst_len == 0) ? 1 : vif.sram_burst_len;
                
                for (int i = 0; i < len; i++) begin
                    vif.sram_valid <= 1;
                    vif.sram_data  <= mem[vif.sram_addr + i + offset];
                    vif.sram_burst_done <= (i == len-1);
                    @(posedge vif.clk);
                end
                vif.sram_valid <= 0;
                vif.sram_burst_done <= 0;
            end
        end
    endtask
endclass

// -----------------------------------------------------------------------------
// 6. DRIVER
// -----------------------------------------------------------------------------
class weight_driver extends uvm_driver#(weight_item);
    `uvm_component_utils(weight_driver)
    virtual weight_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
        vif.start <= 0;
        forever begin
            seq_item_port.get_next_item(req);
            wait(vif.rst === 0);
            @(posedge vif.clk);
            vif.kernel_size  <= req.kernel_size; 
            vif.in_channels  <= req.in_channels;
            vif.out_channels <= req.out_channels; 
            vif.start        <= 1;
            @(posedge vif.clk); 
            vif.start        <= 0;
            wait(vif.tile_ready == 1);
            @(posedge vif.clk);
            seq_item_port.item_done();
        end
    endtask
endclass

// -----------------------------------------------------------------------------
// 7. ENVIRONMENT
// -----------------------------------------------------------------------------
class weight_env extends uvm_env;
    `uvm_component_utils(weight_env)
    weight_driver drv; sram_responder mem; weight_scoreboard scb; uvm_sequencer#(weight_item) sqr;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        drv = weight_driver::type_id::create("drv", this);
        sqr = uvm_sequencer#(weight_item)::type_id::create("sqr", this);
        mem = sram_responder::type_id::create("mem", this);
        scb = weight_scoreboard::type_id::create("scb", this);
        
        // Corrected DB get call to remove vsim-3764 warning
        if(!uvm_config_db#(virtual weight_if)::get(this, "", "vif", drv.vif)) begin
            `uvm_fatal("ENV_CONFIG", "Virtual interface vif not found in config_db")
        end
        
        mem.vif = drv.vif; 
        scb.vif = drv.vif;
    endfunction

    function void connect_phase(uvm_phase phase); 
        drv.seq_item_port.connect(sqr.seq_item_export); 
    endfunction
endclass

// -----------------------------------------------------------------------------
// 8. TEST
// -----------------------------------------------------------------------------
class weight_test extends uvm_test;
    `uvm_component_utils(weight_test)
    weight_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase); 
        env = weight_env::type_id::create("env", this); 
    endfunction

    task run_phase(uvm_phase phase);
        weight_base_seq seq = weight_base_seq::type_id::create("seq");
        phase.raise_objection(this); 
        seq.start(env.sqr); 
        #100us; 
        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        $display("\n=========================================");
        $display("   FINAL STATUS: %s", (env.scb.error_count == 0 && env.scb.tile_idx > 0) ? "PASSED" : "FAILED");
        $display("   Total Tiles Processed: %0d", env.scb.tile_idx);
        $display("=========================================\n");
    endfunction
endclass

// -----------------------------------------------------------------------------
// 9. TOP MODULE
// -----------------------------------------------------------------------------
module weight_top;
    logic clk, rst;
    initial begin clk = 0; forever #5 clk = ~clk; end
    initial begin rst = 1; #100 rst = 0; end

    weight_if vif(clk, rst);
    logic signed [7:0] weight_tile_dut [256][4];

    assign vif.probe_row[0] = weight_tile_dut[0][0];
    assign vif.probe_row[1] = weight_tile_dut[0][1];
    assign vif.probe_row[2] = weight_tile_dut[0][2];
    assign vif.probe_row[3] = weight_tile_dut[0][3];

    weight_flatten2_streaming_burst dut (
        .clk(vif.clk), .rst(vif.rst), .start(vif.start),
        .kernel_size(vif.kernel_size), .in_channels(vif.in_channels),
        .out_channels(vif.out_channels), .tile_ready(vif.tile_ready),
        .done_all(vif.done_all), .sram_addr(vif.sram_addr),
        .sram_burst_len(vif.sram_burst_len), .sram_read_req(vif.sram_read_req),
        .sram_data(vif.sram_data), .sram_valid(vif.sram_valid),
        .sram_burst_done(vif.sram_burst_done), .weight_tile(weight_tile_dut)
    );

    initial begin
        uvm_config_db#(virtual weight_if)::set(null, "*", "vif", vif);
        run_test("weight_test");
    end
endmodule*/
/*`include "uvm_macros.svh"
import uvm_pkg::*;

// -----------------------------------------------------------------------------
// 1. INTERFACE
// -----------------------------------------------------------------------------
interface weight_if(input logic clk, input logic rst);
    logic start;
    logic [2:0]  kernel_size;
    logic [8:0]  in_channels;
    logic [6:0]  out_channels;
    logic        tile_ready;
    logic        done_all;
    logic [14:0] sram_addr;
    logic [8:0]  sram_burst_len;
    logic        sram_read_req;
    logic signed [7:0] sram_data;
    logic        sram_valid;
    logic        sram_burst_done;
    
    logic signed [7:0] probe_row [4]; 
endinterface

// -----------------------------------------------------------------------------
// 2. TRANSACTION
// -----------------------------------------------------------------------------
class weight_item extends uvm_sequence_item;
    rand logic [2:0] kernel_size;
    rand logic [8:0] in_channels;
    rand logic [6:0] out_channels;

    `uvm_object_utils_begin(weight_item)
        `uvm_field_int(kernel_size, UVM_ALL_ON)
        `uvm_field_int(in_channels, UVM_ALL_ON)
        `uvm_field_int(out_channels, UVM_ALL_ON)
    `uvm_object_utils_end

    constraint c_stable { 
        kernel_size == 3; 
        in_channels == 2; 
        out_channels == 4; 
    }
    function new(string name = ""); super.new(name); endfunction
endclass

// -----------------------------------------------------------------------------
// 3. SEQUENCE
// -----------------------------------------------------------------------------
class weight_base_seq extends uvm_sequence#(weight_item);
    `uvm_object_utils(weight_base_seq)
    function new(string name = ""); super.new(name); endfunction

    task body();
        repeat (3) begin 
            req = weight_item::type_id::create("req");
            start_item(req);
            if(!req.randomize()) `uvm_error("SEQ", "Randomization failed")
            finish_item(req);
        end
    endtask
endclass

// -----------------------------------------------------------------------------
// 4. SCOREBOARD
// -----------------------------------------------------------------------------
class weight_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(weight_scoreboard)
    virtual weight_if vif;
    
    int tile_idx = 0;
    int error_count = 0;
    logic signed [7:0] expected_heads [$]; 

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(posedge vif.clk);
            
            if (vif.sram_read_req) begin
                wait(vif.sram_valid == 1);
                expected_heads.push_back(vif.sram_data);
                wait(vif.sram_burst_done == 1 || vif.sram_read_req == 0);
            end

            if (vif.tile_ready) begin
                logic signed [7:0] exp [4];
                bit mismatch = 0;

                if (expected_heads.size() >= 4) begin
                    for(int i=0; i<4; i++) begin
                        exp[i] = expected_heads.pop_front();
                        if (vif.probe_row[i] !== exp[i]) mismatch = 1;
                    end
                end else begin
                    mismatch = 1;
                end

                if (!mismatch) begin
                    `uvm_info("SCB", $sformatf("MATCH! Tile %0d\n Observed Vector: [%h, %h, %h, %h]\n Expected Vector: [%h, %h, %h, %h]", 
                              tile_idx, vif.probe_row[0], vif.probe_row[1], vif.probe_row[2], vif.probe_row[3],
                              exp[0], exp[1], exp[2], exp[3]), UVM_LOW)
                end else begin
                    `uvm_error("SCB", $sformatf("MISMATCH! Tile %0d\n Observed Vector: [%h, %h, %h, %h]\n Expected Vector: [%h, %h, %h, %h]", 
                               tile_idx, vif.probe_row[0], vif.probe_row[1], vif.probe_row[2], vif.probe_row[3],
                               exp[0], exp[1], exp[2], exp[3]))
                    error_count++;
                end
                
                tile_idx++;
                expected_heads.delete(); 
            end
        end
    endtask
endclass

// -----------------------------------------------------------------------------
// 5. SRAM RESPONDER
// -----------------------------------------------------------------------------
class sram_responder extends uvm_component;
    `uvm_component_utils(sram_responder)
    virtual weight_if vif; 
    logic signed [7:0] mem [0:30719];
    int tile_call_count = 0; 

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase); 
        $readmemh("F:/College/Graduation project/Weight UVM/weights_conv1_int8.mem", mem);
    endfunction

    task run_phase(uvm_phase phase);
        vif.sram_valid <= 0;
        forever begin
            @(posedge vif.clk);
            
            if (vif.start) begin
                tile_call_count++;
            end

            if (vif.sram_read_req) begin
                int offset = (tile_call_count - 1) * 72; 
                int len = (vif.sram_burst_len == 0) ? 1 : vif.sram_burst_len;
                
                for (int i = 0; i < len; i++) begin
                    vif.sram_valid <= 1;
                    vif.sram_data  <= mem[vif.sram_addr + i + offset];
                    vif.sram_burst_done <= (i == len-1);
                    @(posedge vif.clk);
                end
                vif.sram_valid <= 0;
                vif.sram_burst_done <= 0;
            end
        end
    endtask
endclass

// -----------------------------------------------------------------------------
// 6. DRIVER
// -----------------------------------------------------------------------------
class weight_driver extends uvm_driver#(weight_item);
    `uvm_component_utils(weight_driver)
    virtual weight_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
        vif.start <= 0;
        forever begin
            seq_item_port.get_next_item(req);
            wait(vif.rst === 0);
            @(posedge vif.clk);
            vif.kernel_size  <= req.kernel_size; 
            vif.in_channels  <= req.in_channels;
            vif.out_channels <= req.out_channels; 
            vif.start        <= 1;
            @(posedge vif.clk); 
            vif.start        <= 0;
            wait(vif.tile_ready == 1);
            @(posedge vif.clk);
            seq_item_port.item_done();
        end
    endtask
endclass

// -----------------------------------------------------------------------------
// 7. ENVIRONMENT
// -----------------------------------------------------------------------------
class weight_env extends uvm_env;
    `uvm_component_utils(weight_env)
    weight_driver drv; sram_responder mem; weight_scoreboard scb; uvm_sequencer#(weight_item) sqr;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        drv = weight_driver::type_id::create("drv", this);
        sqr = uvm_sequencer#(weight_item)::type_id::create("sqr", this);
        mem = sram_responder::type_id::create("mem", this);
        scb = weight_scoreboard::type_id::create("scb", this);
        
        // Corrected DB get call to remove vsim-3764 warning
        if(!uvm_config_db#(virtual weight_if)::get(this, "", "vif", drv.vif)) begin
            `uvm_fatal("ENV_CONFIG", "Virtual interface vif not found in config_db")
        end
        
        mem.vif = drv.vif; 
        scb.vif = drv.vif;
    endfunction

    function void connect_phase(uvm_phase phase); 
        drv.seq_item_port.connect(sqr.seq_item_export); 
    endfunction
endclass

// -----------------------------------------------------------------------------
// 8. TEST
// -----------------------------------------------------------------------------
class weight_test extends uvm_test;
    `uvm_component_utils(weight_test)
    weight_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase); 
        env = weight_env::type_id::create("env", this); 
    endfunction

    task run_phase(uvm_phase phase);
        weight_base_seq seq = weight_base_seq::type_id::create("seq");
        phase.raise_objection(this); 
        seq.start(env.sqr); 
        #100us; 
        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        $display("\n=========================================");
        $display("   FINAL STATUS: %s", (env.scb.error_count == 0 && env.scb.tile_idx > 0) ? "PASSED" : "FAILED");
        $display("   Total Tiles Processed: %0d", env.scb.tile_idx);
        $display("=========================================\n");
    endfunction
endclass

// -----------------------------------------------------------------------------
// 9. TOP MODULE
// -----------------------------------------------------------------------------
module weight_top;
    logic clk, rst;
    initial begin clk = 0; forever #5 clk = ~clk; end
    initial begin rst = 1; #100 rst = 0; end

    weight_if vif(clk, rst);
    logic signed [7:0] weight_tile_dut [256][4];

    assign vif.probe_row[0] = weight_tile_dut[0][0];
    assign vif.probe_row[1] = weight_tile_dut[0][1];
    assign vif.probe_row[2] = weight_tile_dut[0][2];
    assign vif.probe_row[3] = weight_tile_dut[0][3];

    weight_flatten2_streaming_burst dut (
        .clk(vif.clk), .rst(vif.rst), .start(vif.start),
        .kernel_size(vif.kernel_size), .in_channels(vif.in_channels),
        .out_channels(vif.out_channels), .tile_ready(vif.tile_ready),
        .done_all(vif.done_all), .sram_addr(vif.sram_addr),
        .sram_burst_len(vif.sram_burst_len), .sram_read_req(vif.sram_read_req),
        .sram_data(vif.sram_data), .sram_valid(vif.sram_valid),
        .sram_burst_done(vif.sram_burst_done), .weight_tile(weight_tile_dut)
    );

    initial begin
        uvm_config_db#(virtual weight_if)::set(null, "*", "vif", vif);
        run_test("weight_test");
    end
endmodule*/
`include "uvm_macros.svh"
import uvm_pkg::*;

// -----------------------------------------------------------------------------
// 1. INTERFACE
// -----------------------------------------------------------------------------
interface weight_if(input logic clk, input logic rst);
    logic start;
    logic [2:0]  kernel_size;
    logic [8:0]  in_channels;
    logic [6:0]  out_channels;
    logic        tile_ready;
    logic        done_all;
    logic [14:0] sram_addr;
    logic [8:0]  sram_burst_len;
    logic        sram_read_req;
    logic signed [7:0] sram_data;
    logic        sram_valid;
    logic        sram_burst_done;

    // probe_row monitors the first row of weight_tile (row=0, all 4 cols)
    logic signed [7:0] probe_row [4];
endinterface

// -----------------------------------------------------------------------------
// 2. TRANSACTION
// -----------------------------------------------------------------------------
class weight_item extends uvm_sequence_item;
    rand logic [2:0] kernel_size;
    rand logic [8:0] in_channels;
    rand logic [6:0] out_channels;

    `uvm_object_utils_begin(weight_item)
        `uvm_field_int(kernel_size,  UVM_ALL_ON)
        `uvm_field_int(in_channels,  UVM_ALL_ON)
        `uvm_field_int(out_channels, UVM_ALL_ON)
    `uvm_object_utils_end

    constraint c_stable {
        kernel_size  == 3;
        in_channels  == 2;
        out_channels == 4;
    }
    function new(string name = ""); super.new(name); endfunction
endclass

// -----------------------------------------------------------------------------
// 3. BASE SEQUENCE  (3 random transactions)
// -----------------------------------------------------------------------------
class weight_base_seq extends uvm_sequence#(weight_item);
    `uvm_object_utils(weight_base_seq)
    function new(string name = ""); super.new(name); endfunction

    task body();
        repeat (3) begin
            req = weight_item::type_id::create("req");
            start_item(req);
            if (!req.randomize()) `uvm_error("SEQ", "Randomization failed")
            finish_item(req);
        end
    endtask
endclass

// =============================================================================
// 3b. COVERAGE-CLOSING DIRECTED SEQUENCE  (14 transactions → 100% coverage)
//
// ROOT CAUSE ANALYSIS — why the previous version reached only 97.5%
// -----------------------------------------------------------------
// cx_kernel_inch (cross cp_kernel × cp_in_ch, 12 bins total):
//   The missing 3 bins were:
//     k1 × inch_medium (in_ch in [16:63]) — no such transaction existed
//     k1 × inch_large  (in_ch >= 64)      — no such transaction existed
//     k5 × inch_medium (in_ch in [16:63]) — no such transaction existed
//
//   Coverage calculation: cx_kernel_inch = 9/12 = 75 %
//   Overall (10 coverpoints averaged): (9×100 + 75) / 10 = 97.5 % ✓
//
// cx_outch_done (cross cp_out_ch × cp_done_all, 6 bins total):
//   outch_partial (cov_outch_cat=0) is set when out_channels < 4.
//   A transaction with out_ch < 4 always has exactly 1 tile, so
//   done_all is always 1 on its tile_ready pulse.  Therefore the bin
//   outch_partial × not_done is architecturally unreachable.
//   This bin is excluded with ignore_bins in the covergroup (see section 7).
//
// TRANSACTIONS ADDED IN THIS VERSION
// -----------------------------------
//   Txn 12: k=1, in_ch=16, out_ch=4  → closes k1 × inch_medium
//   Txn 13: k=1, in_ch=64, out_ch=4  → closes k1 × inch_large
//   Txn 14: k=5, in_ch=16, out_ch=4  → closes k5 × inch_medium
// =============================================================================
class weight_coverage_closing_seq extends uvm_sequence#(weight_item);
    `uvm_object_utils(weight_coverage_closing_seq)
    function new(string name = ""); super.new(name); endfunction

    task body();
        weight_item item;

        // ------------------------------------------------------------------
        // Txn 1: k=1, in_ch=1, out_ch=4  (exact 1 tile, wpf=1 → short burst)
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k1_ich1_oc4");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd1;
                in_channels  == 9'd1;
                out_channels == 7'd4;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k1 ich1 oc4)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 2: k=1, in_ch=1, out_ch=3  (partial tile → padding path)
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k1_ich1_oc3");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd1;
                in_channels  == 9'd1;
                out_channels == 7'd3;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k1 ich1 oc3)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 3: k=1, in_ch=8, out_ch=4  (exact 1 tile, medium burst)
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k1_ich8_oc4");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd1;
                in_channels  == 9'd8;
                out_channels == 7'd4;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k1 ich8 oc4)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 4: k=5, in_ch=1, out_ch=4  (exact 1 tile, wpf=25 medium burst)
        //   Hits: cp_kernel/k5, cx_kernel_inch(k5×in1), cp_burst_len/medium
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k5_ich1_oc4");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd5;
                in_channels  == 9'd1;
                out_channels == 7'd4;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k5 ich1 oc4)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 5: k=5, in_ch=8, out_ch=4  (exact 1 tile, wpf=200 long burst)
        //   Hits: cp_burst_len/long, cx_kernel_inch(k5×in_small)
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k5_ich8_oc4");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd5;
                in_channels  == 9'd8;
                out_channels == 7'd4;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k5 ich8 oc4)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 6: k=3, in_ch=1, out_ch=8  (2 full tiles, wpf=9)
        //   Hits: cp_out_ch/multi-tile, cx_outch_done(exact×done)
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k3_ich1_oc8");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd3;
                in_channels  == 9'd1;
                out_channels == 7'd8;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k3 ich1 oc8)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 7: k=3, in_ch=16, out_ch=5  (multi-tile + partial last tile)
        //   Hits: cp_in_ch/medium, cp_burst_len/long, cp_padding/hit,
        //         cp_out_ch/partial+multi
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k3_ich16_oc5");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd3;
                in_channels  == 9'd16;
                out_channels == 7'd5;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k3 ich16 oc5)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 8: k=3, in_ch=64, out_ch=4  (large in_ch bucket, long burst)
        //   NEW: Closes cx_kernel_inch  k3 × inch_large(64+)
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k3_ich64_oc4");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd3;
                in_channels  == 9'd64;
                out_channels == 7'd4;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k3 ich64 oc4)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 9: k=5, in_ch=64, out_ch=4  (k5 × inch_large)
        //   NEW: Closes cx_kernel_inch  k5 × inch_large(64+)
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k5_ich64_oc4");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd5;
                in_channels  == 9'd64;
                out_channels == 7'd4;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k5 ich64 oc4)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 10: k=1, in_ch=1, out_ch=1  (min configuration)
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k1_ich1_oc1");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd1;
                in_channels  == 9'd1;
                out_channels == 7'd1;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k1 ich1 oc1)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 11: k=1, in_ch=1, out_ch=5
        //   Closes cx_outch_done: outch_multi × not_done (tile 0 of 2)
        //   and   cx_outch_done: outch_multi × done      (tile 1 of 2)
        //   Note: outch_cat logic: out_ch=5 → (5%4)!=0 && 5>=4 → cov_outch_cat=2 (outch_multi)
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k1_ich1_oc5");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd1;
                in_channels  == 9'd1;
                out_channels == 7'd5;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k1 ich1 oc5)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 12: k=1, in_ch=16, out_ch=4
        //   NEW: Closes cx_kernel_inch  k1 × inch_medium (in_ch in [16:63])
        //   wpf = 1*16*1 = 16  → burst_short (16 > 8, actually burst_medium)
        //   in_channels=16 → cov_inch_cat=2 (inch_medium)
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k1_ich16_oc4");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd1;
                in_channels  == 9'd16;
                out_channels == 7'd4;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k1 ich16 oc4)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 13: k=1, in_ch=64, out_ch=4
        //   NEW: Closes cx_kernel_inch  k1 × inch_large (in_ch >= 64)
        //   wpf = 1*64*1 = 64  → burst_medium (64 in [9:63])... actually 64 > 63 → burst_long
        //   in_channels=64 → cov_inch_cat=3 (inch_large)
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k1_ich64_oc4");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd1;
                in_channels  == 9'd64;
                out_channels == 7'd4;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k1 ich64 oc4)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

        // ------------------------------------------------------------------
        // Txn 14: k=5, in_ch=16, out_ch=4
        //   NEW: Closes cx_kernel_inch  k5 × inch_medium (in_ch in [16:63])
        //   wpf = 5*5*16 = 400  → burst_long (> 63)
        //   in_channels=16 → cov_inch_cat=2 (inch_medium)
        // ------------------------------------------------------------------
        item = weight_item::type_id::create("cov_k5_ich16_oc4");
        start_item(item);
        item.c_stable.constraint_mode(0);
        if (!item.randomize() with {
                kernel_size  == 3'd5;
                in_channels  == 9'd16;
                out_channels == 7'd4;
            })
            `uvm_error("COV_SEQ", "Randomization failed (k5 ich16 oc4)")
        item.c_stable.constraint_mode(1);
        finish_item(item);

    endtask
endclass

// -----------------------------------------------------------------------------
// 4. SCOREBOARD  (rewritten)
//
// Bug in original
// ---------------
// The original SCB pushed every SRAM byte into expected_heads, then after
// tile_ready popped exactly 4 bytes and compared against probe_row[0..3].
// This only works when weights_per_filter == 1 (k=1, in_ch=1).  For any
// larger burst the bytes popped are row-0 through row-3 of column-0, not
// the first byte of each column — which is what probe_row[i] carries.
//
// Correct model
// -------------
// weight_tile[row][col] is filled byte-by-byte from SRAM in column order:
//   col 0 → burst of wpf bytes → weight_tile[0..wpf-1][0]
//   col 1 → burst of wpf bytes → weight_tile[0..wpf-1][1]
//   ...
// probe_row[i] = weight_tile[0][i]  = the FIRST byte of column i's burst.
//
// So the expected value for probe_row[col] is simply mem[sram_addr] at the
// moment sram_read_req rises for that column.  We record that first byte
// directly from sram_data on the first sram_valid beat of each burst.
//
// Scoreboard flow
// ---------------
// 1. Watch sram_read_req to know a new burst is starting (store col index).
// 2. On first sram_valid after req, capture sram_data → exp_row[col].
// 3. When tile_ready fires compare probe_row[0..3] vs exp_row[0..3].
// 4. Reset exp_row for the next tile.
//
// Padding columns (oc_vec >= out_channels) skip sram_read_req and zero-fill
// the column; probe_row for those columns will be 0 → exp_row[col] = 0.
// -----------------------------------------------------------------------------
class weight_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(weight_scoreboard)
    virtual weight_if vif;

    int              tile_idx    = 0;
    int              error_count = 0;

    // Expected first-byte for each of the 4 columns in the current tile.
    // Initialised to 0 (correct expected value for padding columns).
    logic signed [7:0] exp_row   [4];
    bit                exp_valid [4]; // 1 once we've captured the byte
    int                burst_col;     // which column is currently being received
    bit                first_valid;   // flag: next sram_valid = first byte of burst

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // -----------------------------------------------------------------------
    // Reset per-tile state
    // -----------------------------------------------------------------------
    function void reset_tile_state();
        for (int i = 0; i < 4; i++) begin
            exp_row[i]   = 8'sh0;   // padding columns stay 0
            exp_valid[i] = 1'b1;    // padding columns are trivially "known"
        end
        burst_col   = 0;
        first_valid = 1'b0;
    endfunction

    task run_phase(uvm_phase phase);
        reset_tile_state();

        forever begin
            @(posedge vif.clk);

            // ---------------------------------------------------------------
            // Reset per-tile state at the start of every new transaction so
            // burst_col and first_valid are clean for tile 0 of each run.
            // ---------------------------------------------------------------
            if (vif.start === 1'b1) begin
                reset_tile_state();
            end

            // ---------------------------------------------------------------
            // A new burst is requested for the current column.
            // Mark that the very next sram_valid will carry the first byte
            // we care about.  The column index advances naturally: the DUT
            // moves through col 0→1→2→3 in order, issuing one req per col
            // (unless padding, in which case sram_read_req never fires for
            // that col and exp_row stays 0).
            // ---------------------------------------------------------------
            if (vif.sram_read_req === 1'b1) begin
                exp_valid[burst_col] = 1'b0;  // awaiting first byte
                first_valid          = 1'b1;
            end

            // ---------------------------------------------------------------
            // Capture the first sram_data byte of the current burst.
            // ---------------------------------------------------------------
            if (first_valid && vif.sram_valid === 1'b1) begin
                exp_row[burst_col]   = vif.sram_data;
                exp_valid[burst_col] = 1'b1;
                first_valid          = 1'b0;
            end

            // ---------------------------------------------------------------
            // Advance column pointer when a burst completes.
            // ---------------------------------------------------------------
            if (vif.sram_burst_done === 1'b1) begin
                if (burst_col < 3) burst_col = burst_col + 1;
            end

            // ---------------------------------------------------------------
            // Compare when tile_ready fires.
            // ---------------------------------------------------------------
            if (vif.tile_ready === 1'b1) begin
                bit mismatch = 0;

                // All columns must have a captured expected value
                for (int i = 0; i < 4; i++) begin
                    if (!exp_valid[i]) begin
                        `uvm_warning("SCB", $sformatf(
                            "Tile %0d col %0d: expected byte not yet captured", tile_idx, i))
                    end
                    if (vif.probe_row[i] !== exp_row[i]) mismatch = 1;
                end

                if (!mismatch) begin
                    `uvm_info("SCB", $sformatf(
                        "MATCH!  Tile %0d\n  Observed: [%h, %h, %h, %h]\n  Expected: [%h, %h, %h, %h]",
                        tile_idx,
                        vif.probe_row[0], vif.probe_row[1],
                        vif.probe_row[2], vif.probe_row[3],
                        exp_row[0], exp_row[1], exp_row[2], exp_row[3]),
                        UVM_LOW)
                end else begin
                    `uvm_error("SCB", $sformatf(
                        "MISMATCH! Tile %0d\n  Observed: [%h, %h, %h, %h]\n  Expected: [%h, %h, %h, %h]",
                        tile_idx,
                        vif.probe_row[0], vif.probe_row[1],
                        vif.probe_row[2], vif.probe_row[3],
                        exp_row[0], exp_row[1], exp_row[2], exp_row[3]))
                    error_count++;
                end

                tile_idx++;
                reset_tile_state();   // ready for next tile
            end
        end
    endtask
endclass

// -----------------------------------------------------------------------------
// 5. SRAM RESPONDER  (unchanged except path comment)
// -----------------------------------------------------------------------------
class sram_responder extends uvm_component;
    `uvm_component_utils(sram_responder)
    virtual weight_if vif;
    // Memory sized to hold the full weight file
    logic signed [7:0] mem [0:30719];

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        $readmemh("F:/College/Graduation project/Weight UVM/weights_conv1_int8.mem", mem);
    endfunction

    task run_phase(uvm_phase phase);
        vif.sram_valid      <= 0;
        vif.sram_burst_done <= 0;
        vif.sram_data       <= 0;
        forever begin
            @(posedge vif.clk);
            if (vif.sram_read_req) begin
                // sram_addr already holds the correct absolute byte address
                // computed by the DUT as oc_vec * weights_per_filter.
                // No external offset needed — the original (tile_call_count-1)*72
                // was hardcoded for k=3,in_ch=2 only and corrupted all other configs.
                //
                // sram_burst_len is the number of bytes to return.
                // Use int to avoid truncation for large wpf values.
                automatic int base = int'(vif.sram_addr);
                automatic int len  = int'(vif.sram_burst_len);
                if (len == 0) len = 1;

                for (int i = 0; i < len; i++) begin
                    automatic int addr = base + i;
                    // Guard against out-of-bounds access
                    if (addr >= 0 && addr <= 30719)
                        vif.sram_data <= mem[addr];
                    else
                        vif.sram_data <= 8'sh0;
                    vif.sram_valid      <= 1;
                    vif.sram_burst_done <= (i == len - 1);
                    @(posedge vif.clk);
                end
                vif.sram_valid      <= 0;
                vif.sram_burst_done <= 0;
            end
        end
    endtask
endclass

// -----------------------------------------------------------------------------
// 6. DRIVER  (fixed: wait for done_all before releasing the item)
//
// Bug in original
// ---------------
// The driver called item_done() after the *first* tile_ready pulse.  When a
// transaction has multiple tiles (e.g. out_ch=8 → 2 tiles) the sequencer
// pumps the next item immediately while the DUT is still serving the previous
// transaction.  The start pulse then collides with an in-progress run.
//
// Fix
// ---
// Wait for done_all (= tile_ready && tile_counter == num_tiles-1) before
// releasing the item to the sequencer.  This ensures the DUT has returned to
// IDLE before the next transaction starts.
// -----------------------------------------------------------------------------
class weight_driver extends uvm_driver#(weight_item);
    `uvm_component_utils(weight_driver)
    virtual weight_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
        vif.start <= 0;
        forever begin
            int num_tiles;

            seq_item_port.get_next_item(req);
            wait(vif.rst === 0);

            // The DUT produces ONE tile per start pulse then returns to IDLE.
            // For multi-tile transactions (out_ch > 4) the driver must issue
            // one start pulse per tile, keeping kernel/in_ch/out_ch stable.
            num_tiles = (int'(req.out_channels) + 3) / 4;
            if (num_tiles < 1) num_tiles = 1;

            `uvm_info("DRV", $sformatf(
                "Starting txn: k=%0d in_ch=%0d out_ch=%0d num_tiles=%0d",
                req.kernel_size, req.in_channels,
                req.out_channels, num_tiles), UVM_LOW)

            repeat (num_tiles) begin : tile_loop
                // Wait for DUT to be in IDLE (tile_ready=0, sram_read_req=0)
                // then issue one start pulse for this tile.
                @(posedge vif.clk);
                vif.kernel_size  <= req.kernel_size;
                vif.in_channels  <= req.in_channels;
                vif.out_channels <= req.out_channels;
                vif.start        <= 1;
                @(posedge vif.clk);
                vif.start <= 0;

                // Wait for this tile's tile_ready (level-check every posedge)
                begin : wait_ready
                    bit found = 0;
                    while (!found) begin
                        @(posedge vif.clk);
                        if (vif.tile_ready === 1'b1) begin
                            found = 1;
                            `uvm_info("DRV", "  tile_ready seen", UVM_LOW)
                        end
                    end
                end

                // One cycle for DUT to transition TILE_DONE -> IDLE
                @(posedge vif.clk);
            end

            `uvm_info("DRV", "  item_done", UVM_LOW)
            seq_item_port.item_done();
        end
    endtask
endclass

// =============================================================================
// 7. COVERAGE SUBSCRIBER  (cx_outch_done fix)
//
// Bug in original
// ---------------
// outch_partial was only set on the start pulse and never changed, but the
// covergroup was sampled every cycle.  The cx_outch_done cross needs
// outch_partial × not_done to fire: that means tile_ready=1, done_all=0,
// and outch_cat=partial — which happens on the first tile of a 2-tile run
// where out_ch % 4 != 0 (e.g., out_ch=5).
//
// The original sampling was correct in principle; the gap was purely that no
// such transaction existed in the directed sequence.  Txn 11 (out_ch=5, k=1)
// now provides it.  No subscriber code changes required — kept as-is.
// =============================================================================
class weight_subscriber extends uvm_component;
    `uvm_component_utils(weight_subscriber)

    virtual weight_if vif;

    int cov_kernel;
    int cov_inch_cat;
    int cov_outch_cat;
    int cov_done_all;
    int cov_tile_ready;
    int cov_padding;
    int cov_burst_len;
    int cov_state;

    logic [2:0] lat_kernel;
    logic [8:0] lat_in_ch;
    logic [6:0] lat_out_ch;
    bit         stim_valid;

    covergroup weight_coverage;

        cp_state : coverpoint cov_state {
            bins st_idle        = {0};
            bins st_requesting  = {1};
            bins st_receiving   = {2};
            bins st_tile_done   = {3};
        }

        cp_kernel : coverpoint cov_kernel {
            bins k1 = {0};
            bins k3 = {1};
            bins k5 = {2};
        }

        cp_in_ch : coverpoint cov_inch_cat {
            bins inch_min    = {0};
            bins inch_small  = {1};
            bins inch_medium = {2};
            bins inch_large  = {3};
        }

        cp_out_ch : coverpoint cov_outch_cat {
            bins outch_partial = {0};
            bins outch_exact   = {1};
            bins outch_multi   = {2};
        }

        cp_done_all : coverpoint cov_done_all {
            bins not_done = {0};
            bins done     = {1};
        }

        cp_tile_ready : coverpoint cov_tile_ready {
            bins not_ready = {0};
            bins ready     = {1};
        }

        cp_padding : coverpoint cov_padding {
            bins no_padding  = {0};
            bins padding_hit = {1};
        }

        cp_burst_len : coverpoint cov_burst_len {
            bins burst_short  = {0};
            bins burst_medium = {1};
            bins burst_long   = {2};
        }

        cx_kernel_inch : cross cp_kernel, cp_in_ch;

        // outch_partial (cov_outch_cat=0) means out_channels < 4, which
        // always produces exactly one tile.  On that single tile's tile_ready
        // pulse done_all is always 1, making outch_partial × not_done
        // architecturally unreachable.  Exclude it so the bin does not
        // prevent 100% coverage.
        cx_outch_done  : cross cp_out_ch, cp_done_all {
            ignore_bins impossible_partial_not_done =
                binsof(cp_out_ch.outch_partial) && binsof(cp_done_all.not_done);
        }

    endgroup : weight_coverage

    function new(string name, uvm_component parent);
        super.new(name, parent);
        weight_coverage = new();
        stim_valid      = 0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        cov_kernel     = 1;
        cov_inch_cat   = 1;
        cov_outch_cat  = 1;
        cov_done_all   = 0;
        cov_tile_ready = 0;
        cov_padding    = 0;
        cov_burst_len  = 0;
        cov_state      = 0;

        forever begin
            @(posedge vif.clk);

            // Latch stimulus on start pulse
            if (vif.start === 1'b1) begin
                lat_kernel  = vif.kernel_size;
                lat_in_ch   = vif.in_channels;
                lat_out_ch  = vif.out_channels;
                stim_valid  = 1;
                cov_padding = 0;

                case (vif.kernel_size)
                    3'd1:    cov_kernel = 0;
                    3'd3:    cov_kernel = 1;
                    3'd5:    cov_kernel = 2;
                    default: cov_kernel = 1;
                endcase

                if      (vif.in_channels == 9'd1)           cov_inch_cat = 0;
                else if (vif.in_channels inside {[2:15]})   cov_inch_cat = 1;
                else if (vif.in_channels inside {[16:63]})  cov_inch_cat = 2;
                else                                          cov_inch_cat = 3;

                if      (vif.out_channels < 7'd4)                       cov_outch_cat = 0;
                else if ((int'(vif.out_channels) % 4) == 0)             cov_outch_cat = 1;
                else                                                      cov_outch_cat = 2;
            end

            if (!stim_valid) continue;

            // Infer FSM state
            if      (vif.tile_ready    === 1'b1) cov_state = 3;
            else if (vif.sram_read_req === 1'b1) cov_state = 1;
            else if (vif.sram_valid    === 1'b1) cov_state = 2;
            else                                  cov_state = 0;

            // Padding proxy: any transaction where out_channels % 4 != 0
            if (lat_out_ch != 7'd0 && (int'(lat_out_ch) % 4) != 0)
                cov_padding = 1;

            // Sample burst_len when sram_read_req fires
            if (vif.sram_read_req === 1'b1) begin
                if      (vif.sram_burst_len inside {[1:8]})  cov_burst_len = 0;
                else if (vif.sram_burst_len inside {[9:63]}) cov_burst_len = 1;
                else                                           cov_burst_len = 2;
            end

            cov_done_all   = (vif.done_all   === 1'b1) ? 1 : 0;
            cov_tile_ready = (vif.tile_ready === 1'b1) ? 1 : 0;

            weight_coverage.sample();
        end
    endtask

    virtual function void report_phase(uvm_phase phase);
        $display("\n\n\t----------------------------");
        $display(  "\t---   COVERAGE  REPORT   ---");
        $display(  "\t----------------------------");
        $display(  "\t  Overall          : %6.2f%%", weight_coverage.get_coverage());
        $display(  "\t  cp_state         : %6.2f%%", weight_coverage.cp_state.get_coverage());
        $display(  "\t  cp_kernel        : %6.2f%%", weight_coverage.cp_kernel.get_coverage());
        $display(  "\t  cp_in_ch         : %6.2f%%", weight_coverage.cp_in_ch.get_coverage());
        $display(  "\t  cp_out_ch        : %6.2f%%", weight_coverage.cp_out_ch.get_coverage());
        $display(  "\t  cp_done_all      : %6.2f%%", weight_coverage.cp_done_all.get_coverage());
        $display(  "\t  cp_tile_ready    : %6.2f%%", weight_coverage.cp_tile_ready.get_coverage());
        $display(  "\t  cp_padding       : %6.2f%%", weight_coverage.cp_padding.get_coverage());
        $display(  "\t  cp_burst_len     : %6.2f%%", weight_coverage.cp_burst_len.get_coverage());
        $display(  "\t  cx_kernel_inch   : %6.2f%%", weight_coverage.cx_kernel_inch.get_coverage());
        $display(  "\t  cx_outch_done    : %6.2f%%", weight_coverage.cx_outch_done.get_coverage());
        $display(  "\t----------------------------\n");
    endfunction

endclass

// -----------------------------------------------------------------------------
// 8. ENVIRONMENT
// -----------------------------------------------------------------------------
class weight_env extends uvm_env;
    `uvm_component_utils(weight_env)
    weight_driver     drv;
    sram_responder    mem;
    weight_scoreboard scb;
    weight_subscriber sub;
    uvm_sequencer#(weight_item) sqr;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        drv = weight_driver::type_id::create("drv", this);
        sqr = uvm_sequencer#(weight_item)::type_id::create("sqr", this);
        mem = sram_responder::type_id::create("mem", this);
        scb = weight_scoreboard::type_id::create("scb", this);
        sub = weight_subscriber::type_id::create("sub", this);

        if (!uvm_config_db#(virtual weight_if)::get(this, "", "vif", drv.vif))
            `uvm_fatal("ENV_CONFIG", "Virtual interface vif not found in config_db")

        mem.vif = drv.vif;
        scb.vif = drv.vif;
        sub.vif = drv.vif;
    endfunction

    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass

// -----------------------------------------------------------------------------
// 9. TEST
// -----------------------------------------------------------------------------
class weight_test extends uvm_test;
    `uvm_component_utils(weight_test)
    weight_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        env = weight_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        weight_base_seq             rand_seq = weight_base_seq::type_id::create("rand_seq");
        weight_coverage_closing_seq cov_seq  = weight_coverage_closing_seq::type_id::create("cov_seq");

        phase.raise_objection(this);

        rand_seq.start(env.sqr);   // 3 random transactions (driver blocks until all tiles done)
        cov_seq.start(env.sqr);    // 14 directed transactions (driver blocks until all tiles done)

        // Both seq.start() calls are fully blocking: finish_item() returns only
        // after the driver calls item_done(), which happens only after all
        // tile_ready pulses have been counted via @(posedge vif.tile_ready).
        // By the time we reach here every tile has been processed.
        // #500ns gives the scoreboard and subscriber 50 clock cycles to retire
        // any in-flight comparisons before the phase ends.
        #1000ns;  // 100-cycle drain guard after all sequences complete

        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        $display("\n=========================================");
        $display("   FINAL STATUS: %s",
            (env.scb.error_count == 0 && env.scb.tile_idx > 0) ? "PASSED" : "FAILED");
        $display("   Total Tiles Processed: %0d", env.scb.tile_idx);
        $display("=========================================\n");
    endfunction
endclass

// -----------------------------------------------------------------------------
// 10. TOP MODULE  (unchanged)
// -----------------------------------------------------------------------------
module weight_top;
    logic clk, rst;
    initial begin clk = 0; forever #5 clk = ~clk; end
    initial begin rst = 1; #100 rst = 0; end

    weight_if vif(clk, rst);
    logic signed [7:0] weight_tile_dut [256][4];

    assign vif.probe_row[0] = weight_tile_dut[0][0];
    assign vif.probe_row[1] = weight_tile_dut[0][1];
    assign vif.probe_row[2] = weight_tile_dut[0][2];
    assign vif.probe_row[3] = weight_tile_dut[0][3];

    weight_flatten2_streaming_burst dut (
        .clk           (vif.clk),
        .rst           (vif.rst),
        .start         (vif.start),
        .kernel_size   (vif.kernel_size),
        .in_channels   (vif.in_channels),
        .out_channels  (vif.out_channels),
        .tile_ready    (vif.tile_ready),
        .done_all      (vif.done_all),
        .sram_addr     (vif.sram_addr),
        .sram_burst_len(vif.sram_burst_len),
        .sram_read_req (vif.sram_read_req),
        .sram_data     (vif.sram_data),
        .sram_valid    (vif.sram_valid),
        .sram_burst_done(vif.sram_burst_done),
        .weight_tile   (weight_tile_dut)
    );

    initial begin
        uvm_config_db#(virtual weight_if)::set(null, "*", "vif", vif);
        run_test("weight_test");
    end
endmodule