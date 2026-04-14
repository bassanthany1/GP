module cnn_top_synth (
    input  logic        clk,
    input  logic        rst,
input logic soft_rst,
    input  logic        uart_rx,
    output logic        uart_tx,

    output logic        npu_ready,
    output logic        npu_error,

    output logic [3:0]  predicted_digit,
    output logic        result_valid_lat,
    output logic        inference_done,
    output logic [2:0]  current_layer,
    output logic        sram_bank_conflict
);

    // =========================================================================
    // Internal wires
    // =========================================================================

    logic [15:0] w_addr;
    logic [7:0]  w_data;
    logic        w_en;
    logic        w_done;

    logic [7:0]  b_addr;
    logic [31:0] b_data;
    logic        b_en;
    logic        b_done;

    logic [9:0]  i_addr;
    logic [7:0]  i_data;
    logic        i_en;
    logic        image_loaded;

    logic        result_valid_pulse;
    logic [3:0]  digit_raw;
logic compute_rst;
assign compute_rst = rst | soft_rst;
    // =========================================================================
    // npu_ready
    // =========================================================================
    assign npu_ready = w_done & b_done;

    // =========================================================================
    // FIX C ? result_valid_lat with 1-cycle delayed clear
    //
    // Using image_loaded directly as the clear would race against the FF's
    // output: on the edge where image_loaded arrives, Q is still the OLD value.
    // TX_IDLE (in uart_image_loader) reads result_valid_lat combinatorially,
    // so it would see HIGH and spuriously transmit the previous inference's
    // digit. By delaying the clear by one cycle (image_loaded_d), the latch
    // goes LOW on cycle N+1, which is definitively AFTER TX_IDLE has been
    // blocked by the !image_loaded guard in uart_image_loader (FIX B).
    //
    // Timeline:
    //   Cycle N  : image_loaded=1   TX blocked by !image_loaded guard
    //              result_valid_lat still HIGH (clear not yet applied)
    //   Cycle N+1: image_loaded_d=1 result_valid_lat ? 0
    //              TX blocked by !image_loaded_r guard
    //   Cycle N+2: both guards clear, latch is definitively 0, TX stays idle
    //   ...
    //   Cycle M  : result_valid_pulse from inference 2 ? result_valid_lat ? 1
    //   Cycle M  : TX sees result_valid_lat=1, img_state=IMG_DONE ? transmits
    // =========================================================================
    logic image_loaded_d;
    always_ff @(posedge clk) begin
        if (rst) image_loaded_d <= 1'b0;
        else     image_loaded_d <= image_loaded;
    end

    always_ff @(posedge clk) begin
        if (compute_rst|| image_loaded_d) begin
            result_valid_lat <= 1'b0;
        end else if (result_valid_pulse) begin
            result_valid_lat <= 1'b1;
        end
    end

    // =========================================================================
    // 1. Weight ROM Loader
    // =========================================================================
    weight_rom_loader #(
        .TOTAL_WEIGHTS  (44190),
        .ADDR_WIDTH     (16),
        .DATA_WIDTH     (8)
    ) u_weight_rom (
        .clk                 (clk),
        .rst                 (rst),
        .weight_write_addr   (w_addr),
        .weight_write_data   (w_data),
        .weight_write_enable (w_en),
        .loading_done        (w_done)
    );

    // =========================================================================
    // 2. Bias ROM Loader
    // =========================================================================
    bias_rom_loader #(
        .TOTAL_BIASES   (236),
        .ADDR_WIDTH     (8),
        .DATA_WIDTH     (32)
    ) u_bias_rom (
        .clk               (clk),
        .rst               (rst),
        .bias_write_addr   (b_addr),
        .bias_write_data   (b_data),
        .bias_write_enable (b_en),
        .loading_done      (b_done)
    );

    // =========================================================================
    // 3. UART Image Loader (fixed v3)
    // =========================================================================
    uart_image_loader #(
        .CLK_FREQ        (100_000_000),
        .BAUD_RATE       (  1_000_000),
        .IMAGE_PIXELS    (784),
        .ADDR_WIDTH      (10),
        .DATA_WIDTH      (8),
        .TIMEOUT_CYCLES  (10_000_000)
    ) u_uart (
        .clk                  (clk),
        .rst                  (compute_rst),
        .uart_rx              (uart_rx),
        .uart_tx              (uart_tx),
        .ready                (npu_ready),
        .ext_wr_en            (i_en),
        .ext_wr_addr          (i_addr),
        .ext_wr_data          (i_data),
        .image_loaded         (image_loaded),
        .npu_error            (npu_error),
        .result_valid_in      (result_valid_lat),
        .predicted_digit_in   (digit_raw)
    );

    // =========================================================================
    // 4. LeNet-5 NPU core
    // =========================================================================
    cnn_top u_cnn (
        .clk                  (clk),
        .rst                  (compute_rst),
        .start                (image_loaded),

        .weight_write_addr    (w_addr),
        .weight_write_data    (w_data),
        .weight_write_enable  (w_en),

        .bias_write_addr      (b_addr),
        .bias_write_data      (b_data),
        .bias_write_enable    (b_en),

        .ext_wr_en            (i_en),
        .ext_wr_addr          (i_addr),
        .ext_wr_data          (i_data),

        .predicted_digit      (digit_raw),
        .result_valid         (result_valid_pulse),
        .inference_done       (inference_done),
        .current_layer        (current_layer),
        .sram_bank_conflict   (sram_bank_conflict)
    );

    assign predicted_digit = digit_raw;

endmodule
