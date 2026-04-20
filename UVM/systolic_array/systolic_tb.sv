package systolic_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ============================================================
  // systolic_seq_item.sv
  // One transaction = one matrix multiply.
  // Fields: stimulus (rand) + response (captured by monitor).
  // ============================================================

  class systolic_seq_item #(
      parameter int DW = 8,
      parameter int M  = 4,
      parameter int K  = 256,
      parameter int N  = 4
  ) extends uvm_sequence_item;

    // Register with factory so it can be overridden in tests
    `uvm_object_param_utils(systolic_seq_item#(DW, M, K, N))

    // ── STIMULUS FIELDS (randomized by sequences) ─────────────

    // Matrix A: M rows × K cols, INT8 signed
    rand logic signed [DW-1:0] a_matrix[M-1:0][K-1:0];

    // Matrix B: K rows × N cols, INT8 signed
    rand logic signed [DW-1:0] b_matrix[K-1:0][N-1:0];

    // k_size: the actual inner dimension used this transaction.
    // This is what the old testbench forgot to drive!
    rand logic [$clog2(K+1)-1:0] k_size;

    // ── RESPONSE FIELDS (written by monitor, read by scoreboard) ──
    logic signed [4*DW-1:0] c_flat[M-1:0][N-1:0];  // DUT output

    // ── CONSTRAINTS ───────────────────────────────────────────

    // k_size must be in [1, K]. Never 0 (assertion in interface catches it too).
    constraint c_ksize_valid {k_size inside {[1 : K]};}

    // Weighted distribution: hit extremes more often.
    // 10% chance k_size=1, 10% k_size=K, 80% random middle.
    // This ensures corner cases get covered without directed tests.
    constraint c_ksize_dist {
      k_size dist {
        1           := 10,
        [2 : K - 1] := 80,
        K           := 10
      };
    }

    // Default: values across full INT8 range [-128, +127].
    // Sequences can override this with tighter constraints.
    constraint c_values_default {
      foreach (a_matrix[i, j]) a_matrix[i][j] inside {[-128 : 127]};
      foreach (b_matrix[i, j]) b_matrix[i][j] inside {[-128 : 127]};
    }

    // ── UTILITY METHODS ───────────────────────────────────────

    // Flatten a_matrix → a_flat for driving onto the interface.
    // Layout: a_flat[(r*K+k)*DW +: DW] = a_matrix[r][k]
    function logic signed [M*K*DW-1:0] get_a_flat();
      for (int r = 0; r < M; r++)
      for (int k = 0; k < K; k++) get_a_flat[(r*K+k)*DW+:DW] = a_matrix[r][k];
    endfunction

    // Flatten b_matrix → b_flat.
    // Layout: b_flat[(k*N+n)*DW +: DW] = b_matrix[k][n]
    function logic signed [K*N*DW-1:0] get_b_flat();
      for (int k = 0; k < K; k++)
      for (int n = 0; n < N; n++) get_b_flat[(k*N+n)*DW+:DW] = b_matrix[k][n];
    endfunction

    // Pretty-print for `uvm_info messages
    function string convert2string();
      return $sformatf(
          "k_size=%0d | A[0][0]=%0d B[0][0]=%0d | C[0][0]=%0d",
          k_size,
          a_matrix[0][0],
          b_matrix[0][0],
          c_flat[0][0]
      );
    endfunction

    // do_copy: required for sequence item cloning
    function void do_copy(uvm_object rhs);
      systolic_seq_item #(DW, M, K, N) rhs_;
      super.do_copy(rhs);
      $cast(rhs_, rhs);
      a_matrix = rhs_.a_matrix;
      b_matrix = rhs_.b_matrix;
      k_size   = rhs_.k_size;
      c_flat   = rhs_.c_flat;
    endfunction

  endclass


  // ============================================================
  // systolic_driver.sv
  // Pulls items from sequencer → drives DUT via clocking block.
  // Key: a_flat/b_flat must stay STABLE until valid_out fires.
  // ============================================================

  class systolic_driver #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_driver #(systolic_seq_item #(DW, M, K, N));

    `uvm_component_param_utils(systolic_driver#(DW, M, K, N))

    // Virtual interface handle — obtained from config_db in build_phase
    virtual systolic_if #(DW, M, K, N).drv_mp vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // ── build_phase: get virtual interface ─────────────────────
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual systolic_if #(DW, M, K, N))::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "systolic_driver: vif not found in config_db");
    endfunction

    // ── run_phase: main driver loop ────────────────────────────
    task run_phase(uvm_phase phase);
      // Apply reset at the start of every simulation run
      apply_reset();

      // Forever loop: get item → drive it → repeat
      forever begin
        systolic_seq_item #(DW, M, K, N) item;

        // seq_item_port.get_next_item() BLOCKS until sequence
        // sends an item. This is the standard UVM driver pattern.
        seq_item_port.get_next_item(item);
        drive_item(item);
        seq_item_port.item_done();  // signal sequencer we're ready for next
      end
    endtask

    // ── apply_reset ────────────────────────────────────────────
    // Hold reset for 5 cycles, then release. Best practice:
    // always reset on a known clock edge via clocking block.
    // task apply_reset();
    //   vif.cb_drv.rst       <= 1'b1;
    //   vif.cb_drv.load_data <= 1'b0;
    //   vif.cb_drv.k_size    <= '0;
    //   vif.cb_drv.a_flat    <= '0;
    //   vif.cb_drv.b_flat    <= '0;
    //   repeat (5) @(vif.cb_drv);  // wait 5 clock edges
    //   vif.cb_drv.rst <= 1'b0;
    //   repeat (3) @(vif.cb_drv);  // 3 clean cycles — gives bus time to settle
    // endtask

    task apply_reset();
  vif.cb_drv.rst       <= 1'b1;
  vif.cb_drv.load_data <= 1'b0;
  vif.cb_drv.k_size    <= '0;      // ← drives 0, not X
  vif.cb_drv.a_flat    <= '0;
  vif.cb_drv.b_flat    <= '0;
  repeat (5) @(vif.cb_drv);
  vif.cb_drv.rst <= 1'b0;
  repeat (3) @(vif.cb_drv);
endtask

    // ── drive_item ─────────────────────────────────────────────
    // This implements the DUT timing contract:
    //   Cycle 0: drive matrices + k_size, assert load_data
    //   Cycle 1: deassert load_data, HOLD a_flat/b_flat stable
    //   ...wait... until valid_out fires
    //   Then we're done — ready for next item.
    // task drive_item(systolic_seq_item #(DW,M,K,N) item);
    //     // Step 1: Drive matrices and assert load_data
    //     vif.cb_drv.a_flat    <= item.get_a_flat();
    //     vif.cb_drv.b_flat    <= item.get_b_flat();
    //     vif.cb_drv.k_size    <= item.k_size;
    //     vif.cb_drv.load_data <= 1'b1;
    //     @(vif.cb_drv); // clock edge: DUT latches load_data

    //     // Step 2: Deassert load_data — data must STAY on the bus!
    //     vif.cb_drv.load_data <= 1'b0;

    //     // Step 3: Hold data stable until DUT asserts valid_out.
    //     // This is the stability contract the DUT requires.
    //     // We poll valid_out each clock edge.
    //     do begin
    //         @(vif.cb_drv);
    //     end while (!vif.cb_drv.valid_out);

    //     // Step 4: Transaction done. One idle cycle before next.
    //     @(vif.cb_drv);
    //     vif.cb_drv.a_flat <= '0;
    //     vif.cb_drv.b_flat <= '0;

    //     `uvm_info("DRV", $sformatf("Drove: %s", item.convert2string()), UVM_HIGH)
    // endtask

    //     task drive_item(systolic_seq_item #(DW,M,K,N) item);
    //     // Step 0: Drive data FIRST, load_data still low
    //     // This gives k_size/a_flat/b_flat one full cycle to settle
    //     // before the monitor sees load_data=1
    //     vif.cb_drv.a_flat    <= item.get_a_flat();
    //     vif.cb_drv.b_flat    <= item.get_b_flat();
    //     vif.cb_drv.k_size    <= item.k_size;
    //     vif.cb_drv.load_data <= 1'b0;        // ← keep LOW this cycle
    //     @(vif.cb_drv);                       // ← data settles on the bus

    //     // Step 1: NOW assert load_data — monitor will sample valid k_size
    //     vif.cb_drv.load_data <= 1'b1;
    //     @(vif.cb_drv);                       // DUT latches load_data

    //     // Step 2: Deassert — data stays stable
    //     vif.cb_drv.load_data <= 1'b0;

    //     // Step 3: Wait for valid_out
    //     do begin
    //         @(vif.cb_drv);
    //     end while (!vif.cb_drv.valid_out);

    //     // Step 4: Idle before next
    //     @(vif.cb_drv);
    //     vif.cb_drv.a_flat <= '0;
    //     vif.cb_drv.b_flat <= '0;

    //     `uvm_info("DRV", $sformatf("Drove: %s", item.convert2string()), UVM_HIGH)
    // endtask

