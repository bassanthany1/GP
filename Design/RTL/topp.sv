// =============================================================================
// cnn_top.sv
// Wires cnn_controller <-> lenet5_npu_sram_no_offset
// No logic ? pure connectivity, except for the result capture and argmax.
//
// Output ports:
//   predicted_digit [3:0] ? binary encoding of the winning class (0..9)
//                           e.g. digit 7 ? 4'b0111
//   result_valid          ? pulses HIGH for one cycle when predicted_digit
//                           is valid. Only fires at the last layer (FC3).
// =============================================================================

module cnn_top #(
    parameter MAX_KERNEL_SIZE     = 5,
    parameter MAX_IN_CHANNELS     = 256,
    parameter MAX_OUT_CHANNELS    = 120,
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
    parameter SRAM_TOTAL_ELEMENTS = 1024,
    parameter NUM_LAYERS          = 5,
    parameter NUM_CLASSES         = 10
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
    input  logic                                    ext_wr_en,
    input  logic [$clog2(SRAM_TOTAL_ELEMENTS)-1:0] ext_wr_addr,
    input  logic signed [DATA_WIDTH-1:0]            ext_wr_data,

    // Status
    output logic sram_bank_conflict,

    // Classification result:
    //   result_valid    ? pulses one cycle when predicted_digit is valid
    //   predicted_digit ? 4-bit binary encoding of the winning class
    //                     e.g. class 7 ? 4'b0111
    //                     Only updates at the last layer (FC3).
    output logic       result_valid,
    output logic [3:0] predicted_digit
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
 
    logic [$clog2(TOTAL_BIASES+1)-1:0]  ctrl_bias_layer_offset;
   

    // =========================================================================
    // Internal NPU output wires
    // =========================================================================
    logic                         npu_out_valid;
    logic [15:0]                  npu_out_addr;
    logic signed [DATA_WIDTH-1:0] npu_out_data;

    // =========================================================================
    // Score accumulation buffer + argmax
    //
    // As FC3 writes its 10 output scores one by one (addr 0..9), we track
    // the running maximum and update predicted_digit whenever a new score
    // beats the current best.
    //
    // When addr == NUM_CLASSES-1 (last score written) result_valid pulses
    // for one cycle and predicted_digit holds the final argmax.
    //
    // Gated on current_layer == NUM_LAYERS-1 so FC1/FC2 outputs (which also
    // start at addr 0) do not corrupt the result.
    // =========================================================================
    logic signed [DATA_WIDTH-1:0] running_max;
    logic [3:0]                   running_best;

    // True when the current output belongs to the last layer
    wire last_layer = (current_layer == 3'(NUM_LAYERS - 1));

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            running_max     <= '1;          // most-negative signed value (0x80)
            running_max[DATA_WIDTH-1] <= 1'b1;
            running_best    <= 4'd0;
            predicted_digit <= 4'd0;
            result_valid    <= 1'b0;
        end else begin
            result_valid <= 1'b0;           // default: deasserted

            if (start) begin
                // Clear for new inference ? reset running max to most-negative
                running_max              <= '0;
                running_max[DATA_WIDTH-1]<= 1'b1;   // = -128 in signed INT8
                running_best             <= 4'd0;
                predicted_digit          <= 4'd0;

            end else if (npu_out_valid
                         && npu_out_addr < 16'(NUM_CLASSES)
                         && last_layer) begin

                // Update running argmax whenever a new score arrives
                if (npu_out_data > running_max) begin
                    running_max  <= npu_out_data;
                    running_best <= 4'(npu_out_addr);
                end

                // Last score has arrived ? latch result and pulse valid
                if (npu_out_addr == 16'(NUM_CLASSES - 1)) begin
                    // Final check: does the last score beat the running max?
                    if (npu_out_data > running_max)
                        predicted_digit <= 4'(npu_out_addr);
                    else
                        predicted_digit <= running_best;

                    result_valid <= 1'b1;
                end
            end
        end
    end

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
     
        .bias_layer_offset    (ctrl_bias_layer_offset)
       
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
       
        .bias_layer_offset    (ctrl_bias_layer_offset),
       
        .weight_write_addr    (weight_write_addr),
        .weight_write_data    (weight_write_data),
        .weight_write_enable  (weight_write_enable),
        .bias_write_addr      (bias_write_addr),
        .bias_write_data      (bias_write_data),
        .bias_write_enable    (bias_write_enable),
        .ext_wr_en            (ext_wr_en),
        .ext_wr_addr          (ext_wr_addr),
        .ext_wr_data          (ext_wr_data),
        .sram_bank_conflict   (sram_bank_conflict),
        .output_valid         (npu_out_valid),
        .output_addr          (npu_out_addr),
        .output_data          (npu_out_data)
    );

endmodule
