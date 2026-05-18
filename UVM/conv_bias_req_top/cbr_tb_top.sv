// =============================================================================
// conv_bias_requant_tb.sv
// Complete UVM-1.1d testbench for conv_bias_requant_integrated
// Style matches systolic_tb.sv exactly.
// =============================================================================

package conv_bias_requant_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Declare a named imp type for the stimulus path
`uvm_analysis_imp_decl(_stimulus)
  // ============================================================
  // cbr_seq_item
  // One transaction = one full pipeline pass (start → done).
  // Stimulus: config registers + SRAM fill values.
  // Response: captured output_valid beats written by monitor.
  // ============================================================

  class cbr_seq_item extends uvm_sequence_item;

    `uvm_object_utils(cbr_seq_item)

    // ── STIMULUS FIELDS (randomized by sequences) ────────────

    rand logic [2:0]          kernel_size;    // 1..5
    rand logic [7:0]          in_channels;    // 1..16 (small for sim speed)
    rand logic [6:0]          out_channels;   // 1..8  (covers ≤2 weight tiles)
    rand logic [4:0]          input_height;   // kernel_size+1 .. 8
    rand logic [4:0]          input_width;    // kernel_size+1 .. 8
    rand logic [31:0]         requant_scale;
    rand logic [5:0]          requant_shift;
    rand logic signed [7:0]   ZP_next;
    rand logic                fc_mode;
    rand logic                enable_relu;

    // Uniform SRAM fill values – driver loads every SRAM port with these.
    // Keeping all pixels/weights identical gives a closed-form golden value.
    rand logic signed [7:0]   img_fill;       // every image pixel
    rand logic signed [7:0]   wt_fill;        // every weight
    rand logic signed [31:0]  bias_fill;      // every bias word

    // ── RESPONSE FIELDS (written by monitor, read by scoreboard) ─
    logic signed [7:0]  out_data [3:0][3:0];  // [TILE_ROWS][ARRAY_COLS]
    logic [6:0]         out_ch_start;
    logic [9:0]         out_win_start;         // $clog2(28*28)=10
    int                 out_tile_count;

    // ── CONSTRAINTS ─────────────────────────────────────────

    constraint c_kernel    { kernel_size inside {[1:3]}; }
    constraint c_channels  { in_channels  inside {[1:4]};
                             out_channels inside {[1:8]}; }
    constraint c_spatial   { input_height >= (kernel_size + 1);
                             input_height <= 8;
                             input_width  >= (kernel_size + 1);
                             input_width  <= 8; }
    // constraint c_requant   { requant_scale inside {[1 : 32'h0000FFFF]};
    //                          requant_shift inside {[1 : 16]}; }
    constraint c_requant   { requant_scale inside {[0 : 32'hFFFFFFFF]};
                         requant_shift inside {[0 : 16]}; }
    constraint c_fill      { img_fill  inside {[-4:4]};
                             wt_fill   inside {[0:2]};
                             bias_fill inside {[-64:64]}; }
    constraint c_fc_mode   { fc_mode == 1'b0; }

    // ── UTILITY METHODS ──────────────────────────────────────

    function string convert2string();
      return $sformatf(
        "ks=%0d ic=%0d oc=%0d h=%0d w=%0d scale=%0h shift=%0d zp=%0d relu=%0b img=%0d wt=%0d bias=%0d",
        kernel_size, in_channels, out_channels, input_height, input_width,
        requant_scale, requant_shift, ZP_next, enable_relu,
        img_fill, wt_fill, bias_fill);
    endfunction

    function void do_copy(uvm_object rhs);
      cbr_seq_item rhs_;
      super.do_copy(rhs);
      $cast(rhs_, rhs);
      kernel_size   = rhs_.kernel_size;
      in_channels   = rhs_.in_channels;
      out_channels  = rhs_.out_channels;
      input_height  = rhs_.input_height;
      input_width   = rhs_.input_width;
      requant_scale = rhs_.requant_scale;
      requant_shift = rhs_.requant_shift;
      ZP_next       = rhs_.ZP_next;
      fc_mode       = rhs_.fc_mode;
      enable_relu   = rhs_.enable_relu;
      img_fill      = rhs_.img_fill;
      wt_fill       = rhs_.wt_fill;
      bias_fill     = rhs_.bias_fill;
      out_data      = rhs_.out_data;
      out_ch_start  = rhs_.out_ch_start;
      out_win_start = rhs_.out_win_start;
      out_tile_count= rhs_.out_tile_count;
    endfunction

  endclass


  // ============================================================
  // cbr_driver
  // Pulls items from sequencer → drives DUT via interface signals.
  // Also acts as the SRAM memory model: responds to every SRAM
  // read-request with the item's fill values, simulating ideal
  // zero-latency memories so the pipeline can run to completion.
  // ============================================================

  class cbr_driver extends uvm_driver #(cbr_seq_item);

    `uvm_component_utils(cbr_driver)

    virtual cbr_if vif;

    // Per-driver SRAM burst state (static across task calls)
    int wt_len, wt_cnt;
    int bs_len, bs_cnt;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db #(virtual cbr_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "cbr_driver: vif not found in config_db");
    endfunction

    task run_phase(uvm_phase phase);
      apply_reset();
      forever begin
        cbr_seq_item item;
        seq_item_port.get_next_item(item);
        drive_item(item);
        seq_item_port.item_done();
      end
    endtask

    task apply_reset();
      vif.rst            <= 1'b1;
      vif.start_pipeline <= 1'b0;
      vif.kernel_size    <= '0;
      vif.in_channels    <= '0;
      vif.out_channels   <= '0;
      vif.input_height   <= '0;
      vif.input_width    <= '0;
      vif.requant_scale  <= '0;
      vif.requant_shift  <= '0;
      vif.ZP_next        <= '0;
      vif.fc_mode        <= '0;
      vif.enable_relu    <= '0;
      // SRAM response signals
      for (int p = 0; p < 3; p++) begin
        vif.img_sram_data[p]  <= '0;
        vif.img_sram_valid[p] <= 1'b0;
      end
      vif.weight_sram_data      <= '0;
      vif.weight_sram_valid     <= 1'b0;
      vif.weight_sram_burst_done<= 1'b0;
      vif.bias_sram_data        <= '0;
      vif.bias_sram_valid       <= 1'b0;
      vif.bias_sram_burst_done  <= 1'b0;
      wt_len = 0; wt_cnt = 0;
      bs_len = 0; bs_cnt = 0;
      repeat (5) @(posedge vif.clk);
      vif.rst <= 1'b0;
      repeat (3) @(posedge vif.clk);
    endtask

    task drive_item(cbr_seq_item item);
      int timeout_cnt;

      // Cycle 0: apply configuration, keep start_pipeline LOW
      @(posedge vif.clk);
      vif.kernel_size   <= item.kernel_size;
      vif.in_channels   <= item.in_channels;
      vif.out_channels  <= item.out_channels;
      vif.input_height  <= item.input_height;
      vif.input_width   <= item.input_width;
      vif.requant_scale <= item.requant_scale;
      vif.requant_shift <= item.requant_shift;
      vif.ZP_next       <= item.ZP_next;
      vif.fc_mode       <= item.fc_mode;
      vif.enable_relu   <= item.enable_relu;

      // Cycle 1: pulse start_pipeline for exactly one cycle
      @(posedge vif.clk);
      vif.start_pipeline <= 1'b1;
      @(posedge vif.clk);
      vif.start_pipeline <= 1'b0;

      // Now run SRAM memory model until pipeline_done fires
      timeout_cnt = 0;
      do begin
        @(posedge vif.clk);
        serve_img_sram(item);
        serve_weight_sram(item);
        serve_bias_sram(item);
        timeout_cnt++;
        if (timeout_cnt >= 5000) begin
          `uvm_error("DRV_TIMEOUT",
            $sformatf("pipeline_done not seen after 5000 cycles – item: %s",
              item.convert2string()))
          return;
        end
      end while (!vif.pipeline_done);

      `uvm_info("DRV",
        $sformatf("pipeline_done after %0d cycles | %s", timeout_cnt, item.convert2string()),
        UVM_HIGH)

      repeat (2) @(posedge vif.clk);
    endtask

    // ── Image SRAM: respond next cycle after req ─────────────
    task serve_img_sram(cbr_seq_item item);
      for (int p = 0; p < 3; p++) begin
        if (vif.img_sram_read_req[p]) begin
          vif.img_sram_data[p]  <= item.img_fill;
          vif.img_sram_valid[p] <= 1'b1;
        end else begin
          vif.img_sram_valid[p] <= 1'b0;
        end
      end
    endtask

    // ── Weight SRAM: burst model – stream valid every cycle ──
    task serve_weight_sram(cbr_seq_item item);
      if (vif.weight_sram_read_req) begin
        wt_len = int'(vif.weight_sram_burst_len);
        wt_cnt = 0;
      end
      if (wt_len > 0) begin
        vif.weight_sram_data  <= item.wt_fill;
        vif.weight_sram_valid <= 1'b1;
        wt_cnt++;
        if (wt_cnt >= wt_len) begin
          vif.weight_sram_burst_done <= 1'b1;
          wt_len = 0; wt_cnt = 0;
        end else begin
          vif.weight_sram_burst_done <= 1'b0;
        end
      end else begin
        vif.weight_sram_valid      <= 1'b0;
        vif.weight_sram_burst_done <= 1'b0;
      end
    endtask

    // ── Bias SRAM: burst model ───────────────────────────────
    task serve_bias_sram(cbr_seq_item item);
      if (vif.bias_sram_read_req) begin
        bs_len = int'(vif.bias_sram_burst_len);
        bs_cnt = 0;
      end
      if (bs_len > 0) begin
        vif.bias_sram_data  <= item.bias_fill;
        vif.bias_sram_valid <= 1'b1;
        bs_cnt++;
        if (bs_cnt >= bs_len) begin
          vif.bias_sram_burst_done <= 1'b1;
          bs_len = 0; bs_cnt = 0;
        end else begin
          vif.bias_sram_burst_done <= 1'b0;
        end
      end else begin
        vif.bias_sram_valid      <= 1'b0;
        vif.bias_sram_burst_done <= 1'b0;
      end
    endtask

  endclass


  // ============================================================
  // cbr_monitor
  // Passive observer. Captures every output_valid beat.
  // Broadcasts completed transactions to analysis port.
  // ============================================================

  class cbr_monitor extends uvm_monitor;

    `uvm_component_utils(cbr_monitor)

    virtual cbr_if vif;

    uvm_analysis_port #(cbr_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      ap = new("ap", this);
      if (!uvm_config_db #(virtual cbr_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "cbr_monitor: vif not found");
    endfunction

    task run_phase(uvm_phase phase);
      cbr_seq_item item;
      forever begin
        @(posedge vif.clk);
        if (vif.rst)          continue;
        if (!vif.output_valid) continue;

        item = cbr_seq_item::type_id::create("item");

        for (int r = 0; r < 4; r++)
        for (int c = 0; c < 4; c++)
          item.out_data[r][c] = vif.output_data[r][c];

        item.out_ch_start  = vif.output_channel_start;
        item.out_win_start = vif.output_window_idx_start;

        ap.write(item);

        `uvm_info("MON",
          $sformatf("output_valid: ch=%0d win=%0d data[0][0]=%0d",
            item.out_ch_start, item.out_win_start, item.out_data[0][0]),
          UVM_MEDIUM)
      end
    endtask

  endclass


  // ============================================================
  // cbr_agent
  // Bundles: sequencer + driver + monitor.
  // ============================================================

  class cbr_agent extends uvm_agent;

    `uvm_component_utils(cbr_agent)

    uvm_sequencer #(cbr_seq_item) sequencer;
    cbr_driver                    driver;
    cbr_monitor                   monitor;

    uvm_analysis_port #(cbr_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      monitor   = cbr_monitor::type_id::create("monitor", this);
      if (get_is_active() == UVM_ACTIVE) begin
        sequencer = uvm_sequencer#(cbr_seq_item)::type_id::create("sequencer", this);
        driver    = cbr_driver::type_id::create("driver", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      ap = monitor.ap;
      if (get_is_active() == UVM_ACTIVE)
        driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

  endclass


  // ============================================================
  // cbr_scoreboard
  // Receives monitor transactions. Computes expected output
  // using the closed-form reference model. Compares and reports.
  //
  // Reference model (uniform fill stimulus):
  //   acc     = img_fill * wt_fill * (ks*ks*ic)   [32-bit]
  //   biased  = acc + bias_fill
  //   if relu && biased < 0 → biased = 0
  //   prod    = biased * requant_scale             [64-bit]
  //   round   = shift==0 ? 0 : (prod>=0 ? 1<<(s-1) : (1<<(s-1))-1)
  //   shifted = (prod + round) >> shift
  //   final   = shifted + ZP_next
  //   output  = clamp(final, -128, 127)
  // ============================================================

  class cbr_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(cbr_scoreboard)

    uvm_analysis_imp #(cbr_seq_item, cbr_scoreboard) analysis_export;

    // Current item under test – set by test before each sequence
    cbr_seq_item current_item;

    int unsigned total_tiles  = 0;
    int unsigned total_errors = 0;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      analysis_export = new("analysis_export", this);
    endfunction

    function void write(cbr_seq_item item);
      logic signed [7:0] exp_val;
      total_tiles++;

      if (current_item == null) begin
        `uvm_warning("SB", "current_item not set – skipping check");
        return;
      end

      exp_val = compute_expected(current_item);

      // Check representative element [0][0]
      if (item.out_data[0][0] !== exp_val) begin
        total_errors++;
        `uvm_error("SB_MISMATCH",
          $sformatf("tile=%0d [0][0]: GOT=%0d EXPECTED=%0d | %s",
            total_tiles, item.out_data[0][0], exp_val,
            current_item.convert2string()))
      end else begin
        `uvm_info("SB_PASS",
          $sformatf("tile=%0d PASSED [0][0]=%0d", total_tiles, item.out_data[0][0]),
          UVM_HIGH)
      end
    endfunction

    function automatic logic signed [7:0] compute_expected(cbr_seq_item it);
      longint signed acc, biased, prod, rnd, shifted, final_val;
      int win_size;

      win_size = int'(it.kernel_size) * int'(it.kernel_size) * int'(it.in_channels);
      acc      = longint'(signed'(it.img_fill)) * longint'(signed'(it.wt_fill)) * longint'(win_size);
      biased   = acc + longint'(signed'(it.bias_fill));
      if (it.enable_relu && biased < 0) biased = 0;

      prod = biased * longint'({1'b0, it.requant_scale});

      if (it.requant_shift == 0)
        rnd = 0;
      else if (prod >= 0)
        rnd = (64'sd1 <<< (it.requant_shift - 1));
      else
        rnd = (64'sd1 <<< (it.requant_shift - 1)) - 64'sd1;

      shifted   = (prod + rnd) >>> it.requant_shift;
      final_val = shifted + longint'(signed'(it.ZP_next));

      if      (final_val >  127) return  8'sd127;
      else if (final_val < -128) return -8'sd128;
      else return $signed(final_val[7:0]);
    endfunction

    function void report_phase(uvm_phase phase);
      if (total_errors == 0)
        `uvm_info("SB_FINAL",
          $sformatf("ALL %0d TILES PASSED", total_tiles), UVM_NONE)
      else
        `uvm_error("SB_FINAL",
          $sformatf("%0d ERRORS in %0d tiles", total_errors, total_tiles));
    endfunction

  endclass

class cbr_coverage extends uvm_subscriber #(cbr_seq_item);

  `uvm_component_utils(cbr_coverage)

  // Second port receives the stimulus item from the sequence
  uvm_analysis_imp_stimulus #(cbr_seq_item, cbr_coverage) stimulus_export;

  covergroup cbr_cg with function sample(cbr_seq_item t);

    cp_kernel_size: coverpoint t.kernel_size {
      bins k1 = {1}; bins k2 = {2}; bins k3 = {3};
    }
    cp_in_channels: coverpoint t.in_channels {
      bins small_bin  = {[1:2]}; bins medium_bin = {[3:4]};
    }
    cp_out_channels: coverpoint t.out_channels {
      bins one_tile = {[1:4]}; bins two_tile = {[5:8]};
    }
    cp_enable_relu: coverpoint t.enable_relu {
      bins relu_off = {0}; bins relu_on = {1};
    }
    cp_requant_shift: coverpoint t.requant_shift {
      bins shift_zero = {0};
      bins shift_low  = {[1:7]};
      bins shift_high = {[8:16]};
    }
    cp_zp_sign: coverpoint t.ZP_next[7] {
      bins zp_pos = {0}; bins zp_neg = {1};
    }
    cp_img_sign: coverpoint t.img_fill[7] {
      bins img_pos = {0}; bins img_neg = {1};
    }
    cp_wt_value: coverpoint t.wt_fill {
      bins wt_zero = {0}; bins wt_nonzero = {[1:2]};
    }
    cp_bias_sign: coverpoint t.bias_fill[31] {
      bins bias_pos = {0}; bins bias_neg = {1};
    }

    cx_relu_img:   cross cp_enable_relu,   cp_img_sign;
    cx_kernel_ic:  cross cp_kernel_size,   cp_in_channels;
    cx_shift_bias: cross cp_requant_shift, cp_bias_sign;
    cx_zp_relu:    cross cp_zp_sign,       cp_enable_relu;

  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cbr_cg = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // The inherited analysis_export comes from uvm_subscriber
    // This new port receives stimulus items
    stimulus_export = new("stimulus_export", this);
  endfunction

  // Called by monitor (response path) — ignore for coverage
  function void write(cbr_seq_item t);
    // Response items don't carry stimulus fields — do nothing here
  endfunction

  // Called by sequences (stimulus path) — THIS is what we sample
  function void write_stimulus(cbr_seq_item t);
    cbr_cg.sample(t);
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV",
      $sformatf("Functional coverage = %.2f%%", cbr_cg.get_coverage()),
      UVM_NONE)
  endfunction

endclass

  // ============================================================
  // cbr_env
  // Creates agent + scoreboard. Wires analysis port in connect.
  // ============================================================

  class cbr_env extends uvm_env;

    `uvm_component_utils(cbr_env)

    cbr_agent      agent;
    cbr_scoreboard scoreboard;
    cbr_coverage   coverage;
    // Broadcast port for stimulus items — sequences write here
  uvm_analysis_port #(cbr_seq_item) stimulus_ap; 

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent      = cbr_agent     ::type_id::create("agent",      this);
      scoreboard = cbr_scoreboard::type_id::create("scoreboard", this);
      coverage   = cbr_coverage  ::type_id::create("coverage",   this);
      stimulus_ap = new("stimulus_ap", this);   // ADD
    endfunction

    function void connect_phase(uvm_phase phase);
      agent.ap.connect(scoreboard.analysis_export);
       agent.ap.connect(coverage.analysis_export); 
       // Stimulus port connects to coverage's stimulus export
    stimulus_ap.connect(coverage.stimulus_export);  // ADD
    endfunction

  endclass



  // ============================================================
  // SEQUENCES
  // ============================================================

  // ── Smoke sequence: single fixed transaction ─────────────
  class cbr_smoke_seq extends uvm_sequence #(cbr_seq_item);
    `uvm_object_utils(cbr_smoke_seq)

    function new(string name = "cbr_smoke_seq");
      super.new(name);
    endfunction

    task body();
      cbr_seq_item item;
      item = cbr_seq_item::type_id::create("item");
      start_item(item);
      if (!item.randomize() with {
        kernel_size   == 3'd3;
        in_channels   == 8'd2;
        out_channels  == 7'd4;
        input_height  == 5'd5;
        input_width   == 5'd5;
        requant_scale == 32'h0000_0080;
        requant_shift == 6'd7;
        ZP_next       == 8'sd0;
        enable_relu   == 1'b0;
        fc_mode       == 1'b0;
        img_fill      == 8'sd1;
        wt_fill       == 8'sd1;
        bias_fill     == 32'sd0;
      }) `uvm_fatal("RAND", "Smoke randomize failed");
      finish_item(item);
      `uvm_info("SMOKE_SEQ", {"Smoke item sent: ", item.convert2string()}, UVM_MEDIUM)
    endtask

  endclass


  // ── Random sequence ──────────────────────────────────────
  class cbr_rand_seq extends uvm_sequence #(cbr_seq_item);
    `uvm_object_utils(cbr_rand_seq)

    int num_transactions = 20;

    // FIX: scoreboard handle set by the test before seq.start().
    // The sequence sets current_item AFTER randomize() (params locked in)
    // but BEFORE finish_item() (before the driver touches the DUT).
    // This guarantees every output_valid beat is checked against the
    // correct reference — no off-by-one-transaction lag.
    cbr_scoreboard scoreboard;
    uvm_analysis_port #(cbr_seq_item) cov_ap;  // ADD

    function new(string name = "cbr_rand_seq");
      super.new(name);
    endfunction

    task body();
      cbr_seq_item item;
      repeat (num_transactions) begin
        item = cbr_seq_item::type_id::create("item");
        start_item(item);
        if (!item.randomize()) `uvm_fatal("RAND", "Randomize failed");
        // Set reference BEFORE finish_item so the scoreboard is ready
        // before the driver sends anything to the DUT.
        if (scoreboard != null)
          scoreboard.current_item = item;

        if (cov_ap != null)     cov_ap.write(item);     // ADD

        finish_item(item);
      end
    endtask

  endclass


  class cbr_corner_seq extends uvm_sequence #(cbr_seq_item);
    `uvm_object_utils(cbr_corner_seq)

    // ADD THIS: scoreboard handle set by test before seq.start()
    cbr_scoreboard scoreboard;
    uvm_analysis_port #(cbr_seq_item) cov_ap;  // ADD

    function new(string name = "cbr_corner_seq");
        super.new(name);
    endfunction

    
    task body();
  cbr_seq_item item;

  // Corner 1
  item = cbr_seq_item::type_id::create("c1");
  start_item(item);
  item.c_fill.constraint_mode(0);
  if (!item.randomize() with {
    kernel_size==3'd1; in_channels==8'd1; out_channels==7'd1;
    input_height==5'd3; input_width==5'd3;
    requant_scale==32'h0000_0100; requant_shift==6'd8;
    ZP_next==8'sd0; enable_relu==1'b1; fc_mode==1'b0;
    img_fill==8'sd3; wt_fill==8'sd1; bias_fill==32'sd10;
  }) `uvm_fatal("RAND","Corner 1 failed")
  item.c_fill.constraint_mode(1);
  if (scoreboard != null) scoreboard.current_item = item;
  if (cov_ap != null)     cov_ap.write(item);       // ✓ already present
  finish_item(item);
  `uvm_info("CORNER_SEQ","Sent c1: min kernel, relu ON, pos bias",UVM_MEDIUM)

  // Corner 2
  item = cbr_seq_item::type_id::create("c2");
  start_item(item);
  item.c_fill.constraint_mode(0);
  if (!item.randomize() with {
    kernel_size==3'd1; in_channels==8'd1; out_channels==7'd4;
    input_height==5'd3; input_width==5'd3;
    requant_scale==32'h0000_0001; requant_shift==6'd0;
    ZP_next==8'sd0; enable_relu==1'b1; fc_mode==1'b0;
    img_fill==8'sd1; wt_fill==8'sd1; bias_fill==-32'sd200;
  }) `uvm_fatal("RAND","Corner 2 failed")
  item.c_fill.constraint_mode(1);
  if (scoreboard != null) scoreboard.current_item = item;
  if (cov_ap != null)     cov_ap.write(item);       // ← ADD
  finish_item(item);
  `uvm_info("CORNER_SEQ","Sent c2: neg bias + relu -> expect all 0",UVM_MEDIUM)

  // Corner 3
  item = cbr_seq_item::type_id::create("c3");
  start_item(item);
  item.c_fill.constraint_mode(0);
  if (!item.randomize() with {
    kernel_size==3'd2; in_channels==8'd4; out_channels==7'd4;
    input_height==5'd4; input_width==5'd4;
    requant_scale==32'hFFFF_FFFF; requant_shift==6'd1;
    ZP_next==8'sd127; enable_relu==1'b0; fc_mode==1'b0;
    img_fill==8'sd2; wt_fill==8'sd2; bias_fill==32'sd1000;
  }) `uvm_fatal("RAND","Corner 3 failed")
  item.c_fill.constraint_mode(1);
  if (scoreboard != null) scoreboard.current_item = item;
  if (cov_ap != null)     cov_ap.write(item);       // ← ADD
  finish_item(item);
  `uvm_info("CORNER_SEQ","Sent c3: large scale -> expect +127 saturate",UVM_MEDIUM)

  // Corner 4
  item = cbr_seq_item::type_id::create("c4");
  start_item(item);
  item.c_fill.constraint_mode(0);
  if (!item.randomize() with {
    kernel_size==3'd1; in_channels==8'd1; out_channels==7'd4;
    input_height==5'd3; input_width==5'd3;
    requant_scale==32'h0000_0001; requant_shift==6'd0;
    ZP_next==-8'sd128; enable_relu==1'b0; fc_mode==1'b0;
    img_fill==8'sd0; wt_fill==8'sd0; bias_fill==32'sd0;
  }) `uvm_fatal("RAND","Corner 4 failed")
  item.c_fill.constraint_mode(1);
  if (scoreboard != null) scoreboard.current_item = item;
  if (cov_ap != null)     cov_ap.write(item);       // ← ADD
  finish_item(item);
  `uvm_info("CORNER_SEQ","Sent c4: acc=0, ZP=-128 -> expect -128 saturate",UVM_MEDIUM)

  // Corner 5: shift_low [1:7] + negative bias → hits <shift_low, bias_neg>
item = cbr_seq_item::type_id::create("c5");
start_item(item);
item.c_fill.constraint_mode(0);
if (!item.randomize() with {
    kernel_size  == 3'd1;  in_channels == 8'd1; out_channels == 7'd1;
    input_height == 5'd3;  input_width  == 5'd3;
    requant_scale == 32'h0000_0010;
    requant_shift == 6'd4;        // shift_low: inside [1:7]
    ZP_next       == 8'sd0;
    enable_relu   == 1'b0;
    fc_mode       == 1'b0;
    img_fill      == 8'sd1;
    wt_fill       == 8'sd1;
    bias_fill     == -32'sd5;     // bias_neg: bit[31]=1
}) `uvm_fatal("RAND","Corner 5 failed")
item.c_fill.constraint_mode(1);
if (scoreboard != null) scoreboard.current_item = item;
if (cov_ap     != null) cov_ap.write(item);
finish_item(item);
`uvm_info("CORNER_SEQ","Sent c5: shift_low + neg bias -> closes cx_shift_bias",UVM_MEDIUM)

endtask

endclass


  // ============================================================
  // TESTS
  // ============================================================

  // ── Base test ────────────────────────────────────────────
  class cbr_base_test extends uvm_test;

    `uvm_component_utils(cbr_base_test)

    cbr_env env;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = cbr_env::type_id::create("env", this);
    endfunction

    function uvm_sequencer #(cbr_seq_item) get_sequencer();
      return env.agent.sequencer;
    endfunction

    // Helper: point scoreboard at a reference item, then run the sequence
    task run_seq(uvm_sequence #(cbr_seq_item) seq, cbr_seq_item ref_item);
      env.scoreboard.current_item = ref_item;
      seq.start(get_sequencer());
    endtask

  endclass


  // ── Smoke test ───────────────────────────────────────────
  class cbr_smoke_test extends cbr_base_test;

    `uvm_component_utils(cbr_smoke_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      cbr_smoke_seq  seq;
      cbr_seq_item   ref_item;

      phase.raise_objection(this);

      `uvm_info("TEST", "=== SMOKE TEST ===", UVM_NONE)

      seq      = cbr_smoke_seq::type_id::create("seq");
      ref_item = cbr_seq_item ::type_id::create("ref");
      void'(ref_item.randomize() with {
        kernel_size   == 3'd3; in_channels == 8'd2; out_channels == 7'd4;
        input_height  == 5'd5; input_width  == 5'd5;
        requant_scale == 32'h0000_0080; requant_shift == 6'd7;
        ZP_next == 8'sd0; enable_relu == 1'b0; fc_mode == 1'b0;
        img_fill == 8'sd1; wt_fill == 8'sd1; bias_fill == 32'sd0;
      });

      run_seq(seq, ref_item);

      phase.drop_objection(this);
    endtask

  endclass


  // ── Random test ─────────────────────────────────────────
  class cbr_rand_test extends cbr_base_test;

    `uvm_component_utils(cbr_rand_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction


    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      `uvm_info("TEST", "=== RANDOM TEST (20 txns) ===", UVM_NONE)
      for (int i = 0; i < 20; i++) begin
        cbr_rand_seq seq;
        seq = cbr_rand_seq::type_id::create($sformatf("seq_%0d", i));
        seq.num_transactions = 1;
        // FIX: give the sequence the scoreboard handle so it can set
        // current_item between randomize() and finish_item().
        seq.scoreboard = env.scoreboard;
        seq.cov_ap     = env.stimulus_ap;   // ADD
        seq.start(get_sequencer());
      end
      phase.drop_objection(this);
    endtask


  endclass


  // ── Corner test ─────────────────────────────────────────
  class cbr_corner_test extends cbr_base_test;

    `uvm_component_utils(cbr_corner_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      cbr_corner_seq seq;
      cbr_seq_item   ref_item;

      phase.raise_objection(this);

      `uvm_info("TEST", "=== CORNER TEST ===", UVM_NONE)

      seq      = cbr_corner_seq::type_id::create("seq");
      seq.scoreboard = env.scoreboard;   // ADD THIS
         seq.cov_ap     = env.stimulus_ap;  // ADD
      ref_item = cbr_seq_item  ::type_id::create("ref");
      // Reference matches first corner item
      void'(ref_item.randomize() with {
        kernel_size   == 3'd1; in_channels == 8'd1; out_channels == 7'd1;
        input_height  == 5'd3; input_width  == 5'd3;
        requant_scale == 32'h0000_0100; requant_shift == 6'd8;
        ZP_next == 8'sd0; enable_relu == 1'b1; fc_mode == 1'b0;
        img_fill == 8'sd3; wt_fill == 8'sd1; bias_fill == 32'sd10;
      });

    //   run_seq(seq, ref_item);
      seq.start(get_sequencer());

      phase.drop_objection(this);
    endtask

  endclass


  // ── Full test: corners → random, back to back ────────────
  class cbr_full_test extends cbr_base_test;

    `uvm_component_utils(cbr_full_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
  cbr_corner_seq corner_seq;
  cbr_rand_seq   rand_seq;
  cbr_seq_item   ref_item;

  phase.raise_objection(this);

  ref_item = cbr_seq_item::type_id::create("ref");

  // Phase 1: corners
  `uvm_info("TEST", "=== PHASE 1: Corner Cases ===", UVM_NONE)
  void'(ref_item.randomize() with {
    kernel_size==3'd1; in_channels==8'd1; out_channels==7'd1;
    input_height==5'd3; input_width==5'd3;
    requant_scale==32'h0000_0100; requant_shift==6'd8;
    ZP_next==8'sd0; enable_relu==1'b1; fc_mode==1'b0;
    img_fill==8'sd3; wt_fill==8'sd1; bias_fill==32'sd10;
  });
  corner_seq            = cbr_corner_seq::type_id::create("corners");
  corner_seq.scoreboard = env.scoreboard;
  corner_seq.cov_ap     = env.stimulus_ap;  // MOVED HERE, corner_seq not rand_seq
  corner_seq.start(get_sequencer());

  // Phase 2: random
  `uvm_info("TEST", "=== PHASE 2: Random (20 txns) ===", UVM_NONE)
  rand_seq                 = cbr_rand_seq::type_id::create("rand"); // CREATE FIRST
  rand_seq.num_transactions = 20;
  rand_seq.scoreboard      = env.scoreboard;
  rand_seq.cov_ap          = env.stimulus_ap;  // THEN assign
  rand_seq.start(get_sequencer());

  phase.drop_objection(this);
endtask

  endclass

endpackage


// ============================================================
// cbr_if
// Physical interface between UVM env and the DUT.
// Parameters must match DUT instantiation in top module.
// ============================================================

interface cbr_if #(
  parameter int TILE_ROWS     = 4,
  parameter int ARRAY_COLS    = 4,
  parameter int MAX_OUT_CH    = 120,
  parameter int MAX_IN_CH     = 256,
  parameter int MAX_KS        = 5,
  parameter int MAX_H         = 28,
  parameter int MAX_W         = 28,
  parameter int NUM_IMG_PORTS = 3,
  parameter int MAX_BURST_LEN = 256,
  parameter int DATA_WIDTH    = 8,
  parameter int MAX_WIN_SIZE  = 256
)(
  input logic clk
);

  // ── Control / Config ────────────────────────────────────
  logic                             rst;
  logic [$clog2(MAX_KS+1)-1:0]     kernel_size;
  logic [$clog2(MAX_IN_CH+1)-1:0]  in_channels;
  logic [$clog2(MAX_OUT_CH+1)-1:0] out_channels;
  logic [$clog2(MAX_H+1)-1:0]      input_height;
  logic [$clog2(MAX_W+1)-1:0]      input_width;
  logic [31:0]                      requant_scale;
  logic [5:0]                       requant_shift;
  logic signed [7:0]                ZP_next;
  logic                             start_pipeline;
  logic                             fc_mode;
  logic                             enable_relu;
  logic                             pipeline_done;

  // ── Image SRAM ──────────────────────────────────────────
  logic [9:0]                    img_sram_addr     [NUM_IMG_PORTS];
  logic                          img_sram_read_req [NUM_IMG_PORTS];
  logic signed [DATA_WIDTH-1:0]  img_sram_data     [NUM_IMG_PORTS];
  logic                          img_sram_valid    [NUM_IMG_PORTS];

  // ── Weight SRAM ─────────────────────────────────────────
  logic [$clog2(MAX_OUT_CH*MAX_WIN_SIZE)-1:0] weight_sram_addr;
  logic [$clog2(MAX_BURST_LEN+1)-1:0]         weight_sram_burst_len;
  logic                                         weight_sram_read_req;
  logic signed [DATA_WIDTH-1:0]                weight_sram_data;
  logic                                         weight_sram_valid;
  logic                                         weight_sram_burst_done;

  // ── Bias SRAM ───────────────────────────────────────────
  logic [$clog2(MAX_OUT_CH)-1:0]      bias_sram_addr;
  logic [$clog2(MAX_BURST_LEN+1)-1:0] bias_sram_burst_len;
  logic                                bias_sram_read_req;
  logic signed [31:0]                  bias_sram_data;
  logic                                bias_sram_valid;
  logic                                bias_sram_burst_done;

  // ── Output ──────────────────────────────────────────────
  logic                             output_valid;
  logic signed [7:0]                output_data [TILE_ROWS][ARRAY_COLS];
  logic [$clog2(MAX_OUT_CH)-1:0]    output_channel_start;
  logic [$clog2(MAX_H*MAX_W)-1:0]   output_window_idx_start;

  // ── Assertions ──────────────────────────────────────────
  // pipeline_done must not stay high indefinitely while start is low
  AP_DONE_CLEARS:
  assert property (@(posedge clk) disable iff (rst)
    (pipeline_done |=> !pipeline_done || start_pipeline))
  else $error("IF_ASSERT: pipeline_done held >1 cycle without restart");

endinterface

module conv_bias_requant_integrated #(
    parameter MAX_KERNEL_SIZE   = 5,
    parameter MAX_WIN_SIZE      = 256,
    parameter MAX_IN_CHANNELS   = 256,
    parameter MAX_OUT_CHANNELS  = 120,
    parameter MAX_INPUT_HEIGHT  = 28,
    parameter MAX_INPUT_WIDTH   = 28,
    parameter TILE_ROWS         = 4,
    parameter ARRAY_COLS        = 4,
    parameter DATA_WIDTH        = 8,
    parameter NUM_IMG_PORTS     = 3,
    parameter MAX_BURST_LEN     = 256,
    parameter TOTAL_ELEMENTS    = 32768
)(
    input  logic clk,
    input  logic rst,

    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    input logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels,
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,
    input logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height,
    input logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width,

    input logic [31:0]          requant_scale,
    input logic [5:0]           requant_shift,
    input logic signed [7:0]    ZP_next,

    input  logic start_pipeline,
    input  logic fc_mode,
    input  logic enable_relu,
    output logic pipeline_done,

    // FIX 3: width matches conv_top's port exactly
    output logic [9:0]
                                               img_sram_addr [NUM_IMG_PORTS],
    output logic                               img_sram_read_req [NUM_IMG_PORTS],
    input  logic signed [DATA_WIDTH-1:0]       img_sram_data [NUM_IMG_PORTS],
    input  logic                               img_sram_valid [NUM_IMG_PORTS],

    output logic [$clog2(MAX_OUT_CHANNELS*MAX_WIN_SIZE)-1:0]
                                               weight_sram_addr,
    output logic [$clog2(MAX_BURST_LEN+1)-1:0] weight_sram_burst_len,
    output logic                                weight_sram_read_req,
    input  logic signed [DATA_WIDTH-1:0]        weight_sram_data,
    input  logic                                weight_sram_valid,
    input  logic                                weight_sram_burst_done,

    output logic [$clog2(MAX_OUT_CHANNELS)-1:0] bias_sram_addr,
    output logic [$clog2(MAX_BURST_LEN+1)-1:0]  bias_sram_burst_len,
    output logic                                  bias_sram_read_req,
    input  logic signed [31:0]                   bias_sram_data,
    input  logic                                  bias_sram_valid,
    input  logic                                  bias_sram_burst_done,

    output logic output_valid,
    output logic signed [7:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(MAX_OUT_CHANNELS)-1:0]                 output_channel_start,
    output logic [$clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH)-1:0] output_window_idx_start
);

    localparam WIN_IDX_W = $clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH);

    // =========================================================================
    // Inter-module signals
    // =========================================================================
    logic conv_done;
    logic conv_output_valid;
    logic signed [4*DATA_WIDTH-1:0] conv_output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(MAX_OUT_CHANNELS)-1:0] conv_channel_start;
    logic [WIN_IDX_W-1:0]               conv_window_idx_start;

    logic bias_output_valid;
    logic signed [31:0] bias_output_data [TILE_ROWS][ARRAY_COLS];
    logic [$clog2(MAX_OUT_CHANNELS)-1:0] bias_channel_start;
    logic [$clog2(1024)-1:0]             bias_window_idx_start;

    // FIX 1: requant_start = bias_output_valid (not meta_valid[4])
    logic requant_start;
    assign requant_start = bias_output_valid;

    logic signed [7:0] requant_output [TILE_ROWS][ARRAY_COLS];

    // =========================================================================
    // PIPELINE CONTROL FSM
    // =========================================================================
    typedef enum logic [2:0] {
        IDLE, CONV_RUNNING, WAITING_FINAL_OUTPUT, DONE
    } pipeline_state_t;

    pipeline_state_t state;

    logic [7:0] conv_tiles_sent;
    logic [7:0] output_tiles_received;
    logic [7:0] drain_counter;

    // Metadata shift register ? 4 stages to match requant pipeline depth
    // FIX 2: meta_win width matches WIN_IDX_W, not $clog2(1024)
    logic [$clog2(MAX_OUT_CHANNELS)-1:0] meta_ch  [1:4];
    logic [WIN_IDX_W-1:0]               meta_win [1:4];
    logic                                meta_valid [1:4];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state                   <= IDLE;
            pipeline_done           <= 1'b0;
            output_valid            <= 1'b0;
            conv_tiles_sent         <= '0;
            output_tiles_received   <= '0;
            drain_counter           <= '0;
            output_channel_start    <= '0;
            output_window_idx_start <= '0;
            for (int i = 1; i <= 4; i++) begin
                meta_ch[i]    <= '0;
                meta_win[i]   <= '0;
                meta_valid[i] <= 1'b0;
            end
        end else begin
            output_valid <= 1'b0;

            if (conv_output_valid)
                conv_tiles_sent <= conv_tiles_sent + 1;

            if (output_valid)
                output_tiles_received <= output_tiles_received + 1;

            // Metadata shift register ? stage 1 captures bias output timing
            // FIX 2: zero-extend bias_window_idx_start to WIN_IDX_W bits
            meta_valid[1] <= bias_output_valid;
            meta_ch[1]    <= bias_channel_start;
            meta_win[1]   <= WIN_IDX_W'(bias_window_idx_start);

            for (int i = 2; i <= 4; i++) begin
                meta_valid[i] <= meta_valid[i-1];
                meta_ch[i]    <= meta_ch[i-1];
                meta_win[i]   <= meta_win[i-1];
            end

            // Output fires 4 cycles after bias_output_valid (requant latency)
            if (meta_valid[4]) begin
                output_valid            <= 1'b1;
                output_channel_start    <= meta_ch[4];
                output_window_idx_start <= meta_win[4];
            end

            case (state)
                IDLE: begin
                    pipeline_done         <= 1'b0;
                    drain_counter         <= '0;
                    conv_tiles_sent       <= '0;
                    output_tiles_received <= '0;
                    if (start_pipeline)
                        state <= CONV_RUNNING;
                end

                CONV_RUNNING: begin
                    if (conv_done && !conv_output_valid) begin
                        state         <= WAITING_FINAL_OUTPUT;
                        drain_counter <= '0;
                    end
                end

                WAITING_FINAL_OUTPUT: begin
                    drain_counter <= drain_counter + 1;
                    if (output_tiles_received >= conv_tiles_sent && conv_tiles_sent > 0)
                        state <= DONE;
                    if (drain_counter > 50)
                        state <= DONE;
                end

                DONE: begin
                    pipeline_done <= 1'b1;
                    if (!start_pipeline)
                        state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // =========================================================================
    // MODULE 1: CONVOLUTION
    // =========================================================================
    conv_top_v2_hybrid #(
        .MAX_KERNEL_SIZE  (MAX_KERNEL_SIZE),
        .MAX_IN_CHANNELS  (MAX_IN_CHANNELS),
        .MAX_OUT_CHANNELS (MAX_OUT_CHANNELS),
        .MAX_INPUT_HEIGHT (MAX_INPUT_HEIGHT),
        .MAX_INPUT_WIDTH  (MAX_INPUT_WIDTH),
        .TILE_ROWS        (TILE_ROWS),
        .ARRAY_COLS       (ARRAY_COLS),
        .DATA_WIDTH       (DATA_WIDTH),
        .NUM_IMG_PORTS    (NUM_IMG_PORTS),
        .MAX_BURST_LEN    (MAX_BURST_LEN),
        .TOTAL_ELEMENTS   (TOTAL_ELEMENTS)
    ) conv_module (
        .clk                    (clk),
        .rst                    (rst),
        .start_conv             (start_pipeline),
        .conv_done              (conv_done),
        .fc_mode                (fc_mode),
        .kernel_size            (kernel_size),
        .in_channels            (in_channels),
        .out_channels           (out_channels),
        .input_height           (input_height),
        .input_width            (input_width),
        .img_sram_addr          (img_sram_addr),
        .img_sram_read_req      (img_sram_read_req),
        .img_sram_data          (img_sram_data),
        .img_sram_valid         (img_sram_valid),
        .weight_sram_addr       (weight_sram_addr),
        .weight_sram_burst_len  (weight_sram_burst_len),
        .weight_sram_read_req   (weight_sram_read_req),
        .weight_sram_data       (weight_sram_data),
        .weight_sram_valid      (weight_sram_valid),
        .weight_sram_burst_done (weight_sram_burst_done),
        .output_valid           (conv_output_valid),
        .output_data            (conv_output_data),
        .output_channel_start   (conv_channel_start),
        .output_window_idx_start(conv_window_idx_start)
    );

    // =========================================================================
    // MODULE 2: BIAS + RELU
    // =========================================================================
    bias_add_relu_streaming #(
        .MAX_OUT_CHANNELS (MAX_OUT_CHANNELS),
        .TILE_ROWS        (TILE_ROWS),
        .ARRAY_COLS       (ARRAY_COLS),
        .DATA_WIDTH       (32),
        .BIAS_WIDTH       (32),
        .MAX_BURST_LEN    (MAX_BURST_LEN)
    ) bias_relu_module (
        .clk                    (clk),
        .rst                    (rst),
        .enable_relu            (enable_relu),
        .out_channels           (out_channels),
        .conv_valid             (conv_output_valid),
        .conv_data              (conv_output_data),
        .conv_channel_start     (conv_channel_start),
        .conv_window_idx_start  (conv_window_idx_start[($clog2(1024)-1):0]),
        .bias_sram_addr         (bias_sram_addr),
        .bias_sram_burst_len    (bias_sram_burst_len),
        .bias_sram_read_req     (bias_sram_read_req),
        .bias_sram_data         (bias_sram_data),
        .bias_sram_valid        (bias_sram_valid),
        .bias_sram_burst_done   (bias_sram_burst_done),
        .output_valid           (bias_output_valid),
        .output_data            (bias_output_data),
        .output_channel_start   (bias_channel_start),
        .output_window_idx_start(bias_window_idx_start)
    );

    // =========================================================================
    // MODULE 3: REQUANTIZATION
    // FIX 1: start = bias_output_valid so sys_out is latched while data is valid
    // =========================================================================
    requantization_block #(
        .sys_row (TILE_ROWS),
        .sys_col (ARRAY_COLS)
    ) requant_module (
        .clk          (clk),
        .rst          (rst),
        .start        (requant_start),   // = bias_output_valid
        .requant_scale(requant_scale),
        .requant_shift(requant_shift),
        .ZP_next      (ZP_next),
        .sys_out      (bias_output_data),
        .requant_out  (requant_output)
    );

    // =========================================================================
    // OUTPUT ? requant_output is valid when output_valid fires (meta_valid[4])
    // =========================================================================
    always_comb begin
        for (int r = 0; r < TILE_ROWS; r++)
            for (int c = 0; c < ARRAY_COLS; c++)
                output_data[r][c] = requant_output[r][c];
    end

endmodule
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
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels_buf;  // latched at conv_valid

    // Bias storage â?? only ARRAY_COLS values needed at a time
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
                        out_channels_buf          <= out_channels; // latch runtime value
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
                                // Padding column â?? pass through
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

module conv_controller_v3 #(
    parameter MAX_KERNEL_SIZE  = 5,
    parameter MAX_WIN_SIZE     = 256,
    parameter MAX_IN_CHANNELS  = 256,
    parameter MAX_OUT_CHANNELS = 120,
    parameter MAX_INPUT_HEIGHT = 28,
    parameter MAX_INPUT_WIDTH  = 28,
    parameter TILE_ROWS        = 4,
    parameter ARRAY_COLS       = 4,
    parameter DATA_WIDTH       = 8
)(
    input  logic clk,
    input  logic rst,
    input  logic start_conv,
    input  logic fc_mode,
    output logic conv_done,

    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,
    input logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height,
    input logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width,

    output logic start_im2col,
    input  logic im2col_tile_ready,

    output logic start_weight,
    input  logic weight_tile_ready,

    output logic systolic_load,
    input  logic systolic_valid,
    input  logic signed [4*DATA_WIDTH-1:0] systolic_out [TILE_ROWS][ARRAY_COLS],

    output logic output_valid,
    output logic signed [4*DATA_WIDTH-1:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(MAX_OUT_CHANNELS)-1:0]                 output_channel_start,
    output logic [$clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH)-1:0] output_window_idx_start
);

    localparam MAX_OUT_H         = MAX_INPUT_HEIGHT - MAX_KERNEL_SIZE + 1;
    localparam MAX_OUT_W         = MAX_INPUT_WIDTH  - MAX_KERNEL_SIZE + 1;
    localparam MAX_TOTAL_WINDOWS = MAX_OUT_H * MAX_OUT_W;
    localparam MAX_IM2COL_TILES  = (MAX_TOTAL_WINDOWS + TILE_ROWS  - 1) / TILE_ROWS;
    localparam MAX_WEIGHT_TILES  = (MAX_OUT_CHANNELS  + ARRAY_COLS - 1) / ARRAY_COLS;

    // ---------- Runtime geometry (combinational) ----------
    logic [$clog2(MAX_OUT_H+1)-1:0]         output_h;
    logic [$clog2(MAX_OUT_W+1)-1:0]         output_w;
    logic [$clog2(MAX_TOTAL_WINDOWS+1)-1:0] total_windows;
    logic [$clog2(MAX_IM2COL_TILES+1)-1:0]  num_im2col_tiles;
    logic [$clog2(MAX_WEIGHT_TILES+1)-1:0]  num_weight_tiles;

    always_comb begin
        output_h         = input_height - kernel_size + 1;
        output_w         = input_width  - kernel_size + 1;
        total_windows    = output_h * output_w;
        num_im2col_tiles = (total_windows + TILE_ROWS  - 1) / TILE_ROWS;
        num_weight_tiles = (out_channels  + ARRAY_COLS - 1) / ARRAY_COLS;
    end

    // ---------- Latched at start_conv ----------
    // FIX: total_windows_r REMOVED - was latched but never read anywhere
    //      in the FSM. All tile-count logic uses num_im2col_tiles_r and
    //      num_weight_tiles_r, which already encode the window count.
    logic [$clog2(MAX_IM2COL_TILES+1)-1:0]  num_im2col_tiles_r;
    logic [$clog2(MAX_WEIGHT_TILES+1)-1:0]  num_weight_tiles_r;

    typedef enum logic [2:0] {
        IDLE, START_TILES, WAIT_BOTH, COMPUTE, NEXT_TILE, WAIT_IM2COL
    } state_t;

    state_t state;

    logic [$clog2(MAX_WEIGHT_TILES+1)-1:0]  weight_tile_idx;
    logic [$clog2(MAX_IM2COL_TILES+1)-1:0]  im2col_tile_idx;
    logic [$clog2(MAX_OUT_CHANNELS)-1:0]     current_output_channel;
    logic [$clog2(MAX_TOTAL_WINDOWS+1)-1:0]  current_window_idx_start;
    logic weight_has_data, im2col_has_data, fc_mode_latched;

    logic [$clog2(MAX_IM2COL_TILES+1)-1:0] effective_im2col_tiles;
    always_comb
        effective_im2col_tiles = fc_mode_latched ? 1 : num_im2col_tiles_r;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state                    <= IDLE;
            fc_mode_latched          <= 1'b0;
            start_im2col             <= 1'b0;
            start_weight             <= 1'b0;
            systolic_load            <= 1'b0;
            output_valid             <= 1'b0;
            conv_done                <= 1'b0;
            weight_tile_idx          <= '0;
            im2col_tile_idx          <= '0;
            current_output_channel   <= '0;
            current_window_idx_start <= '0;
            output_channel_start     <= '0;
            output_window_idx_start  <= '0;
            weight_has_data          <= 1'b0;
            im2col_has_data          <= 1'b0;
            // FIX: total_windows_r removed from reset list
            num_im2col_tiles_r       <= '0;
            num_weight_tiles_r       <= '0;
            for (int r = 0; r < TILE_ROWS; r++)
                for (int c = 0; c < ARRAY_COLS; c++)
                    output_data[r][c] <= '0;
        end else begin
            start_im2col  <= 1'b0;
            start_weight  <= 1'b0;
            systolic_load <= 1'b0;
            output_valid  <= 1'b0;
            conv_done     <= 1'b0;

            case (state)

                IDLE: begin
                    if (start_conv) begin
                        fc_mode_latched    <= fc_mode;
                        // FIX: total_windows_r assignment removed
                        num_im2col_tiles_r <= num_im2col_tiles;
                        num_weight_tiles_r <= num_weight_tiles;
                        weight_tile_idx    <= '0;
                        im2col_tile_idx    <= '0;
                        weight_has_data    <= 1'b0;
                        im2col_has_data    <= 1'b0;
                        state              <= START_TILES;
                    end
                end

                START_TILES: begin
                    start_weight <= 1'b1;
                    start_im2col <= 1'b1;
                    state        <= WAIT_BOTH;
                end

                WAIT_BOTH: begin
                    if (weight_tile_ready) begin
                        weight_has_data        <= 1'b1;
                        current_output_channel <= weight_tile_idx * ARRAY_COLS;
                    end
                    if (im2col_tile_ready) begin
                        im2col_has_data          <= 1'b1;
                        current_window_idx_start <= im2col_tile_idx * TILE_ROWS;
                    end
                    if ((weight_has_data || weight_tile_ready) &&
                        (im2col_has_data || im2col_tile_ready)) begin
                        systolic_load   <= 1'b1;
                        weight_has_data <= 1'b0;
                        im2col_has_data <= 1'b0;
                        state           <= COMPUTE;
                    end
                end

                COMPUTE: begin
                    if (systolic_valid) begin
                        output_valid            <= 1'b1;
                        output_channel_start    <= current_output_channel;
                        output_window_idx_start <= current_window_idx_start;
                        for (int r = 0; r < TILE_ROWS; r++)
                            for (int c = 0; c < ARRAY_COLS; c++)
                                output_data[r][c] <= systolic_out[r][c];
                        state <= NEXT_TILE;
                    end
                end

                NEXT_TILE: begin
                    if (im2col_tile_idx < effective_im2col_tiles - 1) begin
                        im2col_tile_idx <= im2col_tile_idx + 1;
                        start_im2col    <= 1'b1;
                        state           <= WAIT_IM2COL;
                    end else if (weight_tile_idx < num_weight_tiles_r - 1) begin
                        weight_tile_idx <= weight_tile_idx + 1;
                        im2col_tile_idx <= '0;
                        state           <= START_TILES;
                    end else begin
                        conv_done <= 1'b1;
                        state     <= IDLE;
                    end
                end

                WAIT_IM2COL: begin
                    if (im2col_tile_ready) begin
                        current_window_idx_start <= im2col_tile_idx * TILE_ROWS;
                        systolic_load            <= 1'b1;
                        state                    <= COMPUTE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

module conv_top_v2_hybrid #(
    parameter MAX_KERNEL_SIZE  = 5,
    parameter MAX_WINDOW_SIZE  = 256,
    parameter MAX_IN_CHANNELS  = 256,
    parameter MAX_OUT_CHANNELS = 120,
    parameter MAX_INPUT_HEIGHT = 28,
    parameter MAX_INPUT_WIDTH  = 28,
    parameter TILE_ROWS        = 8,
    parameter ARRAY_COLS       = 8,
    parameter DATA_WIDTH       = 8,
    parameter NUM_IMG_PORTS    = 5,
    parameter MAX_BURST_LEN    = 256,
    parameter TOTAL_ELEMENTS   = 1024
)(
    input  logic clk,
    input  logic rst,
    input  logic start_conv,
    output logic conv_done,
    input  logic fc_mode,

    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    input logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels,
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,
    input logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height,
    input logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width,

    output logic [9:0]                                             img_sram_addr    [NUM_IMG_PORTS],
    output logic                                                   img_sram_read_req[NUM_IMG_PORTS],
    input  logic signed [DATA_WIDTH-1:0]                           img_sram_data    [NUM_IMG_PORTS],
    input  logic                                                   img_sram_valid   [NUM_IMG_PORTS],

    output logic [$clog2(MAX_OUT_CHANNELS*MAX_WINDOW_SIZE)-1:0]    weight_sram_addr,
    output logic [$clog2(MAX_BURST_LEN+1)-1:0]                    weight_sram_burst_len,
    output logic                                                   weight_sram_read_req,
    input  logic signed [DATA_WIDTH-1:0]                           weight_sram_data,
    input  logic                                                   weight_sram_valid,
    input  logic                                                   weight_sram_burst_done,

    output logic                                                   output_valid,
    output logic signed [4*DATA_WIDTH-1:0]                        output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(MAX_OUT_CHANNELS)-1:0]                    output_channel_start,
    output logic [$clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH)-1:0]    output_window_idx_start
);

    localparam A_FLAT_W = TILE_ROWS      * MAX_WINDOW_SIZE * DATA_WIDTH;
    localparam B_FLAT_W = MAX_WINDOW_SIZE * ARRAY_COLS     * DATA_WIDTH;
    localparam C_FLAT_W = TILE_ROWS      * ARRAY_COLS      * 4 * DATA_WIDTH;

    // =========================================================================
    // Internal signals
    // =========================================================================
    logic start_im2col, im2col_tile_ready, im2col_done_all;
    logic signed [DATA_WIDTH-1:0] im2col_tile_data [TILE_ROWS][MAX_WINDOW_SIZE];

    logic start_weight, weight_tile_ready, weight_done_all;
    logic signed [DATA_WIDTH-1:0] weight_tile [MAX_WINDOW_SIZE][ARRAY_COLS];

    logic systolic_load, systolic_valid;

    // 2D unpacked internal wire ? used by controller
    logic signed [4*DATA_WIDTH-1:0] systolic_out [TILE_ROWS][ARRAY_COLS];

    // 1D packed flat wire from systolic ? avoids 2D unpacked port row-swap bug
    logic signed [C_FLAT_W-1:0] c_flat;

    // Unpack c_flat ? systolic_out (combinational, no port crossing)
    always_comb begin
        for (int r = 0; r < TILE_ROWS; r++)
            for (int n = 0; n < ARRAY_COLS; n++)
                systolic_out[r][n] = c_flat[(r*ARRAY_COLS+n)*4*DATA_WIDTH +: 4*DATA_WIDTH];
    end

    // =========================================================================
    // window_size ? runtime computed, passed to systolic k_size port
    // =========================================================================
    logic [$clog2(MAX_WINDOW_SIZE+1)-1:0] window_size;
    always_comb begin
        automatic int ws;
        ws          = int'(kernel_size) * int'(kernel_size) * int'(in_channels);
        window_size = ($clog2(MAX_WINDOW_SIZE+1))'(ws);
    end

    // =========================================================================
    // FLAT 1D packed feeds into systolic ? stable from systolic_load until
    // systolic_valid (see STABILITY INVARIANT in file header).
    // systolic_full reads these directly; no internal copy is made.
    // =========================================================================
    logic [A_FLAT_W-1:0] a_flat;
    logic [B_FLAT_W-1:0] b_flat;

    always_comb begin
        for (int r = 0; r < TILE_ROWS; r++)
            for (int k = 0; k < MAX_WINDOW_SIZE; k++)
                a_flat[(r*MAX_WINDOW_SIZE+k)*DATA_WIDTH +: DATA_WIDTH]
                    = im2col_tile_data[r][k];
        for (int k = 0; k < MAX_WINDOW_SIZE; k++)
            for (int n = 0; n < ARRAY_COLS; n++)
                b_flat[(k*ARRAY_COLS+n)*DATA_WIDTH +: DATA_WIDTH]
                    = weight_tile[k][n];
    end

    // =========================================================================
    // IM2COL ? unchanged
    // =========================================================================
    im2col1_streaming_multiport #(
        .MAX_IMG_W       (MAX_INPUT_WIDTH),
        .MAX_IMG_H       (MAX_INPUT_HEIGHT),
        .MAX_KERNEL_SIZE (MAX_KERNEL_SIZE),
        .MAX_WIN_SIZE    (MAX_WINDOW_SIZE),
        .STRIDE          (1),
        .TILE_ROWS       (TILE_ROWS),
        .MAX_IN_CHANNELS (MAX_IN_CHANNELS),
        .DATA_WIDTH      (DATA_WIDTH),
        .NUM_PORTS       (NUM_IMG_PORTS)
    ) im2col (
        .clk          (clk),
        .rst          (rst),
        .start        (start_im2col),
        .fc_mode      (fc_mode),
        .kernel_size  (kernel_size),
        .in_channels  (in_channels),
        .input_height (input_height),
        .input_width  (input_width),
        .tile_ready   (im2col_tile_ready),
        .done_all     (im2col_done_all),
        .sram_addr    (img_sram_addr),
        .sram_read_req(img_sram_read_req),
        .sram_data    (img_sram_data),
        .sram_valid   (img_sram_valid),
        .tile_data    (im2col_tile_data)
    );

    // =========================================================================
    // WEIGHT MANAGER ? unchanged
    // =========================================================================
    weight_flatten2_streaming_burst #(
        .MAX_KERNEL_SIZE  (MAX_KERNEL_SIZE),
        .MAX_IN_CHANNELS  (MAX_IN_CHANNELS),
        .MAX_OUT_CHANNELS (MAX_OUT_CHANNELS),
        .ARRAY_COLS       (ARRAY_COLS),
        .DATA_WIDTH       (DATA_WIDTH),
        .MAX_BURST_LEN    (MAX_BURST_LEN)
    ) weight_mgr (
        .clk             (clk),
        .rst             (rst),
        .start           (start_weight),
        .kernel_size     (kernel_size),
        .in_channels     (in_channels),
        .out_channels    (out_channels),
        .tile_ready      (weight_tile_ready),
        .done_all        (weight_done_all),
        .sram_addr       (weight_sram_addr),
        .sram_burst_len  (weight_sram_burst_len),
        .sram_read_req   (weight_sram_read_req),
        .sram_data       (weight_sram_data),
        .sram_valid      (weight_sram_valid),
        .sram_burst_done (weight_sram_burst_done),
        .weight_tile     (weight_tile)
    );

    // =========================================================================
    // CONTROLLER ? unchanged
    // =========================================================================
    conv_controller_v3 #(
        .MAX_KERNEL_SIZE  (MAX_KERNEL_SIZE),
        .MAX_IN_CHANNELS  (MAX_IN_CHANNELS),
        .MAX_OUT_CHANNELS (MAX_OUT_CHANNELS),
        .MAX_INPUT_HEIGHT (MAX_INPUT_HEIGHT),
        .MAX_INPUT_WIDTH  (MAX_INPUT_WIDTH),
        .TILE_ROWS        (TILE_ROWS),
        .ARRAY_COLS       (ARRAY_COLS),
        .DATA_WIDTH       (DATA_WIDTH)
    ) controller (
        .clk                    (clk),
        .rst                    (rst),
        .start_conv             (start_conv),

        .conv_done              (conv_done),
        .fc_mode                (fc_mode),
        .kernel_size            (kernel_size),
       
        .out_channels           (out_channels),
        .input_height           (input_height),
        .input_width            (input_width),
        .start_im2col           (start_im2col),
        .im2col_tile_ready      (im2col_tile_ready),
      
        .start_weight           (start_weight),
        .weight_tile_ready      (weight_tile_ready),
      
        .systolic_load          (systolic_load),
        .systolic_valid         (systolic_valid),
        .systolic_out           (systolic_out),
        .output_valid           (output_valid),
        .output_data            (output_data),
        .output_channel_start   (output_channel_start),
        .output_window_idx_start(output_window_idx_start)
    );

    // =========================================================================
    // SYSTOLIC ARRAY ? Option A applied (see systolic_full module).
    // a_flat / b_flat: held stable by controller during COMPUTE state.
    // c_flat: 1D packed output unpacked into systolic_out above.
    // =========================================================================
    systolic_full #(
        .DATAWIDTH (DATA_WIDTH),
        .M         (TILE_ROWS),
        .K         (MAX_WINDOW_SIZE),
        .N         (ARRAY_COLS)
    ) systolic (
        .clk       (clk),
        .rst       (rst),
        .load_data (systolic_load),
        .k_size    (window_size),
        .a_flat    (a_flat),
        .b_flat    (b_flat),
        .valid_out (systolic_valid),
        .c_flat    (c_flat)
    );

endmodule 
// im2col1_streaming_multiport - FIXED
// Warnings fixed:
//   [Synth 8-6014] Unused sequential element addr_row_reg was removed  -> line 157
//   [Synth 8-6014] Unused sequential element addr_elem_reg was removed -> line 158
// Root cause: addr_row and addr_elem were registered but never read back;
//   all address generation uses local 'temp_row'/'temp_elem' variables.
// Fix: Remove addr_row and addr_elem registers entirely.
//   The local automatic variables (temp_row, temp_elem) already do the job.
//   fc_mode path never used addr_row (it always wrote row 0).
//   conv path used temp_row/temp_elem exclusively.
// Tile-data write path: use the registered wr_en/wr_row/wr_col/wr_dat
//   scheme from doc-24 so the distributed-RAM write port is driven by FFs
//   (eliminates Vivado [Synth 8-5788] set/reset on distributed RAM).

module im2col1_streaming_multiport #(
    parameter MAX_IMG_W       = 28,
    parameter MAX_IMG_H       = 28,
    parameter MAX_KERNEL_SIZE = 5,
    parameter MAX_WIN_SIZE    = 256,
    parameter STRIDE          = 1,
    parameter TILE_ROWS       = 4,
    parameter MAX_IN_CHANNELS = 256,
    parameter DATA_WIDTH      = 8,
    parameter NUM_PORTS       = 3
)(
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic fc_mode,

    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0] kernel_size,
    input logic [$clog2(MAX_IN_CHANNELS+1)-1:0] in_channels,
    input logic [$clog2(MAX_IMG_H+1)-1:0]       input_height,
    input logic [$clog2(MAX_IMG_W+1)-1:0]       input_width,

    output logic tile_ready,
    output logic done_all,

    output logic [9:0] sram_addr    [NUM_PORTS],
    output logic       sram_read_req[NUM_PORTS],
    input  logic signed [DATA_WIDTH-1:0] sram_data [NUM_PORTS],
    input  logic        sram_valid   [NUM_PORTS],

    output logic signed [DATA_WIDTH-1:0] tile_data [TILE_ROWS][MAX_WIN_SIZE]
);
    localparam MAX_OUT_W        = (MAX_IMG_W - MAX_KERNEL_SIZE) / STRIDE + 1;
    localparam MAX_OUT_H        = (MAX_IMG_H - MAX_KERNEL_SIZE) / STRIDE + 1;
    localparam MAX_TOTAL_WIN    = MAX_OUT_W * MAX_OUT_H;
    localparam MAX_NUM_TILES    = (MAX_TOTAL_WIN + TILE_ROWS - 1) / TILE_ROWS;
    localparam MAX_PIX_PER_TILE = TILE_ROWS * MAX_WIN_SIZE;

    // -------------------------------------------------------------------------
    // Runtime geometry - combinational, sampled only at start pulse
    // -------------------------------------------------------------------------
    logic [$clog2(MAX_OUT_W+1)-1:0]     out_w;
    logic [$clog2(MAX_OUT_H+1)-1:0]     out_h;
    logic [$clog2(MAX_TOTAL_WIN+1)-1:0] total_windows;
    logic [$clog2(MAX_NUM_TILES+1)-1:0] num_tiles;

    always_comb begin
        if (fc_mode) begin
            out_w         = 1;
            out_h         = 1;
            total_windows = TILE_ROWS;
            num_tiles     = 1;
        end else begin
            out_w         = ($clog2(MAX_OUT_W+1))'(input_width  - kernel_size + 1);
            out_h         = ($clog2(MAX_OUT_H+1))'(input_height - kernel_size + 1);
            total_windows = out_h * out_w;
            num_tiles     = (total_windows + TILE_ROWS - 1) / TILE_ROWS;
        end
    end

    typedef enum logic [1:0] { IDLE, PROCESSING } state_t;
    state_t state;

    logic [$clog2(MAX_NUM_TILES+1)-1:0]   tile_counter;
    logic                                  fc_mode_latched;

    // Address-generation counters
    // FIX: addr_row and addr_elem REMOVED - they were never read back;
    //      all address loops use local automatic temp variables instead.
    logic [$clog2(MAX_PIX_PER_TILE+1)-1:0] addr_pixel_count;
    logic [$clog2(MAX_OUT_H+1)-1:0]         addr_wy;
    logic [$clog2(MAX_OUT_W+1)-1:0]         addr_wx;
    logic [$clog2(MAX_TOTAL_WIN+1)-1:0]     addr_window_idx;
    logic [$clog2(MAX_IN_CHANNELS+1)-1:0]   addr_c;
    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]   addr_ky, addr_kx;

    // Data-reception counters
    logic [$clog2(MAX_PIX_PER_TILE+1)-1:0] data_pixel_count;
    logic [$clog2(TILE_ROWS+1)-1:0]         data_row;
    logic [$clog2(MAX_WIN_SIZE+1)-1:0]      data_elem;

    // Latched geometry
    logic [$clog2(MAX_WIN_SIZE+1)-1:0]      window_size_lat;
    logic [$clog2(MAX_OUT_W+1)-1:0]         out_w_lat;
    logic [$clog2(MAX_TOTAL_WIN+1)-1:0]     total_windows_lat;
    logic [$clog2(MAX_NUM_TILES+1)-1:0]     num_tiles_lat;

    logic [$clog2(MAX_PIX_PER_TILE+1)-1:0]  expected_pixels_reg;

    logic addr_done, data_done;
    always_comb begin
        addr_done = (addr_pixel_count >= expected_pixels_reg);
        data_done = (data_pixel_count >= expected_pixels_reg);
    end

    // -------------------------------------------------------------------------
    // FIX: tile_data backed by distributed RAM with NO async reset.
    // Write port driven by registered wr_en/wr_row/wr_col/wr_dat signals
    // to avoid [Synth 8-5788] "has both Set and reset with same priority".
    // -------------------------------------------------------------------------
    (* ram_style = "distributed" *)
    logic signed [DATA_WIDTH-1:0] tile_data_r [TILE_ROWS][MAX_WIN_SIZE];

    assign tile_data = tile_data_r;

    // Registered write-port signals (driven by FSM, consumed by RAM process)
    logic                              wr_en  [NUM_PORTS];
    logic [$clog2(TILE_ROWS+1)-1:0]    wr_row [NUM_PORTS];
    logic [$clog2(MAX_WIN_SIZE+1)-1:0] wr_col [NUM_PORTS];
    logic signed [DATA_WIDTH-1:0]      wr_dat [NUM_PORTS];

    // Distributed-RAM write process - clock only, no reset
    always_ff @(posedge clk) begin
        for (int p = 0; p < NUM_PORTS; p++) begin
            if (wr_en[p])
                tile_data_r[wr_row[p]][wr_col[p]] <= wr_dat[p];
        end
    end

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state               <= IDLE;
            tile_counter        <= 0;
            fc_mode_latched     <= 0;
            tile_ready          <= 0;
            done_all            <= 0;
            addr_pixel_count    <= 0;
            addr_wy             <= 0;
            addr_wx             <= 0;
            addr_window_idx     <= 0;
            addr_c              <= 0;
            addr_ky             <= 0;
            addr_kx             <= 0;
            data_pixel_count    <= 0;
            data_row            <= 0;
            data_elem           <= 0;
            window_size_lat     <= 0;
            out_w_lat           <= 0;
            total_windows_lat   <= 0;
            num_tiles_lat       <= 0;
            expected_pixels_reg <= 0;
            for (int p = 0; p < NUM_PORTS; p++) begin
                sram_read_req[p] <= 0;
                sram_addr[p]     <= 0;
                wr_en[p]         <= 0;
                wr_row[p]        <= 0;
                wr_col[p]        <= 0;
                wr_dat[p]        <= '0;
            end
        end else begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                sram_read_req[p] <= 0;
                wr_en[p]         <= 0;
            end
            tile_ready <= 0;

            case (state)

                // --------------------------------------------------------------
                IDLE: begin
                    if (start && tile_counter < num_tiles) begin
                        fc_mode_latched <= fc_mode;

                        window_size_lat   <= ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                                             ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                                             ($clog2(MAX_WIN_SIZE+1))'(in_channels);
                        out_w_lat         <= out_w;
                        total_windows_lat <= total_windows;
                        num_tiles_lat     <= num_tiles;

                        if (fc_mode) begin
                            expected_pixels_reg <= ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                                                   ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                                                   ($clog2(MAX_WIN_SIZE+1))'(in_channels);
                        end else begin
                            automatic int wins_this_tile;
                            wins_this_tile = (tile_counter == num_tiles - 1)
                                ? int'(total_windows - tile_counter * TILE_ROWS)
                                : TILE_ROWS;
                            expected_pixels_reg <=
                                ($clog2(MAX_PIX_PER_TILE+1))'(wins_this_tile) *
                                (($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                                 ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                                 ($clog2(MAX_WIN_SIZE+1))'(in_channels));
                        end

                        addr_pixel_count <= 0;
                        addr_c           <= 0;
                        addr_ky          <= 0;
                        addr_kx          <= 0;

                        if (!fc_mode) begin
                            addr_window_idx <= tile_counter * TILE_ROWS;
                            addr_wy         <= (tile_counter * TILE_ROWS) / out_w;
                            addr_wx         <= (tile_counter * TILE_ROWS) % out_w;
                        end

                        data_pixel_count <= 0;
                        data_row         <= 0;
                        data_elem        <= 0;
                        done_all         <= 0;
                        state            <= PROCESSING;
                    end
                end

                // --------------------------------------------------------------
                PROCESSING: begin

                    // -- Address generation ------------------------------------
                    if (!addr_done) begin
                        if (fc_mode_latched) begin
                            automatic int can_issue;
                            can_issue = int'(window_size_lat) - int'(addr_pixel_count);
                            if (can_issue > NUM_PORTS) can_issue = NUM_PORTS;
                            for (int p = 0; p < NUM_PORTS; p++) begin
                                if (p < can_issue) begin
                                    sram_addr[p]     <= 10'(addr_pixel_count + p);
                                    sram_read_req[p] <= 1;
                                end
                            end
                            addr_pixel_count <= addr_pixel_count + can_issue;
                        end else begin
                            // FIX: use purely local automatic variables;
                            //      addr_row and addr_elem registers are gone.
                            automatic logic [$clog2(TILE_ROWS+1)-1:0]       temp_row;
                            automatic logic [$clog2(MAX_WIN_SIZE+1)-1:0]    temp_elem;
                            automatic logic [$clog2(MAX_OUT_H+1)-1:0]       temp_wy;
                            automatic logic [$clog2(MAX_OUT_W+1)-1:0]       temp_wx;
                            automatic logic [$clog2(MAX_TOTAL_WIN+1)-1:0]   temp_window_idx;
                            automatic logic [$clog2(MAX_IN_CHANNELS+1)-1:0] temp_c;
                            automatic logic [$clog2(MAX_KERNEL_SIZE+1)-1:0] temp_ky, temp_kx;
                            automatic int pixels_to_request;

                            // Seed from registered state
                            temp_wy           = addr_wy;
                            temp_wx           = addr_wx;
                            temp_window_idx   = addr_window_idx;
                            temp_c            = addr_c;
                            temp_ky           = addr_ky;
                            temp_kx           = addr_kx;
                            // temp_row/temp_elem start at 0 each call because
                            // they are re-derived from the window traversal;
                            // data_row/data_elem track the receive side.
                            // For address generation the row/elem within the
                            // current burst window are implicit in temp_*.
                            temp_row          = '0;   // unused except for inner tracking
                            temp_elem         = '0;
                            pixels_to_request = 0;

                            for (int p = 0; p < NUM_PORTS; p++) begin
                                if (addr_pixel_count + pixels_to_request < expected_pixels_reg) begin
                                    if (temp_window_idx < total_windows_lat) begin
                                        automatic int iy, ix, flat_idx;
                                        iy       = int'(temp_wy) * STRIDE + int'(temp_ky);
                                        ix       = int'(temp_wx) * STRIDE + int'(temp_kx);
                                        flat_idx = int'(temp_c) * int'(input_height) *
                                                   int'(input_width) +
                                                   iy * int'(input_width) + ix;
                                        sram_addr[p]     <= flat_idx;
                                        sram_read_req[p] <= 1;
                                    end
                                    pixels_to_request++;

                                    if (temp_kx == kernel_size - 1) begin
                                        temp_kx = 0;
                                        if (temp_ky == kernel_size - 1) begin
                                            temp_ky = 0;
                                            if (temp_c == in_channels - 1) begin
                                                temp_c    = 0;
                                                temp_elem = 0;
                                                if (temp_wx == out_w_lat - 1) begin
                                                    temp_wx = 0;
                                                    temp_wy = temp_wy + 1;
                                                end else begin
                                                    temp_wx = temp_wx + 1;
                                                end
                                                temp_window_idx = temp_window_idx + 1;
                                                temp_row        = temp_row + 1;
                                            end else begin
                                                temp_c    = temp_c + 1;
                                                temp_elem = temp_elem + 1;
                                            end
                                        end else begin
                                            temp_ky   = temp_ky + 1;
                                            temp_elem = temp_elem + 1;
                                        end
                                    end else begin
                                        temp_kx   = temp_kx + 1;
                                        temp_elem = temp_elem + 1;
                                    end
                                end
                            end

                            addr_pixel_count <= addr_pixel_count + pixels_to_request;
                            addr_wy          <= temp_wy;
                            addr_wx          <= temp_wx;
                            addr_window_idx  <= temp_window_idx;
                            addr_c           <= temp_c;
                            addr_ky          <= temp_ky;
                            addr_kx          <= temp_kx;
                        end
                    end

                    // -- Data reception ----------------------------------------
                    if (!data_done) begin
                        if (fc_mode_latched) begin
                            automatic logic [$clog2(MAX_WIN_SIZE+1)-1:0] temp_elem;
                            automatic int valid_count;
                            temp_elem   = data_elem;
                            valid_count = 0;
                            for (int p = 0; p < NUM_PORTS; p++) begin
                                if (sram_valid[p] && temp_elem < window_size_lat) begin
                                    wr_en[p]  <= 1;
                                    wr_row[p] <= '0;
                                    wr_col[p] <= temp_elem;
                                    wr_dat[p] <= sram_data[p];
                                    valid_count++;
                                    temp_elem++;
                                end
                            end
                            data_pixel_count <= data_pixel_count + valid_count;
                            data_elem        <= temp_elem;
                            if (temp_elem >= window_size_lat && data_row == 0)
                                data_row <= 1;
                        end else begin
                            automatic int valid_count;
                            automatic logic [$clog2(TILE_ROWS+1)-1:0]    temp_row;
                            automatic logic [$clog2(MAX_WIN_SIZE+1)-1:0] temp_elem;
                            valid_count = 0;
                            temp_row    = data_row;
                            temp_elem   = data_elem;
                            for (int p = 0; p < NUM_PORTS; p++) begin
                                if (sram_valid[p] &&
                                    data_pixel_count + valid_count < expected_pixels_reg) begin
                                    wr_en[p]  <= 1;
                                    wr_row[p] <= temp_row;
                                    wr_col[p] <= temp_elem;
                                    wr_dat[p] <= sram_data[p];
                                    valid_count++;
                                    if (temp_elem == window_size_lat - 1) begin
                                        temp_elem = 0;
                                        temp_row  = temp_row + 1;
                                    end else begin
                                        temp_elem = temp_elem + 1;
                                    end
                                end
                            end
                            data_pixel_count <= data_pixel_count + valid_count;
                            data_row         <= temp_row;
                            data_elem        <= temp_elem;
                        end
                    end

                    // -- Completion --------------------------------------------
                    if (addr_done && data_done) begin
                        tile_ready <= 1;
                        if (tile_counter == num_tiles_lat - 1) begin
                            done_all     <= 1;
                            tile_counter <= 0;
                        end else begin
                            done_all     <= 0;
                            tile_counter <= tile_counter + 1;
                        end
                        state <= IDLE;
                    end
                end

            endcase
        end
    end

endmodule
module requantization_block #(
    parameter sys_row = 4,
    parameter sys_col = 4
)(
    input  logic clk,
    input  logic rst,
    input  logic start,

    input  logic [31:0]          requant_scale,
    input  logic [5:0]           requant_shift,
    input  logic signed [7:0]    ZP_next,

    input  logic signed [31:0] sys_out     [0:sys_row-1][0:sys_col-1],
    output logic signed  [7:0] requant_out [0:sys_row-1][0:sys_col-1]
);

    // =========================================================================
    // Input buffer - latched on start
    // =========================================================================
    logic signed [31:0] buffer [0:sys_row-1][0:sys_col-1];
    logic [31:0]        scale_reg;
    logic [5:0]         shift_reg;
    logic signed [7:0]  zp_reg;

    genvar ro, co;
    generate
        for (ro = 0; ro < sys_row; ro++) begin : ro_buf
            for (co = 0; co < sys_col; co++) begin : co_buf
                always_ff @(posedge clk or posedge rst) begin
                    if (rst)        buffer[ro][co] <= 32'd0;
                    else if (start) buffer[ro][co] <= sys_out[ro][co];
                end
            end
        end
    endgenerate

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            scale_reg <= 32'd1;
            shift_reg <= 6'd0;
            zp_reg    <= 8'd0;
        end else if (start) begin
            scale_reg <= requant_scale;
            shift_reg <= requant_shift;
            zp_reg    <= ZP_next;
        end
    end

    // =========================================================================
    // Pipeline - one chain per element
    // =========================================================================
    genvar row, c;
    generate
        for (row = 0; row < sys_row; row++) begin : row_loop
            for (c = 0; c < sys_col; c++) begin : col_loop

                // -------------------------------------------------------------
                // (* keep = "true" *) applied ONLY to registers that Vivado's
                // bit-level liveness analysis incorrectly prunes:
                //
                //   mult_res_reg : 64-bit DSP output register.  Upper bits are
                //     "dead" from the 8-bit output's perspective but are needed
                //     for correct rounding arithmetic.  keep preserves all 64
                //     bits.  DSP48 inference is unaffected because Vivado
                //     recognises the multiply-accumulate pattern before
                //     applying keep constraints.
                //
                //   shift_reg2 : 6-bit pipeline register.  Pruned because
                //     shift_reg (its source) is already registered and Vivado
                //     substitutes it directly.  keep costs zero timing budget
                //     on a 6-bit path.
                //
                // All other registers are left free for retiming.
                // -------------------------------------------------------------
                (* dont_touch = "true" *)  logic signed [63:0] mult_res_reg;
                (* keep = "true" *) logic        [5:0]  shift_reg2;

                logic signed [63:0] round_bias_reg;
                // FIX: 32-bit truncation bug — when biased*scale >= 2^31,
                // 32'(...) takes only the lower 32 bits, wrapping the sign
                // and producing the wrong saturation polarity.
                // Widening to 64 bits keeps the full product through ZP add.
                logic signed [63:0] shift_res_reg;
                logic signed [63:0] final_res_reg;

                always_ff @(posedge clk or posedge rst) begin
                    if (rst) begin
                        mult_res_reg        <= '0;
                        round_bias_reg      <= '0;
                        shift_reg2          <= '0;
                        shift_res_reg       <= '0;
                        final_res_reg       <= '0;
                        requant_out[row][c] <= '0;
                    end else begin

                        // Stage 1: multiply
                        mult_res_reg <= $signed({{32{buffer[row][c][31]}},
                                                    buffer[row][c]})
                                      * $signed({1'b0, scale_reg});

                        // Stage 2: round bias + pipeline shift
                        shift_reg2 <= shift_reg;
                        if (shift_reg == 0)
                            round_bias_reg <= '0;
                        else
                            round_bias_reg <= (mult_res_reg >= 0)
                                ?  (64'sd1 <<< (shift_reg - 1))
                                : ((64'sd1 <<< (shift_reg - 1)) - 64'sd1);

                        // Stage 3: arithmetic right-shift (no truncation)
                        shift_res_reg <=
                            (mult_res_reg + round_bias_reg) >>> shift_reg2;

                        // Stage 4: add zero point (64-bit sign-extend)
                        final_res_reg <= shift_res_reg +
                                         $signed({{56{zp_reg[7]}}, zp_reg});

                        // Stage 5: saturate to int8
                        if      (final_res_reg > 64'sd127)
                            requant_out[row][c] <=  8'sd127;
                        else if (final_res_reg < -64'sd128)
                            requant_out[row][c] <= -8'sd128;
                        else
                            requant_out[row][c] <= final_res_reg[7:0];

                    end
                end

            end
        end
    endgenerate

endmodule
module systolic_full #(
    parameter int DATAWIDTH = 8,
    parameter int M  = 4,
    parameter int K  = 256,
    parameter int N  = 4
)(
    input  logic clk,
    input  logic rst,
    input  logic load_data,

    // Runtime inner dimension
    input  logic [$clog2(K+1)-1:0] k_size,

    // FLAT 1D packed input ports
    input  logic signed [M*K*DATAWIDTH-1:0] a_flat,
    input  logic signed [K*N*DATAWIDTH-1:0] b_flat,

    output logic valid_out,

    // FLAT 1D packed output port
    // c[r][n] at bits [(r*N+n)*4*DATAWIDTH +: 4*DATAWIDTH]
    output logic signed [M*N*4*DATAWIDTH-1:0] c_flat
);

    localparam int CNT_WIDTH = $clog2(K + M + N + 1);

    // =========================================================================
    // Unpack flat inputs into 2D arrays - combinational only, no registers.
    // =========================================================================
    logic signed [DATAWIDTH-1:0] a_in_2d [M-1:0][K-1:0];
    logic signed [DATAWIDTH-1:0] b_in_2d [K-1:0][N-1:0];

    always_comb begin
        for (int r = 0; r < M; r++)
            for (int k = 0; k < K; k++)
                a_in_2d[r][k] = a_flat[(r*K+k)*DATAWIDTH +: DATAWIDTH];
        for (int k = 0; k < K; k++)
            for (int n = 0; n < N; n++)
                b_in_2d[k][n] = b_flat[(k*N+n)*DATAWIDTH +: DATAWIDTH];
    end

    // =========================================================================
    // Control registers
    // =========================================================================
    logic [CNT_WIDTH-1:0]   total_cycles_reg;
    logic [$clog2(K+1)-1:0] k_size_reg;
    logic                   run_enable;
    logic [CNT_WIDTH-1:0]   cycle_cnt;
    logic                   output_ready;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            run_enable       <= 1'b0;
            cycle_cnt        <= '0;
            output_ready     <= 1'b0;
            k_size_reg       <= '0;
            total_cycles_reg <= '0;
        end else begin
            output_ready <= 1'b0;

            if (load_data) begin
                k_size_reg       <= k_size;
                total_cycles_reg <= CNT_WIDTH'(k_size) +
                                    CNT_WIDTH'(M) +
                                    CNT_WIDTH'(N) - 2;
                run_enable       <= 1'b1;
                cycle_cnt        <= '0;
            end

            if (run_enable && !load_data) begin
                if (cycle_cnt < total_cycles_reg)
                    cycle_cnt <= cycle_cnt + 1;
                else begin
                    run_enable   <= 1'b0;
                    output_ready <= 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Wavefront feed - reads a_flat / b_flat directly.
    // =========================================================================
    logic signed [DATAWIDTH-1:0] a_next_in [M-1:0];
    logic signed [DATAWIDTH-1:0] b_next_in [N-1:0];

    always_comb begin
        for (int i = 0; i < M; i++) begin
            automatic int col;
            col = int'(cycle_cnt) - i;
            if (run_enable && col >= 0 && col < int'(k_size_reg))
                a_next_in[i] = a_in_2d[i][col];
            else
                a_next_in[i] = '0;
        end
        for (int j = 0; j < N; j++) begin
            automatic int row;
            row = int'(cycle_cnt) - j;
            if (run_enable && row >= 0 && row < int'(k_size_reg))
                b_next_in[j] = b_in_2d[row][j];
            else
                b_next_in[j] = '0;
        end
    end

    // =========================================================================
    // PE grid
    // FIX: PE_A[r][c] only registered when c < N-1 (last column never forwarded)
    //      PE_B[r][c] only registered when r < M-1 (last row never forwarded)
    //      This removes the dead registers Vivado was warning about.
    //      PE_C_REG always updated for every PE.
    // =========================================================================
    logic signed [DATAWIDTH-1:0]   PE_A     [M-1:0][N-1:0];
    logic signed [DATAWIDTH-1:0]   PE_B     [M-1:0][N-1:0];
    logic signed [4*DATAWIDTH-1:0] PE_C_REG [M-1:0][N-1:0];

    generate
        for (genvar r = 0; r < M; r++) begin : row_loop
            for (genvar c = 0; c < N; c++) begin : col_loop
                logic signed [DATAWIDTH-1:0] a_in, b_in;

                if (c == 0) assign a_in = a_next_in[r];
                else        assign a_in = PE_A[r][c-1];

                if (r == 0) assign b_in = b_next_in[c];
                else        assign b_in = PE_B[r-1][c];

                always_ff @(posedge clk or posedge rst) begin
                    if (rst || load_data) begin
                        PE_C_REG[r][c] <= '0;
                        // FIX: only reset/write PE_A when it will be forwarded
                        if (c < N-1) PE_A[r][c] <= '0;
                        // FIX: only reset/write PE_B when it will be forwarded
                        if (r < M-1) PE_B[r][c] <= '0;
                    end else if (run_enable) begin
                        PE_C_REG[r][c] <= PE_C_REG[r][c] + (a_in * b_in);
                        if (c < N-1) PE_A[r][c] <= a_in;
                        if (r < M-1) PE_B[r][c] <= b_in;
                    end
                end
            end
        end
    endgenerate

    // =========================================================================
    // Output register
    // =========================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            valid_out <= 1'b0;
            c_flat    <= '0;
        end else begin
            if (output_ready) begin
                valid_out <= 1'b1;
                for (int i = 0; i < M; i++)
                    for (int j = 0; j < N; j++)
                        c_flat[(i*N+j)*4*DATAWIDTH +: 4*DATAWIDTH] <= PE_C_REG[i][j];
            end else
                valid_out <= 1'b0;
        end
    end

endmodule

module weight_flatten2_streaming_burst #(
    parameter MAX_KERNEL_SIZE  = 5,
    parameter MAX_WIN_SIZE     = 256,
    parameter MAX_IN_CHANNELS  = 256,
    parameter MAX_OUT_CHANNELS = 120,
    parameter ARRAY_COLS       = 4,
    parameter DATA_WIDTH       = 8,
    parameter MAX_BURST_LEN    = 256,
    parameter MAX_WEIGHTS      = 30720
)(
    input  logic clk,
    input  logic rst,
    input  logic start,

    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    input logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels,
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,

    output logic tile_ready,
    output logic done_all,

    output logic [$clog2(MAX_OUT_CHANNELS*MAX_WIN_SIZE)-1:0] sram_addr,
    output logic [$clog2(MAX_BURST_LEN+1)-1:0] sram_burst_len,
    output logic sram_read_req,
    input  logic signed [DATA_WIDTH-1:0] sram_data,
    input  logic sram_valid,
    input  logic sram_burst_done,

    output logic signed [DATA_WIDTH-1:0] weight_tile
        [MAX_WIN_SIZE][ARRAY_COLS]
);
    localparam MAX_NUM_TILES = (MAX_OUT_CHANNELS + ARRAY_COLS - 1) / ARRAY_COLS;

    logic [$clog2(MAX_WIN_SIZE+1)-1:0]  weights_per_filter;
    logic [$clog2(MAX_NUM_TILES+1)-1:0] num_tiles;

    always_comb begin
        weights_per_filter = ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                             ($clog2(MAX_WIN_SIZE+1))'(kernel_size) *
                             ($clog2(MAX_WIN_SIZE+1))'(in_channels);
        num_tiles          = (out_channels + ARRAY_COLS - 1) / ARRAY_COLS;
    end

    typedef enum logic [1:0] {
        IDLE            = 2'd0,
        REQUEST_BURST   = 2'd1,
        RECEIVING_BURST = 2'd2,
        TILE_DONE       = 2'd3
    } state_t;

    state_t state;

    logic [$clog2(MAX_NUM_TILES+1)-1:0]  tile_counter;
    logic [$clog2(ARRAY_COLS+1)-1:0]     current_col;
    logic [$clog2(MAX_WIN_SIZE+1)-1:0]   burst_count;

    logic [$clog2(MAX_WIN_SIZE+1)-1:0]     weights_per_filter_lat;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels_lat;
    logic [$clog2(MAX_NUM_TILES+1)-1:0]    num_tiles_lat;

    // FIX: oc_vec and base_addr_vec declared as module-level wires
    // driven combinationally - avoids 'automatic' inside always_ff
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0]              oc_vec;
    logic [$clog2(MAX_OUT_CHANNELS*MAX_WIN_SIZE)-1:0]   base_addr_vec;

    always_comb begin
        // FIX: explicit-width cast keeps all bits of out_channels_lat live
        // preventing bit[0] from being pruned (Warning #40 fix from Doc 4)
        oc_vec = ($clog2(MAX_OUT_CHANNELS+1))'(tile_counter) *
                 ($clog2(MAX_OUT_CHANNELS+1))'(ARRAY_COLS)   +
                 ($clog2(MAX_OUT_CHANNELS+1))'(current_col);

        base_addr_vec = oc_vec *
                        ($clog2(MAX_OUT_CHANNELS*MAX_WIN_SIZE))'(weights_per_filter_lat);
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state                  <= IDLE;
            tile_counter           <= 0;
            current_col            <= 0;
            burst_count            <= 0;
            tile_ready             <= 0;
            sram_addr              <= 0;
            sram_burst_len         <= 0;
            sram_read_req          <= 0;
            weights_per_filter_lat <= 0;
            out_channels_lat       <= 0;
            num_tiles_lat          <= 0;
            for (int r = 0; r < MAX_WIN_SIZE; r++)
                for (int c = 0; c < ARRAY_COLS; c++)
                    weight_tile[r][c] <= 0;
        end else begin
            tile_ready    <= 0;
            sram_read_req <= 0;

            case (state)
                IDLE: begin
                    if (start) begin
                        weights_per_filter_lat <= weights_per_filter;
                        out_channels_lat       <= out_channels;
                        num_tiles_lat          <= num_tiles;
                        current_col            <= 0;
                        state                  <= REQUEST_BURST;
                    end
                end

                REQUEST_BURST: begin
                    // FIX: oc_vec and base_addr_vec now computed combinationally
                    // above - just use them directly here, no 'automatic' needed
                    if (oc_vec < out_channels_lat) begin
                        sram_addr      <= base_addr_vec;
                        sram_burst_len <= weights_per_filter_lat;
                        sram_read_req  <= 1;
                        burst_count    <= 0;
                        state          <= RECEIVING_BURST;
                    end else begin
                        for (int r = 0; r < MAX_WIN_SIZE; r++)
                            weight_tile[r][current_col] <= 0;
                        if (current_col == ARRAY_COLS - 1)
                            state <= TILE_DONE;
                        else begin
                            current_col <= current_col + 1;
                            state       <= REQUEST_BURST;
                        end
                    end
                end

                RECEIVING_BURST: begin
                    if (sram_valid) begin
                        weight_tile[burst_count][current_col] <= sram_data;
                        burst_count <= burst_count + 1;
                    end
                    if (sram_burst_done ||
                        (sram_valid && burst_count == weights_per_filter_lat - 1)) begin
                        if (current_col == ARRAY_COLS - 1)
                            state <= TILE_DONE;
                        else begin
                            current_col <= current_col + 1;
                            state       <= REQUEST_BURST;
                        end
                    end
                end

                TILE_DONE: begin
                    tile_ready <= 1;
                    if (tile_counter == num_tiles_lat - 1)
                        tile_counter <= 0;
                    else
                        tile_counter <= tile_counter + 1;
                    state <= IDLE;
                end
            endcase
        end
    end

    assign done_all = tile_ready && (tile_counter == num_tiles_lat - 1);

endmodule 

// ============================================================
// cbr_tb_top
// Non-UVM module. Glues interface ↔ DUT.
// Registers vif in config_db. Launches UVM via run_test().
// ============================================================
`include "uvm_macros.svh"
import uvm_pkg::*;

