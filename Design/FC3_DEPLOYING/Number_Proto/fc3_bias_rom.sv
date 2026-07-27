// =============================================================================
// fc3_bias_rom.sv
//
// Replaces bias_sram_lenet5 for this prototype.
// Stores 10 INT32 bias values for FC3 (one per output class).
// Presents the exact same burst-read interface that
// bias_add_relu_streaming expects.
//
// File needed: fc3_biases.mem  (10 lines, 8-digit hex each = 32-bit values)
//
// Burst behaviour: identical to fc3_weight_rom
// =============================================================================

module fc3_bias_rom #(
    parameter NUM_BIASES = 10,
    parameter MAX_BURST  = 16
)(
    input  logic clk,
    input  logic rst,

    // Burst read interface (matches bias_sram_lenet5)
    input  logic [$clog2(NUM_BIASES)-1:0]   read_addr,
    input  logic [$clog2(MAX_BURST+1)-1:0]  burst_length,
    input  logic                             read_request,
    output logic signed [31:0]               read_data,
    output logic                             read_valid,
    output logic                             burst_complete
);
    logic signed [31:0] rom [0:NUM_BIASES-1];

    initial begin
        for (int i = 0; i < NUM_BIASES; i++) rom[i] = '0;
        //$readmemh("D:/GP/ALL_FLOW_FILES/f3_layer_files/biases_malaria.mem", rom, 0, NUM_BIASES-1);
		  $readmemh("E:/GP_Proto/fc3_biases.mem", rom, 0, NUM_BIASES-1);
    end

    // Burst state
    logic                           active;
    logic [$clog2(NUM_BIASES)-1:0]  base_addr;
    logic [$clog2(MAX_BURST+1)-1:0] cnt;
    logic [$clog2(MAX_BURST+1)-1:0] target;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            active         <= 1'b0;
            base_addr      <= '0;
            cnt            <= '0;
            target         <= '0;
            read_data      <= '0;
            read_valid     <= 1'b0;
            burst_complete <= 1'b0;
        end else begin
            read_valid     <= 1'b0;
            burst_complete <= 1'b0;

            if (read_request && !active) begin
                base_addr <= read_addr;
                target    <= burst_length;
                cnt       <= '0;
                active    <= 1'b1;
            end else if (active) begin
                read_data  <= rom[base_addr + cnt];
                read_valid <= 1'b1;
                if (cnt == target - 1) begin
                    active         <= 1'b0;
                    burst_complete <= 1'b1;
                end else begin
                    cnt <= cnt + 1;
                end
            end
        end
    end

endmodule
