module lenet5_npu_sram_no_offset #(
    parameter MAX_KERNEL_SIZE     = 5,
    parameter MAX_IN_CHANNELS     = 6,
    parameter MAX_OUT_CHANNELS    = 16,
    parameter MAX_INPUT_HEIGHT    = 28,
    parameter MAX_INPUT_WIDTH     = 28,
    parameter TILE_ROWS           = 4,
    parameter ARRAY_COLS          = 4,
    parameter DATA_WIDTH          = 8,
    parameter NUM_IMG_PORTS       = 3,
    parameter MAX_BURST_LEN       = 256,
    parameter MAX_WEIGHTS         = 30720,
    parameter TOTAL_WEIGHTS       = 44190,
    parameter MAX_BIASES          = 120,
    parameter TOTAL_BIASES        = 236,
    parameter SRAM_TOTAL_ELEMENTS = 1024
)(
    input  logic clk,
    input  logic rst,

    input  logic start_layer,
    input  logic fc_mode,
    input  logic enable_relu,
    output logic layer_done,

    // Runtime geometry
    input  logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    input  logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels,
    input  logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,
    input  logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height,
    input  logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width,

    // Runtime requantization
    input  logic [31:0]        requant_scale,
    input  logic [5:0]         requant_shift,
    input  logic signed [7:0]  ZP_next,

    // Memory configuration
    input  logic [$clog2(TOTAL_WEIGHTS+1)-1:0] weight_layer_offset,
    input  logic [$clog2(MAX_WEIGHTS+1)-1:0]   weight_layer_total,
    input  logic [$clog2(TOTAL_BIASES+1)-1:0]  bias_layer_offset,
    input  logic [$clog2(MAX_BIASES+1)-1:0]    bias_layer_total,

    // Weight / bias initialization
    input  logic [$clog2(TOTAL_WEIGHTS)-1:0]  weight_write_addr,
    input  logic signed [DATA_WIDTH-1:0]       weight_write_data,
    input  logic                               weight_write_enable,
    input  logic [$clog2(TOTAL_BIASES)-1:0]   bias_write_addr,
    input  logic signed [31:0]                 bias_write_data,
    input  logic                               bias_write_enable,

    // External SRAM write (image load)
    input  logic                                    ext_wr_en,
    input  logic [$clog2(SRAM_TOTAL_ELEMENTS)-1:0] ext_wr_addr,
    input  logic signed [DATA_WIDTH-1:0]            ext_wr_data,

    output logic sram_bank_conflict,

    // FIX: thread NPU compute outputs up to cnn_top so the entire
    // compute cone is reachable from a primary output and is not
    // pruned by Vivado's backward cone elimination.
    output logic                         output_valid,
    output logic [15:0]                  output_addr,
    output logic signed [DATA_WIDTH-1:0] output_data
);

    // =========================================================================
    // NPU <-> SRAM signals
    // =========================================================================
    logic [9:0]                             npu_img_addr  [NUM_IMG_PORTS];
    logic                                   npu_img_req   [NUM_IMG_PORTS];
    logic signed [DATA_WIDTH-1:0]           npu_img_data  [NUM_IMG_PORTS];
    logic                                   npu_img_valid [NUM_IMG_PORTS];

    logic                                   npu_out_valid;
    logic [15:0]                            npu_out_addr;
    logic signed [DATA_WIDTH-1:0]           npu_out_data;

    logic [$clog2(SRAM_TOTAL_ELEMENTS)-1:0] sram_rd_addr [NUM_IMG_PORTS];
    logic                                   sram_rd_req  [NUM_IMG_PORTS];
    logic signed [DATA_WIDTH-1:0]           sram_rd_data [NUM_IMG_PORTS];
    logic                                   sram_rd_valid[NUM_IMG_PORTS];

    logic                                   sram_wr_en;
    logic [$clog2(SRAM_TOTAL_ELEMENTS)-1:0] sram_wr_addr;
    logic signed [DATA_WIDTH-1:0]           sram_wr_data;

    // =========================================================================
    // Read port wiring
    // =========================================================================
    always_comb begin
        for (int i = 0; i < NUM_IMG_PORTS; i++) begin
            sram_rd_addr[i]  = npu_img_addr[i];
            sram_rd_req[i]   = npu_img_req[i];
            npu_img_data[i]  = sram_rd_data[i];
            npu_img_valid[i] = sram_rd_valid[i];
        end
    end

    // =========================================================================
    // Write mux: external load has priority over NPU output
    // =========================================================================
    always_comb begin
        if (ext_wr_en) begin
            sram_wr_en   = 1'b1;
            sram_wr_addr = ext_wr_addr;
            sram_wr_data = ext_wr_data;
        end else if (npu_out_valid) begin
            sram_wr_en   = 1'b1;
            sram_wr_addr = npu_out_addr[$clog2(SRAM_TOTAL_ELEMENTS)-1:0];
            sram_wr_data = npu_out_data;
        end else begin
            sram_wr_en   = 1'b0;
            sram_wr_addr = '0;
            sram_wr_data = '0;
        end
    end

    // =========================================================================
    // NPU
    // =========================================================================
    lenet5_npu_complete #(
        .MAX_KERNEL_SIZE  (MAX_KERNEL_SIZE),
        .MAX_IN_CHANNELS  (MAX_IN_CHANNELS),
        .MAX_OUT_CHANNELS (MAX_OUT_CHANNELS),
        .MAX_INPUT_HEIGHT (MAX_INPUT_HEIGHT),
        .MAX_INPUT_WIDTH  (MAX_INPUT_WIDTH),
        .TILE_ROWS        (TILE_ROWS),
        .ARRAY_COLS       (ARRAY_COLS),
        .DATA_WIDTH       (DATA_WIDTH),
        .NUM_IMG_PORTS    (NUM_IMG_PORTS),
        .MAX_BURST_LEN    (MAX_BURST_LEN),
        .MAX_WEIGHTS      (MAX_WEIGHTS),
        .TOTAL_WEIGHTS    (TOTAL_WEIGHTS),
        .MAX_BIASES       (MAX_BIASES),
        .TOTAL_BIASES     (TOTAL_BIASES),
        .TOTAL_ELEMENTS   (SRAM_TOTAL_ELEMENTS)
    ) npu (
        .clk                 (clk),
        .rst                 (rst),
        .start_layer         (start_layer),
        .fc_mode             (fc_mode),
        .enable_relu         (enable_relu),
        .layer_done          (layer_done),
        .kernel_size         (kernel_size),
        .in_channels         (in_channels),
        .out_channels        (out_channels),
        .input_height        (input_height),
        .input_width         (input_width),
        .requant_scale       (requant_scale),
        .requant_shift       (requant_shift),
        .ZP_next             (ZP_next),
        .weight_layer_offset (weight_layer_offset),
        .weight_layer_total  (weight_layer_total),
        .bias_layer_offset   (bias_layer_offset),
        .bias_layer_total    (bias_layer_total),
        .weight_write_addr   (weight_write_addr),
        .weight_write_data   (weight_write_data),
        .weight_write_enable (weight_write_enable),
        .bias_write_addr     (bias_write_addr),
        .bias_write_data     (bias_write_data),
        .bias_write_enable   (bias_write_enable),
        .img_sram_addr       (npu_img_addr),
        .img_sram_read_req   (npu_img_req),
        .img_sram_data       (npu_img_data),
        .img_sram_valid      (npu_img_valid),
        // FIX: previously unconnected - now drives output ports
        .output_valid        (npu_out_valid),
        .output_addr         (npu_out_addr),
        .output_data         (npu_out_data)
    );

    // =========================================================================
    // Drive output ports - cnn_top captures these into the result register
    // =========================================================================
    assign output_valid = npu_out_valid;
    assign output_addr  = npu_out_addr;
    assign output_data  = npu_out_data;

    // =========================================================================
    // SRAM: feature_map_sram_5port
    // =========================================================================
    feature_map_sram_5port #(
        .DATA_WIDTH     (DATA_WIDTH),
        .TOTAL_ELEMENTS (SRAM_TOTAL_ELEMENTS),
        .NUM_PORTS      (NUM_IMG_PORTS)
    ) sram (
        .clk          (clk),
        .rst          (rst),
        .wr_en        (sram_wr_en),
        .wr_addr      (sram_wr_addr),
        .wr_data      (sram_wr_data),
        .rd_req       (sram_rd_req),
        .rd_addr      (sram_rd_addr),
        .rd_data      (sram_rd_data),
        .rd_valid     (sram_rd_valid),
        .bank_conflict(sram_bank_conflict)
    );

endmodule
