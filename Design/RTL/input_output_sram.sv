module feature_map_sram_5port #(
    parameter DATA_WIDTH     = 8,
    parameter TOTAL_ELEMENTS = 864,
    parameter NUM_PORTS      = 3
)(
    input  logic clk,
    input  logic rst,

    // Single write port
    input  logic                              wr_en,
    input  logic [$clog2(TOTAL_ELEMENTS)-1:0] wr_addr,
    input  logic signed [DATA_WIDTH-1:0]      wr_data,
module feature_map_sram_5port #(
    parameter DATA_WIDTH     = 8,
    parameter TOTAL_ELEMENTS = 864,
    parameter NUM_PORTS      = 3
)(
    input  logic clk,
    input  logic rst,

    // Single write port
    input  logic                              wr_en,
    input  logic [$clog2(TOTAL_ELEMENTS)-1:0] wr_addr,
    input  logic signed [DATA_WIDTH-1:0]      wr_data,

    // 3 independent read ports
    input  logic                              rd_req  [NUM_PORTS],
    input  logic [$clog2(TOTAL_ELEMENTS)-1:0] rd_addr [NUM_PORTS],
    output logic signed [DATA_WIDTH-1:0]      rd_data [NUM_PORTS],
    output logic                              rd_valid[NUM_PORTS],

    output logic bank_conflict
);
    // =========================================================
    // 3 BANKS
    // Bank assignment: addr % 3
    // Bank address:    addr / 3
    // =========================================================
    localparam BANK_DEPTH      = (TOTAL_ELEMENTS + 2) / 3;
    localparam BANK_ADDR_WIDTH = $clog2(BANK_DEPTH);

    logic signed [DATA_WIDTH-1:0] bank0 [0:BANK_DEPTH-1];
    logic signed [DATA_WIDTH-1:0] bank1 [0:BANK_DEPTH-1];
    logic signed [DATA_WIDTH-1:0] bank2 [0:BANK_DEPTH-1];

    // =========================================================
    // WRITE PATH
    // =========================================================
    logic [1:0]                  wr_bank;
    logic [BANK_ADDR_WIDTH-1:0]  wr_baddr;

    assign wr_bank  = wr_addr % 3;
    assign wr_baddr = wr_addr / 3;

    always_ff @(posedge clk) begin
        if (wr_en) begin
            case (wr_bank)
                2'd0: bank0[wr_baddr] <= wr_data;
                2'd1: bank1[wr_baddr] <= wr_data;
                2'd2: bank2[wr_baddr] <= wr_data;
                default: ;
            endcase
        end
    end

    // =========================================================
    // READ DECODE (combinational) - 3 ports
    // =========================================================
    logic [1:0]                 rb [NUM_PORTS];
    logic [BANK_ADDR_WIDTH-1:0] rba[NUM_PORTS];

    assign rb[0] = rd_addr[0] % 3; assign rba[0] = rd_addr[0] / 3;
    assign rb[1] = rd_addr[1] % 3; assign rba[1] = rd_addr[1] / 3;
    assign rb[2] = rd_addr[2] % 3; assign rba[2] = rd_addr[2] / 3;

    // =========================================================
    // READ PATH - PORT 0
    // =========================================================
    always_ff @(posedge clk) begin
        if (rst) begin rd_valid[0] <= 0; rd_data[0] <= 0; end
        else begin
            rd_valid[0] <= rd_req[0];
            if (rd_req[0]) begin
                case (rb[0])
                    2'd0: rd_data[0] <= bank0[rba[0]];
                    2'd1: rd_data[0] <= bank1[rba[0]];
                    2'd2: rd_data[0] <= bank2[rba[0]];
                    default: rd_data[0] <= 0;
                endcase
            end
        end
    end

    // =========================================================
    // READ PATH - PORT 1
    // =========================================================
    always_ff @(posedge clk) begin
        if (rst) begin rd_valid[1] <= 0; rd_data[1] <= 0; end
        else begin
            rd_valid[1] <= rd_req[1];
            if (rd_req[1]) begin
                case (rb[1])
                    2'd0: rd_data[1] <= bank0[rba[1]];
                    2'd1: rd_data[1] <= bank1[rba[1]];
                    2'd2: rd_data[1] <= bank2[rba[1]];
                    default: rd_data[1] <= 0;
                endcase
            end
        end
    end

    // =========================================================
    // READ PATH - PORT 2
    // =========================================================
    always_ff @(posedge clk) begin
        if (rst) begin rd_valid[2] <= 0; rd_data[2] <= 0; end
        else begin
            rd_valid[2] <= rd_req[2];
            if (rd_req[2]) begin
                case (rb[2])
                    2'd0: rd_data[2] <= bank0[rba[2]];
                    2'd1: rd_data[2] <= bank1[rba[2]];
                    2'd2: rd_data[2] <= bank2[rba[2]];
                    default: rd_data[2] <= 0;
                endcase
            end
        end
    end

    // =========================================================
    // CONFLICT DETECTION (write vs any of 3 read ports)
    // =========================================================
    assign bank_conflict = wr_en & (
        (rd_req[0] & (rb[0] == wr_bank)) |
        (rd_req[1] & (rb[1] == wr_bank)) |
        (rd_req[2] & (rb[2] == wr_bank))
    );

