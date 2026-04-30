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

        
        
        `include "fm_seq_item.svh"
        `include "fm_ref_model.svh" 
        `include "fm_driver.svh"
        `include "fm_monitor.svh"
    
        `include "fm_agent.svh"
        `include "fm_scoreboard.svh"
        `include "fm_coverage.svh"
        `include "fm_env.svh"
        `include "fm_sequences.svh"
       `include "fm_tests.svh"

endpackage