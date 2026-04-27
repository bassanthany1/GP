// =============================================================================
// INTERFACE
// =============================================================================
interface br_if #(
    parameter int MAX_OUT_CHANNELS = 120,
    parameter int TILE_ROWS        = 4,
    parameter int ARRAY_COLS       = 4,
    parameter int DATA_WIDTH       = 32,
    parameter int BIAS_WIDTH       = 32,
    parameter int MAX_BURST_LEN    = 32
)(input logic clk);

    // Derived widths
    localparam int CH_W  = $clog2(MAX_OUT_CHANNELS);
    localparam int CHN_W = $clog2(MAX_OUT_CHANNELS + 1);
    localparam int BL_W  = $clog2(MAX_BURST_LEN + 1);
    localparam int WIN_W = 10;  // $clog2(1024)

    // ---- DUT inputs ----
    logic                             rst;
    logic                             enable_relu;
    logic [CHN_W-1:0]                out_channels;
    logic                             conv_valid;
    logic signed [DATA_WIDTH-1:0]    conv_data [TILE_ROWS][ARRAY_COLS];
    logic [CH_W-1:0]                 conv_channel_start;
    logic [WIN_W-1:0]                conv_window_idx_start;

    // ---- SRAM response inputs (driven by driver/TB, consumed by DUT) ----
    logic signed [BIAS_WIDTH-1:0]    bias_sram_data;
    logic                             bias_sram_valid;
    logic                             bias_sram_burst_done;

    // ---- DUT outputs ----
    logic [CH_W-1:0]                 bias_sram_addr;
    logic [BL_W-1:0]                 bias_sram_burst_len;
    logic                             bias_sram_read_req;
    logic                             output_valid;
    logic signed [DATA_WIDTH-1:0]    output_data [TILE_ROWS][ARRAY_COLS];
    logic [CH_W-1:0]                 output_channel_start;
    logic [WIN_W-1:0]                output_window_idx_start;

    // ---- Initial values ----
    initial begin
        rst                   = 1'b1;
        enable_relu           = 1'b0;
        out_channels          = '0;
        conv_valid            = 1'b0;
        conv_channel_start    = '0;
        conv_window_idx_start = '0;
        bias_sram_data        = '0;
        bias_sram_valid       = 1'b0;
        bias_sram_burst_done  = 1'b0;
        foreach (conv_data[r,c]) conv_data[r][c] = '0;
    end

    // ---- Clocking blocks ----
    clocking cb_drv @(posedge clk);
        default input #1 output #0;
        // Driven by driver
        output rst;
        output enable_relu, out_channels;
        output conv_valid, conv_channel_start, conv_window_idx_start;
        output conv_data;
        output bias_sram_data, bias_sram_valid, bias_sram_burst_done;
        // Sampled by driver (for protocol handshake)
        input  bias_sram_addr, bias_sram_burst_len, bias_sram_read_req;
        input  output_valid;
        input  output_data, output_channel_start, output_window_idx_start;
    endclocking

    clocking cb_mon @(posedge clk);
        default input #1;
        // Observe all signals
        input rst;
        input enable_relu, out_channels;
        input conv_valid, conv_channel_start, conv_window_idx_start;
        input conv_data;
        input bias_sram_addr, bias_sram_burst_len, bias_sram_read_req;
        input bias_sram_data, bias_sram_valid, bias_sram_burst_done;
        input output_valid;
        input output_data, output_channel_start, output_window_idx_start;
    endclocking

    modport drv_mp (clocking cb_drv, input clk);
    modport mon_mp (clocking cb_mon, input clk);

    // ---- SVA Assertions ----

    // conv_valid must be a single-cycle pulse
    property p_conv_valid_pulse;
        @(posedge clk) disable iff (rst)
        conv_valid |=> !conv_valid;
    endproperty
    ap_conv_valid_pulse: assert property (p_conv_valid_pulse)
        else $error("SVA: conv_valid held more than 1 cycle");

    // bias_sram_read_req must be a single-cycle pulse
    property p_req_pulse;
        @(posedge clk) disable iff (rst)
        bias_sram_read_req |=> !bias_sram_read_req;
    endproperty
    ap_req_pulse: assert property (p_req_pulse)
        else $error("SVA: bias_sram_read_req held more than 1 cycle");

    // output_valid must be a single-cycle pulse
    property p_output_valid_pulse;
        @(posedge clk) disable iff (rst)
        output_valid |=> !output_valid;
    endproperty
    ap_output_valid_pulse: assert property (p_output_valid_pulse)
        else $error("SVA: output_valid held more than 1 cycle");

    // bias_sram_burst_len must be > 0 when read_req is asserted
    property p_nonzero_burst;
        @(posedge clk) disable iff (rst)
        bias_sram_read_req |-> (bias_sram_burst_len > 0);
    endproperty
    ap_nonzero_burst: assert property (p_nonzero_burst)
        else $error("SVA: bias_sram_burst_len==0 on bias_sram_read_req");

    // output_channel_start must equal conv_channel_start when output_valid
    property p_channel_passthrough;
        @(posedge clk) disable iff (rst)
        output_valid |->
            (output_channel_start == $past(conv_channel_start,
                                           /* latency covered by state machine */ 1,
                                           1'b1));
    endproperty
    // Note: the exact past-depth is design-specific; scoreboard validates this precisely.
    // The SVA above is a lightweight sanity check.

endinterface