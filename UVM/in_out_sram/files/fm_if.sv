// =============================================================================
// INTERFACE
// =============================================================================
interface fm_if #(
    parameter int DATA_WIDTH     = 8,
    parameter int TOTAL_ELEMENTS = 864,
    parameter int NUM_PORTS      = 3
)(input logic clk);

    localparam int ADDR_W = $clog2(TOTAL_ELEMENTS);   // 10

    // ---- Write port ----
    logic                             rst;
    logic                             wr_en;
    logic [ADDR_W-1:0]               wr_addr;
    logic signed [DATA_WIDTH-1:0]    wr_data;

    // ---- Read ports ----
    logic                            rd_req  [NUM_PORTS];
    logic [ADDR_W-1:0]              rd_addr [NUM_PORTS];
    logic signed [DATA_WIDTH-1:0]   rd_data [NUM_PORTS];
    logic                            rd_valid[NUM_PORTS];

    // ---- Conflict flag ----
    logic                            bank_conflict;

    // ---- Initial values ----
    initial begin
        rst    = 1'b1;
        wr_en  = 1'b0;
        wr_addr = '0;
        wr_data = '0;
        for (int p = 0; p < NUM_PORTS; p++) begin
            rd_req [p] = 1'b0;
            rd_addr[p] = '0;
        end
    end

    // ---- Clocking blocks ----
    clocking cb_drv @(posedge clk);
        default input #1 output #0;
        output rst;
        output wr_en, wr_addr, wr_data;
        output rd_req, rd_addr;
        input  rd_data, rd_valid;
        input  bank_conflict;
    endclocking

    clocking cb_mon @(posedge clk);
        default input #1;
        input rst;
        input wr_en, wr_addr, wr_data;
        input rd_req, rd_addr;
        input rd_data, rd_valid;
        input bank_conflict;
    endclocking

    modport drv_mp (clocking cb_drv, input clk);
    modport mon_mp (clocking cb_mon, input clk);

    // ---- SVA Assertions ----

    // rd_valid[p] must be exactly the registered version of rd_req[p]
    // (checked for each port independently)
    generate
        for (genvar p = 0; p < NUM_PORTS; p++) begin : g_sva
            property p_valid_follows_req;
                @(posedge clk) disable iff (rst)
                $rose(rd_req[p]) |=> rd_valid[p];
            endproperty
            ap_valid_follows: assert property (p_valid_follows_req)
                else $error("SVA: rd_valid[%0d] did not follow rd_req[%0d]", p, p);

            property p_valid_deasserts;
                @(posedge clk) disable iff (rst)
                !rd_req[p] |=> !rd_valid[p];
            endproperty
            ap_valid_deasserts: assert property (p_valid_deasserts)
                else $error("SVA: rd_valid[%0d] did not deassert after rd_req[%0d]", p, p);
        end
    endgenerate

    // bank_conflict can only be asserted when wr_en is high
    property p_conflict_needs_wr;
        @(posedge clk) disable iff (rst)
        bank_conflict |-> wr_en;
    endproperty
    ap_conflict_wr: assert property (p_conflict_needs_wr)
        else $error("SVA: bank_conflict asserted without wr_en");

    // wr_addr must be in range
    property p_wr_addr_range;
        @(posedge clk) disable iff (rst)
        wr_en |-> (wr_addr < TOTAL_ELEMENTS);
    endproperty
    ap_wr_range: assert property (p_wr_addr_range)
        else $error("SVA: wr_addr out of range");

endinterface 