// =============================================================================
// cnn_top.sv
// Wires cnn_controller <-> lenet5_npu_sram_no_offset
// No logic — pure connectivity.
// =============================================================================

module cnn_top #(
    parameter MAX_KERNEL_SIZE     = 5,
    parameter MAX_IN_CHANNELS     = 256,
    parameter MAX_OUT_CHANNELS    = 120,
    parameter MAX_INPUT_HEIGHT    = 28,
    parameter MAX_INPUT_WIDTH     = 28,
    parameter TILE_ROWS           = 8,
    parameter ARRAY_COLS          = 8,
    parameter DATA_WIDTH          = 8,
    parameter NUM_IMG_PORTS       = 5,
    parameter MAX_BURST_LEN       = 256,
    parameter MAX_WEIGHTS         = 30720,
    parameter TOTAL_WEIGHTS       = 44190,
    parameter MAX_BIASES          = 120,
    parameter TOTAL_BIASES        = 236,
    parameter SRAM_TOTAL_ELEMENTS = 1024,
    parameter NUM_LAYERS          = 7
)(
    input  logic clk,
    input  logic rst,

    // User control
    input  logic start,
    output logic inference_done,
    output logic [2:0] current_layer,

    // Weight initialisation
    input  logic [$clog2(TOTAL_WEIGHTS)-1:0]  weight_write_addr,
    input  logic signed [DATA_WIDTH-1:0]       weight_write_data,
    input  logic                               weight_write_enable,

    // Bias initialisation
    input  logic [$clog2(TOTAL_BIASES)-1:0]   bias_write_addr,
    input  logic signed [31:0]                 bias_write_data,
    input  logic                               bias_write_enable,

    // Image load
    input  logic                                       ext_wr_en,
    input  logic [$clog2(SRAM_TOTAL_ELEMENTS)-1:0]    ext_wr_addr,
    input  logic signed [DATA_WIDTH-1:0]               ext_wr_data,

    // Status
    output logic sram_bank_conflict
);

    // =========================================================================
    // Controller -> NPU wires
    // =========================================================================
    logic ctrl_start_layer;
    logic npu_layer_done;

    logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  ctrl_kernel_size;
    logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  ctrl_in_channels;
    logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] ctrl_out_channels;
    logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] ctrl_input_height;
    logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  ctrl_input_width;
    logic        ctrl_fc_mode;
    logic        ctrl_enable_relu;
    logic [31:0] ctrl_requant_scale;
    logic [5:0]  ctrl_requant_shift;
    logic signed [7:0] ctrl_ZP_next;
    logic [$clog2(TOTAL_WEIGHTS+1)-1:0] ctrl_weight_layer_offset;
    logic [$clog2(MAX_WEIGHTS+1)-1:0]   ctrl_weight_layer_total;
    logic [$clog2(TOTAL_BIASES+1)-1:0]  ctrl_bias_layer_offset;
    logic [$clog2(MAX_BIASES+1)-1:0]    ctrl_bias_layer_total;
    logic [15:0] ctrl_fm_read_base;
    logic [15:0] ctrl_fm_write_base;

    // =========================================================================
    // CNN Controller
    // =========================================================================
    cnn_controller #(
        .MAX_KERNEL_SIZE  (MAX_KERNEL_SIZE),
        .MAX_IN_CHANNELS  (MAX_IN_CHANNELS),
        .MAX_OUT_CHANNELS (MAX_OUT_CHANNELS),
        .MAX_INPUT_HEIGHT (MAX_INPUT_HEIGHT),
        .MAX_INPUT_WIDTH  (MAX_INPUT_WIDTH),
        .TOTAL_WEIGHTS    (TOTAL_WEIGHTS),
        .MAX_WEIGHTS      (MAX_WEIGHTS),
        .TOTAL_BIASES     (TOTAL_BIASES),
        .MAX_BIASES       (MAX_BIASES),
        .NUM_LAYERS       (NUM_LAYERS)
    ) u_ctrl (
        .clk                  (clk),
        .rst                  (rst),
        .start_inference      (start),
        .inference_done       (inference_done),
        .current_layer        (current_layer),
        .start_layer          (ctrl_start_layer),
        .layer_done           (npu_layer_done),
        .kernel_size          (ctrl_kernel_size),
        .in_channels          (ctrl_in_channels),
        .out_channels         (ctrl_out_channels),
        .input_height         (ctrl_input_height),
        .input_width          (ctrl_input_width),
        .fc_mode              (ctrl_fc_mode),
        .enable_relu          (ctrl_enable_relu),
        .requant_scale        (ctrl_requant_scale),
        .requant_shift        (ctrl_requant_shift),
        .ZP_next              (ctrl_ZP_next),
        .weight_layer_offset  (ctrl_weight_layer_offset),
        .weight_layer_total   (ctrl_weight_layer_total),
        .bias_layer_offset    (ctrl_bias_layer_offset),
        .bias_layer_total     (ctrl_bias_layer_total),
        .fm_read_base         (ctrl_fm_read_base),
        .fm_write_base        (ctrl_fm_write_base)
    );

    // =========================================================================
    // NPU + feature-map SRAM
    // =========================================================================
    lenet5_npu_sram_no_offset #(
        .MAX_KERNEL_SIZE     (MAX_KERNEL_SIZE),
        .MAX_IN_CHANNELS     (MAX_IN_CHANNELS),
        .MAX_OUT_CHANNELS    (MAX_OUT_CHANNELS),
        .MAX_INPUT_HEIGHT    (MAX_INPUT_HEIGHT),
        .MAX_INPUT_WIDTH     (MAX_INPUT_WIDTH),
        .TILE_ROWS           (TILE_ROWS),
        .ARRAY_COLS          (ARRAY_COLS),
        .DATA_WIDTH          (DATA_WIDTH),
        .NUM_IMG_PORTS       (NUM_IMG_PORTS),
        .MAX_BURST_LEN       (MAX_BURST_LEN),
        .MAX_WEIGHTS         (MAX_WEIGHTS),
        .TOTAL_WEIGHTS       (TOTAL_WEIGHTS),
        .MAX_BIASES          (MAX_BIASES),
        .TOTAL_BIASES        (TOTAL_BIASES),
        .SRAM_TOTAL_ELEMENTS (SRAM_TOTAL_ELEMENTS)
    ) u_npu (
        .clk                  (clk),
        .rst                  (rst),
        .start_layer          (ctrl_start_layer),
        .layer_done           (npu_layer_done),
        .fc_mode              (ctrl_fc_mode),
        .enable_relu          (ctrl_enable_relu),
        .kernel_size          (ctrl_kernel_size),
        .in_channels          (ctrl_in_channels),
        .out_channels         (ctrl_out_channels),
        .input_height         (ctrl_input_height),
        .input_width          (ctrl_input_width),
        .requant_scale        (ctrl_requant_scale),
        .requant_shift        (ctrl_requant_shift),
        .ZP_next              (ctrl_ZP_next),
        .weight_layer_offset  (ctrl_weight_layer_offset),
        .weight_layer_total   (ctrl_weight_layer_total),
        .bias_layer_offset    (ctrl_bias_layer_offset),
        .bias_layer_total     (ctrl_bias_layer_total),
        .weight_write_addr    (weight_write_addr),
        .weight_write_data    (weight_write_data),
        .weight_write_enable  (weight_write_enable),
        .bias_write_addr      (bias_write_addr),
        .bias_write_data      (bias_write_data),
        .bias_write_enable    (bias_write_enable),
        .ext_wr_en            (ext_wr_en),
        .ext_wr_addr          (ext_wr_addr),
        .ext_wr_data          (ext_wr_data),
        .sram_bank_conflict   (sram_bank_conflict)
    );

endmodule
