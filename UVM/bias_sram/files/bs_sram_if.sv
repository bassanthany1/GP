// =============================================================================
// INTERFACE
// =============================================================================
interface bs_sram_if #(
    parameter int DATA_WIDTH    = 32,
    parameter int MAX_BURST_LEN = 16,
    parameter int MAX_BIASES    = 120,
    parameter int TOTAL_BIASES  = 236
)(input logic clk);

    logic                                         rst;
    logic [$clog2(TOTAL_BIASES+1)-1:0]            layer_offset;
    logic [$clog2(TOTAL_BIASES)-1:0]              write_addr;
    logic signed [DATA_WIDTH-1:0]                 write_data;
    logic                                         write_enable;
    logic [$clog2(MAX_BIASES)-1:0]                read_addr;
    logic [$clog2(MAX_BURST_LEN+1)-1:0]           burst_length;
    logic                                         read_request;
    logic signed [DATA_WIDTH-1:0]                 read_data;
    logic                                         read_valid;
    logic                                         burst_complete;

    initial begin
        rst          = 1'b1;
        layer_offset = '0;
        write_addr   = '0;
        write_data   = '0;
        write_enable = 1'b0;
        read_addr    = '0;
        burst_length = '0;
        read_request = 1'b0;
    end

    clocking cb_drv @(posedge clk);
        default input #1 output #0;
        output rst;
        output layer_offset;
        output write_addr, write_data, write_enable;
        output read_addr, burst_length, read_request;
        input  read_data, read_valid, burst_complete;
    endclocking

    clocking cb_mon @(posedge clk);
        default input #1;
        input rst;
        input layer_offset;
        input write_addr, write_data, write_enable;
        input read_addr, burst_length, read_request;
        input read_data, read_valid, burst_complete;
    endclocking

    modport drv_mp (clocking cb_drv, input clk);
    modport mon_mp (clocking cb_mon, input clk);

    // ------------------------------------------------------------------
    // SVA assertions
    // ------------------------------------------------------------------
    property p_req_single_cycle;
        @(posedge clk) read_request |=> !read_request;
    endproperty
    ap_req_single: assert property (p_req_single_cycle)
        else $error("SVA: read_request held >1 cycle");

    property p_complete_single_cycle;
        @(posedge clk) burst_complete |=> !burst_complete;
    endproperty
    ap_complete_single: assert property (p_complete_single_cycle)
        else $error("SVA: burst_complete held >1 cycle");

    property p_no_collision;
        @(posedge clk) !(write_enable && read_request);
    endproperty
    ap_no_collision: assert property (p_no_collision)
        else $error("SVA: write_enable and read_request both asserted");

    property p_nonzero_burst;
        @(posedge clk) read_request |-> (burst_length > 0);
    endproperty
    ap_nonzero: assert property (p_nonzero_burst)
        else $error("SVA: burst_length==0 on read_request");

    property p_burst_len_in_range;
        @(posedge clk) read_request |-> (burst_length <= MAX_BURST_LEN);
    endproperty
    ap_burst_range: assert property (p_burst_len_in_range)
        else $error("SVA: burst_length exceeds MAX_BURST_LEN");

endinterface