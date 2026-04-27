// =============================================================================
// PACKAGE
// =============================================================================
package br_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // -------------------------------------------------------------------------
    // Parameters – must match DUT
    // -------------------------------------------------------------------------
    localparam int PKG_MAX_OUT_CHANNELS = 120;
    localparam int PKG_TILE_ROWS        = 4;
    localparam int PKG_ARRAY_COLS       = 4;
    localparam int PKG_DATA_WIDTH       = 32;
    localparam int PKG_BIAS_WIDTH       = 32;
    localparam int PKG_MAX_BURST_LEN    = 32;
    localparam int PKG_WIN_IDX_W        = 10;   // $clog2(1024)

    // Derived widths (mirrors DUT's $clog2 expressions)
    localparam int CH_W  = $clog2(PKG_MAX_OUT_CHANNELS);       // channel addr width
    localparam int CHN_W = $clog2(PKG_MAX_OUT_CHANNELS + 1);  // out_channels width
    localparam int BL_W  = $clog2(PKG_MAX_BURST_LEN + 1);     // burst_len width

        `include "br_seq_item.svh"
        `include "br_ref_model.svh" 
        `include "br_driver.svh"
        `include "br_monitor.svh"
    
        `include "br_agent.svh"
        `include "br_scoreboard.svh"
        `include "br_coverage.svh"
        `include "br_env.svh"
        `include "br_sequences.svh"
       `include "br_tests.svh"

endpackage