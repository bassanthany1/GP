module lenet5_layer_processor #(
    parameter MAX_KERNEL_SIZE   = 5,
    parameter MAX_IN_CHANNELS   = 256,
    parameter MAX_OUT_CHANNELS  = 120,
    parameter MAX_INPUT_HEIGHT  = 28,
    parameter MAX_INPUT_WIDTH   = 28,
    parameter TOTAL_ELEMENTS    = 32768,
    parameter TILE_ROWS         = 4,
    parameter ARRAY_COLS        = 4,
    parameter DATA_WIDTH        = 8,
    parameter NUM_IMG_PORTS     = 3,
    parameter MAX_BURST_LEN     = 256,
    parameter MAX_WEIGHTS       = 30720,
    parameter TOTAL_WEIGHTS     = 44190,
    parameter MAX_BIASES        = 120,
    parameter TOTAL_BIASES      = 236
)(
    input  logic clk,
    input  logic rst,

    input  logic start_layer,
    input  logic fc_mode,
    input  logic enable_relu,
    output logic layer_done,

    input logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    input logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels,
    input logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,
    input logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height,
    input logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width,

    input logic [31:0]       requant_scale,
    input logic [5:0]        requant_shift,
    input logic signed [7:0] ZP_next,

    input logic [$clog2(TOTAL_WEIGHTS+1)-1:0] weight_layer_offset,
  
    input logic [$clog2(TOTAL_BIASES+1)-1:0]  bias_layer_offset,
  

    input logic [$clog2(TOTAL_WEIGHTS)-1:0] weight_write_addr,
    input logic signed [DATA_WIDTH-1:0]     weight_write_data,
    input logic                             weight_write_enable,

    input logic [$clog2(TOTAL_BIASES)-1:0] bias_write_addr,
    input logic signed [31:0]              bias_write_data,
    input logic                            bias_write_enable,

    // img_sram_addr width = $clog2(TOTAL_ELEMENTS) ? unified throughout hierarchy
    output logic [9:0] img_sram_addr [NUM_IMG_PORTS],
    output logic                               img_sram_read_req [NUM_IMG_PORTS],
    input  logic signed [DATA_WIDTH-1:0]       img_sram_data [NUM_IMG_PORTS],
    input  logic                               img_sram_valid [NUM_IMG_PORTS],

    output logic output_valid,
    output logic signed [7:0] output_data [TILE_ROWS][ARRAY_COLS],
    output logic [$clog2(MAX_OUT_CHANNELS)-1:0]                 output_channel_start,
    output logic [$clog2(MAX_INPUT_HEIGHT*MAX_INPUT_WIDTH)-1:0] output_window_idx_start
);

    // =========================================================================
    // Internal SRAM interface
    // =========================================================================
    logic [$clog2(MAX_WEIGHTS)-1:0]      weight_read_addr;
    logic [$clog2(MAX_BURST_LEN+1)-1:0]  weight_burst_len;
    logic                                 weight_read_req;
    logic signed [DATA_WIDTH-1:0]         weight_read_data;
    logic                                 weight_read_valid;
    logic                                 weight_burst_complete;

    logic [$clog2(MAX_BIASES)-1:0]       bias_read_addr;
    logic [$clog2(MAX_BURST_LEN+1)-1:0]  bias_burst_len;
    logic                                 bias_read_req;
    logic signed [31:0]                   bias_read_data;
    logic                                 bias_read_valid;
    logic                                 bias_burst_complete;

    // =========================================================================
    // WEIGHT SRAM
    // =========================================================================
    weight_sram_lenet5_actual #(
        .DATA_WIDTH    (DATA_WIDTH),
        .MAX_BURST_LEN (MAX_BURST_LEN),
        .MAX_WEIGHTS   (MAX_WEIGHTS),
        .TOTAL_WEIGHTS (TOTAL_WEIGHTS)
    ) weight_memory (
        .clk                 (clk),
        .rst                 (rst),
        .layer_offset        (weight_layer_offset),
      
        .write_addr          (weight_write_addr),
        .write_data          (weight_write_data),
        .write_enable        (weight_write_enable),
        .read_addr           (weight_read_addr),
        .burst_length        (weight_burst_len),
        .read_request        (weight_read_req),
        .read_data           (weight_read_data),
        .read_valid          (weight_read_valid),
        .burst_complete      (weight_burst_complete)
    );

    // =========================================================================
    // BIAS SRAM
    // =========================================================================
    bias_sram_lenet5 #(
        .DATA_WIDTH    (32),
        .MAX_BURST_LEN (MAX_BURST_LEN),
        .MAX_BIASES    (MAX_BIASES),
        .TOTAL_BIASES  (TOTAL_BIASES)
    ) bias_memory (
        .clk                (clk),
        .rst                (rst),
        .layer_offset       (bias_layer_offset),
       
        .write_addr         (bias_write_addr),
        .write_data         (bias_write_data),
        .write_enable       (bias_write_enable),
        .read_addr          (bias_read_addr),
        .burst_length       (bias_burst_len),
        .read_request       (bias_read_req),
        .read_data          (bias_read_data),
        .read_valid         (bias_read_valid),
        .burst_complete     (bias_burst_complete)
    );

    // =========================================================================
    // CONV + BIAS + REQUANT PIPELINE
    // img_sram_addr uses $clog2(TOTAL_ELEMENTS) ? matches hierarchy
    // =========================================================================
    conv_bias_requant_integrated #(
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
        .TOTAL_ELEMENTS   (TOTAL_ELEMENTS)
    ) processing_pipeline (
        .clk                    (clk),
        .rst                    (rst),
        .start_pipeline         (start_layer),
        .fc_mode                (fc_mode),
        .enable_relu            (enable_relu),
        .pipeline_done          (layer_done),
        .kernel_size            (kernel_size),
        .in_channels            (in_channels),
        .out_channels           (out_channels),
        .input_height           (input_height),
        .input_width            (input_width),
        .requant_scale          (requant_scale),
        .requant_shift          (requant_shift),
        .ZP_next                (ZP_next),
        .img_sram_addr          (img_sram_addr),
        .img_sram_read_req      (img_sram_read_req),
        .img_sram_data          (img_sram_data),
        .img_sram_valid         (img_sram_valid),
        .weight_sram_addr       (weight_read_addr),
        .weight_sram_burst_len  (weight_burst_len),
        .weight_sram_read_req   (weight_read_req),
        .weight_sram_data       (weight_read_data),
        .weight_sram_valid      (weight_read_valid),
        .weight_sram_burst_done (weight_burst_complete),
        .bias_sram_addr         (bias_read_addr),
        .bias_sram_burst_len    (bias_burst_len),
        .bias_sram_read_req     (bias_read_req),
        .bias_sram_data         (bias_read_data),
        .bias_sram_valid        (bias_read_valid),
        .bias_sram_burst_done   (bias_burst_complete),
        .output_valid           (output_valid),
        .output_data            (output_data),
        .output_channel_start   (output_channel_start),
        .output_window_idx_start(output_window_idx_start)
    );

endmodule
