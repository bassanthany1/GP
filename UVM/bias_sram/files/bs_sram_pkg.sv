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

    `include "bs_sram_seq_item.svh"
    `include "bs_sram_ref_model.svh" 
    `include "bs_sram_driver.svh"
    `include "bs_sram_monitor.svh"
    
    `include "bs_sram_agent.svh"
    `include "bs_sram_scoreboard.svh"
    `include "bs_sram_coverage.svh"
    `include "bs_sram_env.svh"
    `include "bs_sram_sequences.svh"
    `include "bs_sram_tests.svh"
    
endpackage