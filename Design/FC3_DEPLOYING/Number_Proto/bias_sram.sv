// ============================================================================
// Bias SRAM for LeNet-5 CNN Accelerator
// - Stores bias values for all layers
// - Much smaller than weight memory (only 236 total biases)
// - Single-port BRAM with burst read support
// ============================================================================
// bias_sram_lenet5 - FIXED
// Warnings fixed:
//   [Synth 8-3331] design bias_sram_lenet5 has unconnected port
//                  layer_total_biases[6:0]
//
// Root cause and fix: identical pattern to weight_sram_lenet5_actual.
//   layer_total_biases was declared as an input but never read internally.
// Fix: use it as an address upper-bound guard, making the port live.
//   No change to existing burst behaviour for valid accesses.
/*module bias_sram_lenet5 #(
    parameter DATA_WIDTH    = 32,
    parameter MAX_BURST_LEN = 16,
    parameter MAX_BIASES    = 120,
    parameter TOTAL_BIASES  = 236
)(
    input  logic clk,
    input  logic rst,

    // Configuration (set per layer)
    input  logic [$clog2(TOTAL_BIASES+1)-1:0] layer_offset,
    // NOTE: layer_total_biases REMOVED ? was never read internally.

    // Write port (initialization)
    input  logic [$clog2(TOTAL_BIASES)-1:0]    write_addr,
    input  logic signed [DATA_WIDTH-1:0]        write_data,
    input  logic                                write_enable,

    // Read port (burst interface)
    input  logic [$clog2(MAX_BIASES)-1:0]       read_addr,
    input  logic [$clog2(MAX_BURST_LEN+1)-1:0]  burst_length,
    input  logic                                read_request,
    output logic signed [DATA_WIDTH-1:0]        read_data,
    output logic                                read_valid,
    output logic                                burst_complete
);

    localparam BRAM_DEPTH = 256;
    localparam ADDR_WIDTH = $clog2(BRAM_DEPTH);

    (* ram_style = "block" *)
    (* ramstyle = "M20K" *)
    (* syn_ramstyle = "block_ram" *)
    logic signed [DATA_WIDTH-1:0] bias_bram [BRAM_DEPTH];

    logic [ADDR_WIDTH-1:0]                  bram_addr;
    logic [ADDR_WIDTH-1:0]                  absolute_read_addr;
    logic                                   bram_write_en;
    logic                                   bram_read_en;

    logic [ADDR_WIDTH-1:0]                  current_read_addr;
    logic [$clog2(MAX_BURST_LEN+1)-1:0]     burst_counter;
    logic [$clog2(MAX_BURST_LEN+1)-1:0]     burst_target;
    logic                                   burst_active;
    logic [1:0]                             valid_pipe;
    logic                                   burst_complete_reg;

    always_comb begin
        absolute_read_addr = layer_offset + read_addr;
    end

    always_comb begin
        if (write_enable) begin
            bram_addr    = write_addr;
            bram_write_en = 1'b1;
            bram_read_en  = 1'b0;
        end else begin
            bram_addr    = current_read_addr;
            bram_write_en = 1'b0;
            bram_read_en  = burst_active || read_request;
        end
    end

    always_ff @(posedge clk) begin
        if (bram_write_en)
            bias_bram[bram_addr] <= write_data;
        read_data <= bias_bram[bram_addr];
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            burst_active       <= 1'b0;
            burst_counter      <= '0;
            burst_target       <= '0;
            current_read_addr  <= '0;
            valid_pipe         <= 2'b00;
            burst_complete_reg <= 1'b0;
        end else begin
            valid_pipe         <= {valid_pipe[0], 1'b0};
            burst_complete_reg <= 1'b0;

            if (!write_enable) begin
                if (read_request && !burst_active) begin
                    current_read_addr <= absolute_read_addr;
                    burst_target      <= burst_length;
                    burst_counter     <= 1;
                    burst_active      <= 1'b1;
                    valid_pipe[0]     <= 1'b1;
                end else if (burst_active) begin
                    if (burst_counter < burst_target) begin
                        current_read_addr <= current_read_addr + 1;
                        burst_counter     <= burst_counter + 1;
                        valid_pipe[0]     <= 1'b1;
                    end else begin
                        valid_pipe[0] <= 1'b0;
                        burst_active  <= 1'b0;
                    end
                end

                if (!burst_active && burst_counter == burst_target &&
                    valid_pipe[1] && !valid_pipe[0]) begin
                    burst_complete_reg <= 1'b1;
                    burst_counter      <= '0;
                end
            end else begin
                burst_active  <= 1'b0;
                valid_pipe    <= 2'b00;
                burst_counter <= '0;
            end
        end
    end

    assign read_valid    = valid_pipe[1];
    assign burst_complete = burst_complete_reg;

endmodule*/
// ============================================================================
// Weight SRAM for LeNet-5 CNN Accelerator
// FIXED: Removed unused port layer_total_weights (caused Synth 8-3331 warnings)
// ==========================================================================

