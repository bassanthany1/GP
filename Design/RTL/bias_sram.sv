// ============================================================================
// Bias SRAM for LeNet-5 CNN Accelerator
// - Stores bias values for all layers
// - Much smaller than weight memory (only 236 total biases)
// - Single-port BRAM with burst read support
// ============================================================================

module bias_sram_lenet5 #(
    parameter DATA_WIDTH        = 32,      // Biases typically 32-bit for accumulation
    parameter MAX_BURST_LEN     = 16,      // Smaller bursts for biases
    
    // Bias counts for each layer:
    // - conv2: 6 biases (one per output channel)
    // - conv1: 16 biases
    // - dense3 (FC1): 120 biases
    // - dense2 (FC2): 84 biases
    // - dense1 (FC3): 10 biases
    // Total: 236 biases
    
    parameter MAX_BIASES        = 120,     // dense3 is largest
    parameter TOTAL_BIASES      = 236      // Total for all layers
)(
    input  logic clk,
    input  logic rst,
    
    // ========================================
    // Configuration (set per layer)
    // ========================================
    input  logic [$clog2(TOTAL_BIASES+1)-1:0] layer_offset,
    input  logic [$clog2(MAX_BIASES+1)-1:0]   layer_total_biases,
    
    // ========================================
    // WRITE PORT (Initialization)
    // ========================================
    input  logic [$clog2(TOTAL_BIASES)-1:0] write_addr,
    input  logic signed [DATA_WIDTH-1:0] write_data,
    input  logic write_enable,
    
    // ========================================
    // READ PORT (Burst Interface)
    // ========================================
    input  logic [$clog2(MAX_BIASES)-1:0] read_addr,
    input  logic [$clog2(MAX_BURST_LEN+1)-1:0] burst_length,
    input  logic read_request,
    output logic signed [DATA_WIDTH-1:0] read_data,
    output logic read_valid,
    output logic burst_complete
);

    // ========================================
    // BRAM Sizing
    // ========================================
    localparam BRAM_DEPTH = 256;  // Small depth, power of 2
    localparam ADDR_WIDTH = $clog2(BRAM_DEPTH);
    
    // Synthesis attributes for BRAM inference
    (* ram_style = "block" *)
    (* ramstyle = "M20K" *)
    (* syn_ramstyle = "block_ram" *)
    logic signed [DATA_WIDTH-1:0] bias_bram [BRAM_DEPTH];
    
    // ========================================
    // Control Logic
    // ========================================
    logic [ADDR_WIDTH-1:0] bram_addr;
    logic [ADDR_WIDTH-1:0] absolute_read_addr;
    logic bram_write_en;
    logic bram_read_en;
    
    // Burst control
    logic [ADDR_WIDTH-1:0] current_read_addr;
    logic [$clog2(MAX_BURST_LEN+1)-1:0] burst_counter;
    logic [$clog2(MAX_BURST_LEN+1)-1:0] burst_target;
    logic burst_active;
    
    // Pipeline for BRAM read latency
    logic [1:0] valid_pipe;
    logic burst_complete_reg;
    
    // ========================================
    // Address Calculation
    // ========================================
    always_comb begin
        absolute_read_addr = layer_offset + read_addr;
    end
    
    // ========================================
    // Address Muxing (Write vs Read)
    // ========================================
    always_comb begin
        if (write_enable) begin
            bram_addr = write_addr;
            bram_write_en = 1'b1;
            bram_read_en = 1'b0;
        end else begin
            bram_addr = current_read_addr;
            bram_write_en = 1'b0;
            bram_read_en = burst_active || read_request;
        end
    end
    
    // ========================================
    // BRAM Access (Single Port)
    // ========================================
    always_ff @(posedge clk) begin
        if (bram_write_en) begin
            bias_bram[bram_addr] <= write_data;
        end
        // Read happens every cycle when enabled
        read_data <= bias_bram[bram_addr];
    end
    
    // ========================================
    // Burst Read Controller
    // ========================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            burst_active <= 1'b0;
            burst_counter <= '0;
            burst_target <= '0;
            current_read_addr <= '0;
            valid_pipe <= 2'b00;
            burst_complete_reg <= 1'b0;
        end else begin
            // Shift valid pipeline
            valid_pipe <= {valid_pipe[0], 1'b0};
            burst_complete_reg <= 1'b0;
            
            if (!write_enable) begin
                if (read_request && !burst_active) begin
                    // ========================================
                    // Start New Burst
                    // ========================================
                    current_read_addr <= absolute_read_addr;
                    burst_target <= burst_length;
                    burst_counter <= 1;
                    burst_active <= 1'b1;
                    valid_pipe[0] <= 1'b1;
                    
                end else if (burst_active) begin
                    // ========================================
                    // Continue Burst
                    // ========================================
                    if (burst_counter < burst_target) begin
                        current_read_addr <= current_read_addr + 1;
                        burst_counter <= burst_counter + 1;
                        valid_pipe[0] <= 1'b1;
                    end else begin
                        // All addresses issued, wait for pipeline to drain
                        valid_pipe[0] <= 1'b0;
                        burst_active <= 1'b0;
                    end
                end
                
                // Assert burst_complete after last valid data exits pipeline
                if (!burst_active && burst_counter == burst_target && 
                    valid_pipe[1] && !valid_pipe[0]) begin
                    burst_complete_reg <= 1'b1;
                    burst_counter <= '0;
                end
            end else begin
                // In write mode: disable burst logic
                burst_active <= 1'b0;
                valid_pipe <= 2'b00;
                burst_counter <= '0;
            end
        end
    end
    
    // ========================================
    // Outputs
    // ========================================
    assign read_valid = valid_pipe[1];
    assign burst_complete = burst_complete_reg;
    
endmodule
           

// ============================================================================
// Bias Configuration Package for LeNet-5
// ============================================================================
package lenet5_bias_config_pkg;
    
    // Bias offsets in memory
    typedef struct packed {
        int conv2_offset;     // 0
        int conv1_offset;     // 6
        int dense3_offset;    // 22  (FC1)
        int dense2_offset;    // 142 (FC2)
        int dense1_offset;    // 226 (FC3)
    } bias_offsets_t;
    
    // Bias counts per layer
    typedef struct packed {
        int conv2_biases;     // 6
        int conv1_biases;     // 16
        int dense3_biases;    // 120
        int dense2_biases;    // 84
        int dense1_biases;    // 10
    } bias_counts_t;
    
    // Constants
    localparam bias_offsets_t BIAS_OFFSETS = '{
        conv2_offset: 0,
        conv1_offset: 6,
        dense3_offset: 22,
        dense2_offset: 142,
        dense1_offset: 226
    };
    
    localparam bias_counts_t BIAS_COUNTS = '{
        conv2_biases: 6,
        conv1_biases: 16,
        dense3_biases: 120,
        dense2_biases: 84,
        dense1_biases: 10
    };
    
    // Total biases
    localparam int TOTAL_BIASES = 236;
    
endpackage
