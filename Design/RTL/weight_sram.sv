// ============================================================================
// Weight SRAM for LeNet-5 CNN Accelerator (Fixed Burst Controller)
// - Matches provided weight file dimensions
// - dense3 is 120×256 instead of standard 120×400
// - FIXED: Proper burst_complete timing after pipeline drainage
// ============================================================================

module weight_sram_lenet5_actual #(
    parameter DATA_WIDTH        = 8,
    parameter MAX_BURST_LEN     = 512,
    
    // Actual dimensions from provided weight files:
    // - conv2: [6, 5, 5, 1] = 150 weights
    // - conv1: [16, 5, 5, 6] = 2,400 weights  
    // - dense3 (FC1): [120, 256] = 30,720 weights
    // - dense2 (FC2): [84, 120] = 10,080 weights
    // - dense1 (FC3): [10, 84] = 840 weights
    // Total: 44,190 weights
    
    parameter MAX_WEIGHTS       = 30720,  // dense3 is largest
    parameter TOTAL_WEIGHTS     = 44190   // Total for all layers
)(
    input  logic clk,
    input  logic rst,
    
    // ========================================
    // Configuration (set per layer)
    // ========================================
    input  logic [$clog2(TOTAL_WEIGHTS+1)-1:0] layer_offset,
    input  logic [$clog2(MAX_WEIGHTS+1)-1:0]   layer_total_weights,
    
    // ========================================
    // WRITE PORT (Initialization)
    // ========================================
    input  logic [$clog2(TOTAL_WEIGHTS)-1:0] write_addr,
    input  logic signed [DATA_WIDTH-1:0] write_data,
    input  logic write_enable,
    
    // ========================================
    // READ PORT (Burst Interface)
    // ========================================
    input  logic [$clog2(MAX_WEIGHTS)-1:0] read_addr,
    input  logic [$clog2(MAX_BURST_LEN+1)-1:0] burst_length,
    input  logic read_request,
    output logic signed [DATA_WIDTH-1:0] read_data,
    output logic read_valid,
    output logic burst_complete
);

    // ========================================
    // BRAM Sizing
    // ========================================
    localparam BRAM_DEPTH = 65536;  // 64K depth (power of 2)
    localparam ADDR_WIDTH = $clog2(BRAM_DEPTH);
    
    // Synthesis attributes for BRAM inference
    (* ram_style = "block" *)
    (* ramstyle = "M20K" *)
    (* syn_ramstyle = "block_ram" *)
    logic signed [DATA_WIDTH-1:0] weight_bram [BRAM_DEPTH];
    
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
            weight_bram[bram_addr] <= write_data;
        end
        // Read happens every cycle when enabled
        read_data <= weight_bram[bram_addr];
    end
    
    // ========================================
    // Burst Read Controller (FIXED VERSION)
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
// Configuration Package for Actual Weight Files
// ============================================================================
package lenet5_actual_config_pkg;
    
    typedef struct packed {
        int conv2_offset;     // 0       (weights_conv2_int8.mem)
        int conv1_offset;     // 150     (weights_conv1_int8.mem)
        int dense3_offset;    // 2,550   (weights_dense3_int8.mem - FC1)
        int dense2_offset;    // 33,270  (weights_dense2_int8.mem - FC2)
        int dense1_offset;    // 43,350  (weights_dense1_int8.mem - FC3)
    } layer_offsets_t;
    
    typedef struct packed {
        int conv2_weights;    // 150
        int conv1_weights;    // 2,400
        int dense3_weights;   // 30,720 (FC1 with 256 input instead of 400)
        int dense2_weights;   // 10,080
        int dense1_weights;   // 840
    } layer_weights_t;
    
    typedef struct packed {
        int kernel_size;
        int in_channels;
        int out_channels;
    } layer_dims_t;
    
    localparam layer_offsets_t ACTUAL_OFFSETS = '{
        conv2_offset: 0,
        conv1_offset: 150,
        dense3_offset: 2550,
        dense2_offset: 33270,
        dense1_offset: 43350
    };
    
    localparam layer_weights_t ACTUAL_WEIGHTS = '{
        conv2_weights: 150,
        conv1_weights: 2400,
        dense3_weights: 30720,
        dense2_weights: 10080,
        dense1_weights: 840
    };
    
    localparam layer_dims_t CONV2_DIMS = '{kernel_size: 5, in_channels: 1, out_channels: 6};
    localparam layer_dims_t CONV1_DIMS = '{kernel_size: 5, in_channels: 6, out_channels: 16};
    localparam layer_dims_t DENSE3_DIMS = '{kernel_size: 1, in_channels: 256, out_channels: 120};
    localparam layer_dims_t DENSE2_DIMS = '{kernel_size: 1, in_channels: 120, out_channels: 84};
    localparam layer_dims_t DENSE1_DIMS = '{kernel_size: 1, in_channels: 84, out_channels: 10};
    
endpackage