localparam int P_TILE_ROWS     = 4;
localparam int P_ARRAY_COLS    = 4;
localparam int P_MAX_OUT_CH    = 120;
localparam int P_MAX_IN_CH     = 256;
localparam int P_MAX_KS        = 5;
localparam int P_MAX_H         = 28;
localparam int P_MAX_W         = 28;
localparam int P_NUM_IMG_PORTS = 3;
localparam int P_MAX_BURST_LEN = 256;
localparam int P_DATA_WIDTH    = 8;
localparam int P_MAX_WIN_SIZE  = 256;
 
module cbr_tb_top_new;
 
  import uvm_pkg::*;
  import conv_bias_requant_pkg::* ;

  // ── Clock generation ─────────────────────────────────────
  logic clk;
  initial clk = 0;
  always #5 clk = ~clk;  // 100 MHz

  // ── Interface instantiation ──────────────────────────────
  cbr_if #(
    .TILE_ROWS     (P_TILE_ROWS),
    .ARRAY_COLS    (P_ARRAY_COLS),
    .MAX_OUT_CH    (P_MAX_OUT_CH),
    .MAX_IN_CH     (P_MAX_IN_CH),
    .MAX_KS        (P_MAX_KS),
    .MAX_H         (P_MAX_H),
    .MAX_W         (P_MAX_W),
    .NUM_IMG_PORTS (P_NUM_IMG_PORTS),
    .MAX_BURST_LEN (P_MAX_BURST_LEN),
    .DATA_WIDTH    (P_DATA_WIDTH),
    .MAX_WIN_SIZE  (P_MAX_WIN_SIZE)
  ) dut_if (.clk(clk));

  // ── DUT instantiation ────────────────────────────────────
  conv_bias_requant_integrated #(
    .MAX_KERNEL_SIZE  (P_MAX_KS),
    .MAX_WIN_SIZE     (P_MAX_WIN_SIZE),
    .MAX_IN_CHANNELS  (P_MAX_IN_CH),
    .MAX_OUT_CHANNELS (P_MAX_OUT_CH),
    .MAX_INPUT_HEIGHT (P_MAX_H),
    .MAX_INPUT_WIDTH  (P_MAX_W),
    .TILE_ROWS        (P_TILE_ROWS),
    .ARRAY_COLS       (P_ARRAY_COLS),
    .DATA_WIDTH       (P_DATA_WIDTH),
    .NUM_IMG_PORTS    (P_NUM_IMG_PORTS),
    .MAX_BURST_LEN    (P_MAX_BURST_LEN),
    .TOTAL_ELEMENTS   (32768)
  ) dut (
    .clk                    (dut_if.clk),
    .rst                    (dut_if.rst),
    .kernel_size            (dut_if.kernel_size),
    .in_channels            (dut_if.in_channels),
    .out_channels           (dut_if.out_channels),
    .input_height           (dut_if.input_height),
    .input_width            (dut_if.input_width),
    .requant_scale          (dut_if.requant_scale),
    .requant_shift          (dut_if.requant_shift),
    .ZP_next                (dut_if.ZP_next),
    .start_pipeline         (dut_if.start_pipeline),
    .fc_mode                (dut_if.fc_mode),
    .enable_relu            (dut_if.enable_relu),
    .pipeline_done          (dut_if.pipeline_done),
    .img_sram_addr          (dut_if.img_sram_addr),
    .img_sram_read_req      (dut_if.img_sram_read_req),
    .img_sram_data          (dut_if.img_sram_data),
    .img_sram_valid         (dut_if.img_sram_valid),
    .weight_sram_addr       (dut_if.weight_sram_addr),
    .weight_sram_burst_len  (dut_if.weight_sram_burst_len),
    .weight_sram_read_req   (dut_if.weight_sram_read_req),
    .weight_sram_data       (dut_if.weight_sram_data),
    .weight_sram_valid      (dut_if.weight_sram_valid),
    .weight_sram_burst_done (dut_if.weight_sram_burst_done),
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

  // ── Force known state before first clock edge ────────────
  initial begin
    dut_if.rst             = 1'b1;
    dut_if.start_pipeline  = 1'b0;
    dut_if.kernel_size     = '0;
    dut_if.in_channels     = '0;
    dut_if.out_channels    = '0;
    dut_if.input_height    = '0;
    dut_if.input_width     = '0;
    dut_if.requant_scale   = '0;
    dut_if.requant_shift   = '0;
    dut_if.ZP_next         = '0;
    dut_if.fc_mode         = '0;
    dut_if.enable_relu     = '0;
    for (int p = 0; p < P_NUM_IMG_PORTS; p++) begin
      dut_if.img_sram_data[p]  = '0;
      dut_if.img_sram_valid[p] = '0;
    end
    dut_if.weight_sram_data       = '0;
    dut_if.weight_sram_valid      = '0;
    dut_if.weight_sram_burst_done = '0;
    dut_if.bias_sram_data         = '0;
    dut_if.bias_sram_valid        = '0;
    dut_if.bias_sram_burst_done   = '0;

    uvm_config_db #(virtual cbr_if)::set(null, "uvm_test_top.*", "vif", dut_if);

    // Test name from +UVM_TESTNAME on command line:
    //   +UVM_TESTNAME=cbr_smoke_test
    //   +UVM_TESTNAME=cbr_rand_test
    //   +UVM_TESTNAME=cbr_corner_test
    //   +UVM_TESTNAME=cbr_full_test
    run_test("cbr_full_test");
  end

  // ── Global timeout watchdog ──────────────────────────────
  initial begin
    #(10_000_000);  // 10 ms
    `uvm_fatal("TIMEOUT", "Simulation exceeded 10ms – hung?");
  end

endmodule