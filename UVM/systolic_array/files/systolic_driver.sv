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