task drive_item(systolic_seq_item#(DW, M, K, N) item);
  // Cycle 0: Drive data, keep load_data LOW — let signals settle
  vif.cb_drv.a_flat    <= item.get_a_flat();
  vif.cb_drv.b_flat    <= item.get_b_flat();
  vif.cb_drv.k_size    <= item.k_size;
  vif.cb_drv.load_data <= 1'b0;
  @(vif.cb_drv);                    // data is now stable on the bus

  // Cycle 1: Assert load_data — monitor now sees valid k_size
  vif.cb_drv.load_data <= 1'b1;
  @(vif.cb_drv);                    // DUT latches, monitor captures

  // Cycle 2: Deassert, wait for valid_out
  vif.cb_drv.load_data <= 1'b0;
  do
    begin
      @(vif.cb_drv);
    end
    while (!vif.cb_drv.valid_out)
      ;

  // Idle before next transaction
  @(vif.cb_drv);
  vif.cb_drv.a_flat <= '0;
  vif.cb_drv.b_flat <= '0;

  `uvm_info("DRV", $sformatf("Drove: %s", item.convert2string()), UVM_HIGH)
         endtask

  endclass


  // ============================================================
  // systolic_monitor.sv
  // Passive observer. Captures A, B, k_size on load_data.
  // Captures c_flat on valid_out. Broadcasts to analysis port.
  // ============================================================

  class systolic_monitor #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_monitor;

    `uvm_component_param_utils(systolic_monitor#(DW, M, K, N))

    // Virtual interface handle (monitor modport — read-only)
    virtual systolic_if #(DW, M, K, N).mon_mp vif;

    // Analysis port: broadcasts completed transactions to
    // scoreboard AND coverage collector simultaneously (fan-out).
    uvm_analysis_port #(systolic_seq_item #(DW, M, K, N)) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      // Create the analysis port in build_phase (not new())
      ap = new("ap", this);
      if (!uvm_config_db#(virtual systolic_if #(DW, M, K, N))::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "systolic_monitor: vif not found");
    endfunction

    // ── run_phase: main monitor loop ───────────────────────────
    task run_phase(uvm_phase phase);
  systolic_seq_item #(DW, M, K, N) item;

  forever begin
    @(vif.cb_mon);
    
    // ── Ignore any activity while reset is asserted ──────────
    if (vif.cb_mon.rst)  continue;
    if (!vif.cb_mon.load_data) continue;

    // Only proceed if data is not X/Z
    if ($isunknown(vif.cb_mon.k_size)) begin
      `uvm_warning("MON", "load_data seen but k_size is X — skipping (reset artifact)")
      continue;
    end

    item = systolic_seq_item#(DW, M, K, N)::type_id::create("item");
    item.k_size = vif.cb_mon.k_size;

        // Unpack flat buses back into 2D arrays for easy scoreboard use
        for (int r = 0; r < M; r++)
        for (int k = 0; k < K; k++) item.a_matrix[r][k] = vif.cb_mon.a_flat[(r*K+k)*DW+:DW];
        for (int k = 0; k < K; k++)
        for (int n = 0; n < N; n++) item.b_matrix[k][n] = vif.cb_mon.b_flat[(k*N+n)*DW+:DW];

        // ── Now wait for valid_out ──────────────────────────
        // The DUT takes (k_size + M + N - 2) cycles.
        // We just wait — don't assume how many cycles.
        do begin
          @(vif.cb_mon);
        end while (!vif.cb_mon.valid_out);

        // ── Capture response ────────────────────────────────
        // valid_out is high: c_flat is valid this cycle.
        // Unpack flat output into 2D array.
        for (int r = 0; r < M; r++)
        for (int n = 0; n < N; n++) item.c_flat[r][n] = vif.cb_mon.c_flat[(r*N+n)*4*DW+:4*DW];

        // ── Broadcast to all subscribers via analysis port ──
        // ap.write() calls every connected component's write() method.
        // Scoreboard gets it. Coverage gets it. Zero coupling.
        ap.write(item);

        `uvm_info("MON", $sformatf("Captured: %s", item.convert2string()), UVM_MEDIUM)
      end

    endtask

  endclass


  // ============================================================
  // systolic_agent.sv
  // Bundles: sequencer + driver + monitor.
  // is_active = UVM_ACTIVE  → creates driver + sequencer (block-level)
  // is_active = UVM_PASSIVE → monitor only (chip-level reuse)
  // ============================================================

  class systolic_agent #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_agent;

    `uvm_component_param_utils(systolic_agent#(DW, M, K, N))

    // Child components (declared, created conditionally)
    uvm_sequencer #(systolic_seq_item #(DW, M, K, N))     sequencer;
    systolic_driver #(DW, M, K, N)                        driver;
    systolic_monitor #(DW, M, K, N)                       monitor;

    // Expose monitor's analysis port so env can connect scoreboard/coverage
    uvm_analysis_port #(systolic_seq_item #(DW, M, K, N)) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      // Monitor always exists — active OR passive
      monitor = systolic_monitor#(DW, M, K, N)::type_id::create("monitor", this);

      // Driver + sequencer only in ACTIVE mode
      if (get_is_active() == UVM_ACTIVE) begin
        sequencer =
            uvm_sequencer#(systolic_seq_item#(DW, M, K, N))::type_id::create("sequencer", this);
        driver = systolic_driver#(DW, M, K, N)::type_id::create("driver", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      // Expose monitor's ap through agent's ap (simple passthrough)
      ap = monitor.ap;

      // Connect driver's seq_item_port to sequencer's export (TLM)
      if (get_is_active() == UVM_ACTIVE) driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

  endclass


  // ============================================================
  // systolic_scoreboard.sv
  // Receives transactions from monitor's analysis port.
  // Computes golden C=A×B, compares element-by-element.
  // ============================================================

  class systolic_scoreboard #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_scoreboard;

    `uvm_component_param_utils(systolic_scoreboard#(DW, M, K, N))

    // Analysis export: the "input port" that connects to monitor's ap.
    // uvm_analysis_imp automatically calls our write() method.
    uvm_analysis_imp #(
        systolic_seq_item #(DW,M,K,N),
        systolic_scoreboard #(DW,M,K,N)
    ) analysis_export;

    // Statistics counters
    int unsigned total_transactions = 0;
    int unsigned total_errors = 0;
    int unsigned total_elements = 0;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      analysis_export = new("analysis_export", this);
    endfunction

    // ── write(): called by monitor's ap.write() ────────────────
    // This is called ONCE per transaction. No need to synchronize
    // with the clock — we're in the transaction domain now.
    function void write(systolic_seq_item#(DW, M, K, N) item);
      logic signed [4*DW-1:0] expected[M-1:0][N-1:0];
      int errors_this_txn = 0;

      // ── Compute golden reference: C = A × B ─────────────────
      // CRITICAL: Only sum up to k_size columns/rows.
      // k_size may be < K — the rest of the matrix is don't-care.
      // This is what the old testbench ALWAYS got wrong (k_size=0).
      for (int r = 0; r < M; r++) begin
        for (int n = 0; n < N; n++) begin
          automatic logic signed [4*DW-1:0] acc = '0;
          for (int k = 0; k < item.k_size; k++) begin
            // INT8 × INT8 → sign-extended to 4×DW before accumulate
            acc += ((4 * DW)'(item.a_matrix[r][k]) * (4 * DW)'(item.b_matrix[k][n]));
          end
          expected[r][n] = acc;
        end
      end

      // ── Compare DUT output with golden ─────────────────────
      for (int r = 0; r < M; r++) begin
        for (int n = 0; n < N; n++) begin
          total_elements++;
          if (item.c_flat[r][n] !== expected[r][n]) begin
            // !== checks for X/Z too, not just value mismatch
            `uvm_error("SB_MISMATCH", $sformatf(
                       "C[%0d][%0d]: GOT=%0d EXPECTED=%0d (k_size=%0d)",
                       r,
                       n,
                       $signed(
                           item.c_flat[r][n]
                       ),
                       $signed(
                           expected[r][n]
                       ),
                       item.k_size
                       ));
            errors_this_txn++;
            total_errors++;
          end
        end
      end

      total_transactions++;

      if (errors_this_txn == 0)
        `uvm_info("SB_PASS", $sformatf(
                  "TXN %0d PASSED (k_size=%0d)", total_transactions, item.k_size), UVM_MEDIUM)
    endfunction

    // ── report_phase: final summary ────────────────────────────
    function void report_phase(uvm_phase phase);
      if (total_errors == 0)
        `uvm_info(
            "SB_FINAL", $sformatf(
            "ALL %0d TRANSACTIONS PASSED (%0d elements checked)", total_transactions, total_elements
            ), UVM_NONE)
      else
        `uvm_error("SB_FINAL", $sformatf(
                   "%0d ERRORS in %0d transactions", total_errors, total_transactions));
    endfunction

  endclass

  // ============================================================
  // systolic_coverage.sv
  // Functional coverage collector. Samples covergroups every
  // time monitor broadcasts a completed transaction.
  // ============================================================

  class systolic_coverage #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_subscriber #(systolic_seq_item #(DW, M, K, N));

    `uvm_component_param_utils(systolic_coverage#(DW, M, K, N))

    // Local copy of current transaction for covergroup sampling
    systolic_seq_item #(DW, M, K, N) curr_item;

    // ── Covergroup 1: k_size distribution ─────────────────────
    // Are we hitting the minimum, maximum, and mid-range values?
    covergroup cg_ksize;
      cp_ksize: coverpoint curr_item.k_size {
        bins min_k = {1};
        bins small_k = {[2 : 16]};
        bins mid_k = {[17 : (K / 2)]};
        bins large_k = {[(K / 2 + 1) : K - 1]};
        bins max_k = {K};
      }
    endgroup

    // ── Covergroup 2: Matrix A value distribution ──────────────
    // Do we hit zeros, max positive, max negative, mixed signs?
    // We sample A[0][0] as a representative element.
    covergroup cg_a_values;
      cp_a00: coverpoint curr_item.a_matrix[0][0] {
        bins max_pos = {127};
        bins pos = {[1 : 126]};
        bins zero = {0};
        bins neg = {[-127 : -1]};
        bins min_neg = {-128};
      }
    endgroup

    // ── Covergroup 3: Sign combination cross ──────────────────
    // Did A and B have all 4 sign combinations? (++, +-, -+, --)
    // Cross coverage ensures we test signed multiply thoroughly.
    covergroup cg_sign_cross;
      cp_a_sign: coverpoint (curr_item.a_matrix[0][0] >= 0) {
        bins positive = {1}; bins negative = {0};
      }
      cp_b_sign: coverpoint (curr_item.b_matrix[0][0] >= 0) {
        bins positive = {1}; bins negative = {0};
      }
      // Cross: all 4 combinations of A-sign × B-sign must be hit
      cx_ab_sign: cross cp_a_sign, cp_b_sign;
    endgroup

    // ── Covergroup 4: k_size × value corner cross ─────────────
    // Were extreme values exercised at extreme k_sizes?
    // Max accumulation (k_size=K, values=±128) is the worst case.
    covergroup cg_stress_cross;
      cp_k: coverpoint curr_item.k_size {bins k_min = {1}; bins k_max = {K}; bins k_mid = default;}
      cp_aval: coverpoint (curr_item.a_matrix[0][0] == 127 || curr_item.a_matrix[0][0] == -128) {
        bins extreme = {1}; bins normal = {0};
      }
      cx_stress: cross cp_k, cp_aval;
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      // Instantiate covergroups in new() — they exist for entire sim
      cg_ksize        = new();
      cg_a_values     = new();
      cg_sign_cross   = new();
      cg_stress_cross = new();
    endfunction

    // ── write(): called by monitor's ap.write() ────────────────
    // uvm_subscriber automatically creates analysis_export and
    // calls write() — no wiring needed in env.
    function void write(systolic_seq_item#(DW, M, K, N) t);
      curr_item = t;
      // Sample ALL covergroups with this transaction's data
      cg_ksize.sample();
      cg_a_values.sample();
      cg_sign_cross.sample();
      cg_stress_cross.sample();
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("COV", $sformatf(
                "Coverage: k_size=%.1f%% | values=%.1f%% | signs=%.1f%% | stress=%.1f%%",
                cg_ksize.get_coverage(),
                cg_a_values.get_coverage(),
                cg_sign_cross.get_coverage(),
                cg_stress_cross.get_coverage()
                ), UVM_NONE)
    endfunction

  endclass

  // ============================================================
  // systolic_env.sv
  // Top-level UVM environment. Creates agent, scoreboard,
  // coverage. Wires analysis port fan-out in connect_phase.
  // ============================================================

  class systolic_env #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_env;

    `uvm_component_param_utils(systolic_env#(DW, M, K, N))

    systolic_agent #(DW, M, K, N)      agent;
    systolic_scoreboard #(DW, M, K, N) scoreboard;
    systolic_coverage #(DW, M, K, N)   coverage;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // ── build_phase: create all children ──────────────────────
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent      = systolic_agent#(DW, M, K, N)::type_id::create("agent", this);
      scoreboard = systolic_scoreboard#(DW, M, K, N)::type_id::create("scoreboard", this);
      coverage   = systolic_coverage#(DW, M, K, N)::type_id::create("coverage", this);
    endfunction

    // ── connect_phase: wire TLM ports ─────────────────────────
    // The monitor's analysis port fans out to BOTH scoreboard
    // and coverage. This is standard UVM fan-out wiring.
    function void connect_phase(uvm_phase phase);
      // agent.ap is the monitor's analysis port (passed through agent)
      agent.ap.connect(scoreboard.analysis_export);
      agent.ap.connect(coverage.analysis_export);
      // That's it! UVM handles the fan-out automatically.
    endfunction

  endclass


  // Baseline random sequence — exercises a wide distribution
  // of k_size values and INT8 data values.
  // The item's own constraints handle the distribution (10/80/10).

  class systolic_rand_seq #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_sequence #(systolic_seq_item #(DW, M, K, N));

    `uvm_object_param_utils(systolic_rand_seq#(DW, M, K, N))

    int num_transactions = 100;  // set from test

    task body();
      systolic_seq_item #(DW, M, K, N) item;
      repeat (num_transactions) begin
        item = systolic_seq_item#(DW, M, K, N)::type_id::create("item");
        start_item(item);
        if (!item.randomize()) `uvm_fatal("RAND", "Randomization failed!");
        finish_item(item);  // blocks until driver calls item_done()
      end
    endtask

  endclass

  // Directed corner-case sequence.
  // Uses inline constraints to force specific scenarios.
  // Run this BEFORE the random sequence to ensure corners are hit.

  class systolic_corner_seq #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_sequence #(systolic_seq_item #(DW, M, K, N));

    `uvm_object_param_utils(systolic_corner_seq#(DW, M, K, N))

    task body();
      systolic_seq_item #(DW, M, K, N) item;

      // ── Corner 1: k_size = 1 (minimum) ────────────────────
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c1");
      start_item(item);
      if (!item.randomize() with {k_size == 1;}) `uvm_fatal("RAND", "Corner 1 failed");
      finish_item(item);

      // ── Corner 2: k_size = K (maximum, max accumulation) ──
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c2");
      start_item(item);
      if (!item.randomize() with {k_size == K;}) `uvm_fatal("RAND", "Corner 2 failed");
      finish_item(item);

      // ── Corner 3: All-zero A matrix ────────────────────────
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c3");
      start_item(item);
      if (!item.randomize() with {foreach (a_matrix[i, j]) a_matrix[i][j] == 0;})
        `uvm_fatal("RAND", "Corner 3 failed");
      finish_item(item);

      // ── Corner 4: Max positive × Max positive (overflow test) ─
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c4");
      start_item(item);
      if (!item.randomize() with {
            k_size == K;
            foreach (a_matrix[i, j]) a_matrix[i][j] == 127;
            foreach (b_matrix[i, j]) b_matrix[i][j] == 127;
          })
        `uvm_fatal("RAND", "Corner 4 failed");
      finish_item(item);

      // ── Corner 5: Min negative × Min negative ─────────────
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c5");
      start_item(item);
      if (!item.randomize() with {
            k_size == K;
            foreach (a_matrix[i, j]) a_matrix[i][j] == -128;
            foreach (b_matrix[i, j]) b_matrix[i][j] == -128;
          })
        `uvm_fatal("RAND", "Corner 5 failed");
      finish_item(item);

      // ── Corner 6: Identity-like: A=I, B=random → C=B ──────
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c6");
      start_item(item);
      if (!item.randomize() with {
            k_size == 1;
            foreach (a_matrix[i, j]) a_matrix[i][j] == (int'(i) == int'(j) ? 1 : 0);
          })
        `uvm_fatal("RAND", "Corner 6 failed");
      finish_item(item);

      // ── Corner 7: k_size=1 with extreme values → closes stress cross ──
      item = systolic_seq_item#(DW, M, K, N)::type_id::create("c7");
      start_item(item);
      if (!item.randomize() with {
            k_size == 1;
            foreach (a_matrix[i, j]) a_matrix[i][j] == 127;
            foreach (b_matrix[i, j]) b_matrix[i][j] == 127;
          })
        `uvm_fatal("RAND", "Corner 7 failed");
      finish_item(item);
    endtask

  endclass

  // Stress sequence: sends transactions back-to-back with
  // no idle cycles. Tests DUT's ability to restart immediately
  // after valid_out fires. This is the hardest protocol timing.

  class systolic_stress_seq #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_sequence #(systolic_seq_item #(DW, M, K, N));

    `uvm_object_param_utils(systolic_stress_seq#(DW, M, K, N))

    int num_transactions = 50;

    task body();
      systolic_seq_item #(DW, M, K, N) item;
      // Alternate between k_size=1 (fastest) and k_size=K (slowest)
      // to stress the state machine transitions
      repeat (num_transactions) begin
        automatic int use_k = ($urandom_range(0, 1) ? 1 : K);
        item = systolic_seq_item#(DW, M, K, N)::type_id::create("item");
        start_item(item);
        if (!item.randomize() with {k_size == use_k;}) `uvm_fatal("RAND", "Stress rand failed");
        finish_item(item);
        // finish_item blocks until driver calls item_done()
        // Driver calls item_done() right after valid_out.
        // So next start_item fires immediately → true back-to-back.
      end
    endtask

  endclass

  // ============================================================
  // systolic_base_test.sv
  // Base class all tests inherit from. Creates env, gets vif.
  // ============================================================
  class systolic_base_test #(
      parameter int DW = 8,
      int M = 4,
      int K = 256,
      int N = 4
  ) extends uvm_test;

    `uvm_component_param_utils(systolic_base_test#(DW, M, K, N))

    systolic_env #(DW, M, K, N) env;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = systolic_env#(DW, M, K, N)::type_id::create("env", this);
    endfunction

    // Convenience: extract seq handle for the agent's sequencer
    function uvm_sequencer#(systolic_seq_item#(DW, M, K, N)) get_sequencer();
      return env.agent.sequencer;
    endfunction

  endclass

  // ============================================================
  // systolic_rand_test.sv
  // Runs corner cases first, then 200 random transactions.
  // ============================================================
  class systolic_rand_test extends systolic_base_test #(8, 4, 256, 4);

    `uvm_component_utils(systolic_rand_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      systolic_corner_seq #(8, 4, 256, 4) corner_seq;
      systolic_rand_seq #(8, 4, 256, 4)   rand_seq;

      phase.raise_objection(this);  // Tell UVM "sim is not done yet"

      // Phase 1: Directed corners (deterministic, always runs)
      corner_seq = systolic_corner_seq#(8, 4, 256, 4)::type_id::create("corners");
      corner_seq.start(get_sequencer());

      // Phase 2: Constrained random (seeds controlled by +ntb_random_seed)
      rand_seq = systolic_rand_seq#(8, 4, 256, 4)::type_id::create("rand");
      rand_seq.num_transactions = 200;
      rand_seq.start(get_sequencer());

      phase.drop_objection(this);  // Tell UVM "sim can end now"
    endtask

  endclass

  // ============================================================
  // systolic_stress_test.sv
  // Pure back-to-back stress, no idle time between transactions.
  // ============================================================
  class systolic_stress_test extends systolic_base_test #(8, 4, 256, 4);

    `uvm_component_utils(systolic_stress_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      systolic_stress_seq #(8, 4, 256, 4) seq;
      phase.raise_objection(this);
      seq = systolic_stress_seq#(8, 4, 256, 4)::type_id::create("stress");
      seq.num_transactions = 50;
      seq.start(get_sequencer());
      phase.drop_objection(this);
    endtask

  endclass

  // ============================================================
  // systolic_full_test
  // Runs ALL scenarios: corners → random → stress, in sequence.
  // One simulation, complete verification.
  // ============================================================
  class systolic_full_test extends systolic_base_test #(8, 4, 256, 4);

    `uvm_component_utils(systolic_full_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      systolic_corner_seq #(8, 4, 256, 4) corner_seq;
      systolic_rand_seq #(8, 4, 256, 4)   rand_seq;
      systolic_stress_seq #(8, 4, 256, 4) stress_seq;

      phase.raise_objection(this);

      // ── Phase 1: Directed corners ──────────────────────────
      `uvm_info("TEST", "=== PHASE 1: Corner Cases ===", UVM_NONE)
      corner_seq = systolic_corner_seq#(8, 4, 256, 4)::type_id::create("corners");
      corner_seq.start(get_sequencer());

      // ── Phase 2: Constrained random ────────────────────────
      `uvm_info("TEST", "=== PHASE 2: Random (200 txns) ===", UVM_NONE)
      rand_seq = systolic_rand_seq#(8, 4, 256, 4)::type_id::create("rand");
      rand_seq.num_transactions = 200;
      rand_seq.start(get_sequencer());

      // ── Phase 3: Back-to-back stress ───────────────────────
      `uvm_info("TEST", "=== PHASE 3: Stress (50 txns) ===", UVM_NONE)
      stress_seq = systolic_stress_seq#(8, 4, 256, 4)::type_id::create("stress");
      stress_seq.num_transactions = 50;
      stress_seq.start(get_sequencer());

      phase.drop_objection(this);
    endtask

  endclass

endpackage

// ============================================================
// systolic_if.sv
// Physical interface between UVM env and the DUT.
// Parameters MUST match DUT parameters.
// ============================================================

interface systolic_if #(
    parameter int DW = 8,    // DATAWIDTH
    parameter int M  = 4,
    parameter int K  = 256,
    parameter int N  = 4
) (
    input logic clk
);

  // ── Signals ──────────────────────────────────────────────
  logic                          rst;
  logic                          load_data;
  logic        [$clog2(K+1)-1:0] k_size;
  logic signed [     M*K*DW-1:0] a_flat;
  logic signed [     K*N*DW-1:0] b_flat;
  logic                          valid_out;
  logic signed [   M*N*4*DW-1:0] c_flat;

  // ── Driver clocking block ─────────────────────────────────
  // Driver WRITES on @(cb_drv) — outputs update at the clock edge.
  // Monitor samples inputs one time unit later, avoiding clocking races.
  clocking cb_drv @(posedge clk);
    default input #1 output #0;
    output rst;
    output load_data;
    output k_size;
    output a_flat;
    output b_flat;
    input valid_out;
  endclocking

  // ── Monitor clocking block ────────────────────────────────
  // Monitor READS on @(cb_mon) — all signals are inputs.
  clocking cb_mon @(posedge clk);
    default input #1;
    input rst;
    input load_data;
    input k_size;
    input a_flat;
    input b_flat;
    input valid_out;
    input c_flat;
  endclocking

  // ── Modports ─────────────────────────────────────────────
  modport drv_mp(clocking cb_drv, input clk);
  modport mon_mp(clocking cb_mon, input clk);

  // ── Assertions ────────────────────────────────────────────
  // Industry practice: put protocol assertions in the interface
  // so they fire regardless of which test is running.

  // k_size must never be zero when load_data is asserted
  AP_KSIZE_NONZERO :
  assert property (@(posedge clk) disable iff (rst) (load_data |-> k_size > 0))
  else $error("IF_ASSERT", "load_data asserted with k_size==0!");

  // valid_out should be exactly 1 cycle wide
  AP_VALID_PULSE :
  assert property (@(posedge clk) disable iff (rst) (valid_out |=> !valid_out))
  else $error("IF_ASSERT", "valid_out held for >1 cycle!");

endinterface

////////// DUT ////////////

module systolic_full #(
    parameter int DATAWIDTH = 8,
    parameter int M = 4,
    parameter int K = 256,
    parameter int N = 4
) (
    input logic clk,
    input logic rst,
    input logic load_data,

    // Runtime inner dimension
    input logic [$clog2(K+1)-1:0] k_size,

    // FLAT 1D packed input ports
    input logic signed [M*K*DATAWIDTH-1:0] a_flat,
    input logic signed [K*N*DATAWIDTH-1:0] b_flat,

    output logic valid_out,

    // FLAT 1D packed output port
    // c[r][n] at bits [(r*N+n)*4*DATAWIDTH +: 4*DATAWIDTH]
    output logic signed [M*N*4*DATAWIDTH-1:0] c_flat
);

  localparam int CNT_WIDTH = $clog2(K + M + N + 1);

  // =========================================================================
  // Unpack flat inputs into 2D arrays - combinational only, no registers.
  // These wires are read directly by the wavefront logic every cycle.
  // =========================================================================
  logic signed [DATAWIDTH-1:0] a_in_2d[M-1:0][K-1:0];
  logic signed [DATAWIDTH-1:0] b_in_2d[K-1:0][N-1:0];

  always_comb begin
    for (int r = 0; r < M; r++)
    for (int k = 0; k < K; k++) a_in_2d[r][k] = a_flat[(r*K+k)*DATAWIDTH+:DATAWIDTH];
    for (int k = 0; k < K; k++)
    for (int n = 0; n < N; n++) b_in_2d[k][n] = b_flat[(k*N+n)*DATAWIDTH+:DATAWIDTH];
  end

  // =========================================================================
  // Control registers
  // =========================================================================
  logic [  CNT_WIDTH-1:0] total_cycles_reg;
  logic [$clog2(K+1)-1:0] k_size_reg;
  logic                   run_enable;
  logic [  CNT_WIDTH-1:0] cycle_cnt;
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
        // Latch geometry and arm the run.
        // No buffer copy needed - a_flat/b_flat are read directly.
        k_size_reg       <= k_size;
        total_cycles_reg <= CNT_WIDTH'(k_size) + CNT_WIDTH'(M) + CNT_WIDTH'(N) - 2;
        run_enable       <= 1'b1;
        cycle_cnt        <= '0;
      end

      if (run_enable && !load_data) begin
        if (cycle_cnt < total_cycles_reg) cycle_cnt <= cycle_cnt + 1;
        else begin
          run_enable   <= 1'b0;
          output_ready <= 1'b1;
        end
      end
    end
  end

  // =========================================================================
  // Wavefront feed - reads a_flat / b_flat directly, no intermediate buffer.
  //
  // For row i: the diagonal element at cycle t is a_in_2d[i][t-i]
  //   valid when run_enable && (t >= i) && (t-i < k_size_reg)
  //
  // For col j: the diagonal element at cycle t is b_in_2d[t-j][j]
  //   valid when run_enable && (t >= j) && (t-j < k_size_reg)
  //
  // a_flat / b_flat must be held stable by the caller for the entire run.
  // =========================================================================
  logic signed [DATAWIDTH-1:0] a_next_in[M-1:0];
  logic signed [DATAWIDTH-1:0] b_next_in[N-1:0];

  always_comb begin
    for (int i = 0; i < M; i++) begin
      automatic int col;
      col = int'(cycle_cnt) - i;
      if (run_enable && col >= 0 && col < int'(k_size_reg)) a_next_in[i] = a_in_2d[i][col];
      else a_next_in[i] = '0;
    end
    for (int j = 0; j < N; j++) begin
      automatic int row;
      row = int'(cycle_cnt) - j;
      if (run_enable && row >= 0 && row < int'(k_size_reg)) b_next_in[j] = b_in_2d[row][j];
      else b_next_in[j] = '0;
    end
  end

  // =========================================================================
  // PE grid - unchanged from original
  // =========================================================================
  logic signed [  DATAWIDTH-1:0] PE_A    [M-1:0][N-1:0];
  logic signed [  DATAWIDTH-1:0] PE_B    [M-1:0][N-1:0];
  logic signed [4*DATAWIDTH-1:0] PE_C_REG[M-1:0][N-1:0];

  generate
    for (genvar r = 0; r < M; r++) begin : row_loop
      for (genvar c = 0; c < N; c++) begin : col_loop
        logic signed [DATAWIDTH-1:0] a_in, b_in;

        if (c == 0) assign a_in = a_next_in[r];
        else assign a_in = PE_A[r][c-1];

        if (r == 0) assign b_in = b_next_in[c];
        else assign b_in = PE_B[r-1][c];

        always_ff @(posedge clk or posedge rst) begin
          if (rst || load_data) begin
            PE_A[r][c]     <= '0;
            PE_B[r][c]     <= '0;
            PE_C_REG[r][c] <= '0;
          end else if (run_enable) begin
            PE_A[r][c]     <= a_in;
            PE_B[r][c]     <= b_in;
            PE_C_REG[r][c] <= PE_C_REG[r][c] + (a_in * b_in);
          end
        end
      end
    end
  endgenerate

  // =========================================================================
  // Output register - unchanged from original
  // =========================================================================
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      valid_out <= 1'b0;
      c_flat    <= '0;
    end else begin
      if (output_ready) begin
        valid_out <= 1'b1;
        for (int i = 0; i < M; i++)
        for (int j = 0; j < N; j++) c_flat[(i*N+j)*4*DATAWIDTH+:4*DATAWIDTH] <= PE_C_REG[i][j];
      end else valid_out <= 1'b0;
    end
  end

endmodule


// ============================================================
// systolic_tb_top.sv
// Non-UVM module. Glues interface ↔ DUT.
// Registers vif in config_db. Launches UVM via run_test().
// ============================================================
// `timescale 1ns/1ps
`include "uvm_macros.svh"
import uvm_pkg::*;

// Parameters (match DUT)
localparam int DW = 8;
localparam int M = 4;
localparam int K = 256;
localparam int N = 4;

module systolic_tb_top;

  import systolic_pkg::*;
  import uvm_pkg::*;


  // ── Clock generation ───────────────────────────────────────
  logic clk;
  initial clk = 0;
  always #5 clk = ~clk;  // 100 MHz

  // ── Interface instantiation ────────────────────────────────
  systolic_if #(DW, M, K, N) dut_if (.clk(clk));

  // ── DUT instantiation ──────────────────────────────────────
  // NOTE: Port names connect to the interface signals (not clocking blocks)
  systolic_full #(
      .DATAWIDTH(DW),
      .M(M),
      .K(K),
      .N(N)
  ) dut (
      .clk      (dut_if.clk),
      .rst      (dut_if.rst),
      .load_data(dut_if.load_data),
      .k_size   (dut_if.k_size),
      .a_flat   (dut_if.a_flat),
      .b_flat   (dut_if.b_flat),
      .valid_out(dut_if.valid_out),
      .c_flat   (dut_if.c_flat)
  );

  // ── Register virtual interface in config_db ────────────────
  // UVM_NULL_CONTEXT ("") means "available to entire hierarchy".
  // Driver and monitor call get(this, "", "vif", vif) to retrieve it.
  initial begin
    uvm_config_db#(virtual systolic_if #(DW, M, K, N))::set(null, "uvm_test_top.*", "vif", dut_if);

    // run_test() launches the UVM phase machinery.
    // Test name comes from +UVM_TESTNAME= simulator argument:
    //   vsim ... +UVM_TESTNAME=systolic_rand_test
    //   vsim ... +UVM_TESTNAME=systolic_stress_test
    run_test("systolic_full_test");
  end

  // ── Global timeout watchdog ────────────────────────────────
  initial begin
    #(10_000_000);  // 10ms timeout
    `uvm_fatal("TIMEOUT", "Simulation exceeded 10ms — hung?");
  end

endmodule