// ============================================================================
// Bias SRAM for LeNet-5 CNN Accelerator
// FIXED: Removed unused port layer_total_biases (caused Synth 8-3331 warnings)
// ============================================================================

module bias_sram_lenet5 #(
    parameter DATA_WIDTH    = 32,
    parameter MAX_BURST_LEN = 16,
    parameter MAX_BIASES    = 120,
    parameter TOTAL_BIASES  = 236
)(
    input  logic clk,
    input  logic rst,

    // Configuration (set per layer)
    input  logic [$clog2(TOTAL_BIASES+1)-1:0] layer_offset,
    // NOTE: layer_total_biases REMOVED ? was never read internally.

    // Write port (initialization)
    input  logic [$clog2(TOTAL_BIASES)-1:0]    write_addr,
    input  logic signed [DATA_WIDTH-1:0]        write_data,
    input  logic                                write_enable,

    // Read port (burst interface)
    input  logic [$clog2(MAX_BIASES)-1:0]       read_addr,
    input  logic [$clog2(MAX_BURST_LEN+1)-1:0]  burst_length,
    input  logic                                read_request,
    output logic signed [DATA_WIDTH-1:0]        read_data,
    output logic                                read_valid,
    output logic                                burst_complete
);

    localparam BRAM_DEPTH = 256;
    localparam ADDR_WIDTH = $clog2(BRAM_DEPTH);

    (* ram_style = "block" *)
    (* ramstyle = "M20K" *)
    (* syn_ramstyle = "block_ram" *)
    logic signed [DATA_WIDTH-1:0] bias_bram [BRAM_DEPTH];

    logic [ADDR_WIDTH-1:0]                  bram_addr;
    logic [ADDR_WIDTH-1:0]                  absolute_read_addr;
    logic                                   bram_write_en;
    logic                                   bram_read_en;

    logic [ADDR_WIDTH-1:0]                  current_read_addr;
    logic [$clog2(MAX_BURST_LEN+1)-1:0]     burst_counter;
    logic [$clog2(MAX_BURST_LEN+1)-1:0]     burst_target;
    logic                                   burst_active;
    logic [1:0]                             valid_pipe;
    logic                                   burst_complete_reg;

    always_comb begin
        absolute_read_addr = layer_offset + read_addr;
    end

    always_comb begin
        if (write_enable) begin
            bram_addr    = write_addr;
            bram_write_en = 1'b1;
            bram_read_en  = 1'b0;
        end else begin
            bram_addr    = current_read_addr;
            bram_write_en = 1'b0;
            bram_read_en  = burst_active || read_request;
        end
    end

    always_ff @(posedge clk) begin
        if (bram_write_en)
            bias_bram[bram_addr] <= write_data;
        read_data <= bias_bram[bram_addr];
    end

    always_ff @(posedge clk ) begin
        if (rst) begin
            burst_active       <= 1'b0;
            burst_counter      <= '0;
            burst_target       <= '0;
            current_read_addr  <= '0;
            valid_pipe         <= 2'b00;
            burst_complete_reg <= 1'b0;
        end else begin
            valid_pipe         <= {valid_pipe[0], 1'b0};
            burst_complete_reg <= 1'b0;

            if (!write_enable) begin
                if (read_request && !burst_active) begin
                    current_read_addr <= absolute_read_addr;
                    burst_target      <= burst_length;
                    burst_counter     <= 1;
                    burst_active      <= 1'b1;
                    valid_pipe[0]     <= 1'b1;
                end else if (burst_active) begin
                    if (burst_counter < burst_target) begin
                        current_read_addr <= current_read_addr + 1;
                        burst_counter     <= burst_counter + 1;
                        valid_pipe[0]     <= 1'b1;
                    end else begin
                        valid_pipe[0] <= 1'b0;
                        burst_active  <= 1'b0;
                    end
                end

                if (!burst_active && burst_counter == burst_target &&
                    valid_pipe[1] && !valid_pipe[0]) begin
                    burst_complete_reg <= 1'b1;
                    burst_counter      <= '0;
                end
            end else begin
                burst_active  <= 1'b0;
                valid_pipe    <= 2'b00;
                burst_counter <= '0;
            end
        end
    end

    assign read_valid    = valid_pipe[1];
    assign burst_complete = burst_complete_reg;

endmodule