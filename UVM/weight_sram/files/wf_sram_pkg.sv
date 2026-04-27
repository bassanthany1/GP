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

    `include "wf_sram_seq_item.svh"
    `include "wf_sram_ref_model.svh" 
    `include "wf_sram_driver.svh"
    `include "wf_sram_monitor.svh"
    
    `include "wf_sram_agent.svh"
    `include "wf_sram_scoreboard.svh"
    `include "wf_sram_coverage.svh"
    `include "wf_sram_env.svh"
    `include "wf_sram_sequences.svh"
    `include "wf_sram_tests.svh"
    

endpackage