endmodule

    // 3 independent read ports
    input  logic                              rd_req  [NUM_PORTS],
    input  logic [$clog2(TOTAL_ELEMENTS)-1:0] rd_addr [NUM_PORTS],
    output logic signed [DATA_WIDTH-1:0]      rd_data [NUM_PORTS],
    output logic                              rd_valid[NUM_PORTS],

    output logic bank_conflict
);
    // =========================================================
    // 3 BANKS
    // Bank assignment: addr % 3
    // Bank address:    addr / 3
    // =========================================================
    localparam BANK_DEPTH      = (TOTAL_ELEMENTS + 2) / 3;
    localparam BANK_ADDR_WIDTH = $clog2(BANK_DEPTH);

    logic signed [DATA_WIDTH-1:0] bank0 [0:BANK_DEPTH-1];
    logic signed [DATA_WIDTH-1:0] bank1 [0:BANK_DEPTH-1];
    logic signed [DATA_WIDTH-1:0] bank2 [0:BANK_DEPTH-1];

    // =========================================================
    // WRITE PATH
    // =========================================================
    logic [1:0]                  wr_bank;
    logic [BANK_ADDR_WIDTH-1:0]  wr_baddr;

    assign wr_bank  = wr_addr % 3;
    assign wr_baddr = wr_addr / 3;

    always_ff @(posedge clk) begin
        if (wr_en) begin
            case (wr_bank)
                2'd0: bank0[wr_baddr] <= wr_data;
                2'd1: bank1[wr_baddr] <= wr_data;
                2'd2: bank2[wr_baddr] <= wr_data;
                default: ;
            endcase
        end
    end

    // =========================================================
    // READ DECODE (combinational) - 3 ports
    // =========================================================
    logic [1:0]                 rb [NUM_PORTS];
    logic [BANK_ADDR_WIDTH-1:0] rba[NUM_PORTS];

    assign rb[0] = rd_addr[0] % 3; assign rba[0] = rd_addr[0] / 3;
    assign rb[1] = rd_addr[1] % 3; assign rba[1] = rd_addr[1] / 3;
    assign rb[2] = rd_addr[2] % 3; assign rba[2] = rd_addr[2] / 3;

    // =========================================================
    // READ PATH - PORT 0
    // =========================================================
    always_ff @(posedge clk) begin
        if (rst) begin rd_valid[0] <= 0; rd_data[0] <= 0; end
        else begin
            rd_valid[0] <= rd_req[0];
            if (rd_req[0]) begin
                case (rb[0])
                    2'd0: rd_data[0] <= bank0[rba[0]];
                    2'd1: rd_data[0] <= bank1[rba[0]];
                    2'd2: rd_data[0] <= bank2[rba[0]];
                    default: rd_data[0] <= 0;
                endcase
            end
        end
    end

    // =========================================================
    // READ PATH - PORT 1
    // =========================================================
    always_ff @(posedge clk) begin
        if (rst) begin rd_valid[1] <= 0; rd_data[1] <= 0; end
        else begin
            rd_valid[1] <= rd_req[1];
            if (rd_req[1]) begin
                case (rb[1])
                    2'd0: rd_data[1] <= bank0[rba[1]];
                    2'd1: rd_data[1] <= bank1[rba[1]];
                    2'd2: rd_data[1] <= bank2[rba[1]];
                    default: rd_data[1] <= 0;
                endcase
            end
        end
    end

    // =========================================================
    // READ PATH - PORT 2
    // =========================================================
    always_ff @(posedge clk) begin
        if (rst) begin rd_valid[2] <= 0; rd_data[2] <= 0; end
        else begin
            rd_valid[2] <= rd_req[2];
            if (rd_req[2]) begin
                case (rb[2])
                    2'd0: rd_data[2] <= bank0[rba[2]];
                    2'd1: rd_data[2] <= bank1[rba[2]];
                    2'd2: rd_data[2] <= bank2[rba[2]];
                    default: rd_data[2] <= 0;
                endcase
            end
        end
    end

    // =========================================================
    // CONFLICT DETECTION (write vs any of 3 read ports)
    // =========================================================
    assign bank_conflict = wr_en & (
        (rd_req[0] & (rb[0] == wr_bank)) |
        (rd_req[1] & (rb[1] == wr_bank)) |
        (rd_req[2] & (rb[2] == wr_bank))
    );

endmodule
