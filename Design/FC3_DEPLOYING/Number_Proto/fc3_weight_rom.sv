// =============================================================================
// fc3_weight_rom.sv
//
// Replaces weight_sram_lenet5_actual for this prototype.
// Stores 840 INT8 weights for FC3 (84 inputs x 10 outputs).
// Presents the exact same burst-read interface that
// weight_flatten2_streaming_burst expects.
//
// File needed: fc3_weights.mem  (840 lines, 2-digit hex each)
//
// Burst behaviour:
//   - Assert read_request for 1 cycle with addr and burst_length
//   - ROM streams data with valid high each cycle
//   - burst_done pulses for 1 cycle after last word
// =============================================================================

module fc3_weight_rom #(
    parameter DATA_WIDTH  = 8,
    parameter MAX_WEIGHTS = 128,       // FC3 only: 84x10 .....128 for malar
    parameter MAX_BURST   = 256
)(
    input  logic clk,
    input  logic rst,

    // Burst read interface (matches weight_sram_lenet5_actual)
    input  logic [$clog2(MAX_WEIGHTS)-1:0]  read_addr,
    input  logic [$clog2(MAX_BURST+1)-1:0]  burst_length,
    input  logic                             read_request,
    output logic signed [DATA_WIDTH-1:0]     read_data,
    output logic                             read_valid,
    output logic                             burst_complete
);
    logic signed [DATA_WIDTH-1:0] rom [0:MAX_WEIGHTS-1];

    initial begin
        for (int i = 0; i < MAX_WEIGHTS; i++) rom[i] = '0;
       //$readmemh("D:/GP/ALL_FLOW_FILES/f3_layer_files/weights_malaria.mem", rom, 0, MAX_WEIGHTS-1);
		$readmemh("E:/GP_Proto/fc3_weights.mem", rom, 0, MAX_WEIGHTS-1);
    end

    // Burst state
    logic                            active;
    logic [$clog2(MAX_WEIGHTS)-1:0]  base_addr;
    logic [$clog2(MAX_BURST+1)-1:0]  cnt;
    logic [$clog2(MAX_BURST+1)-1:0]  target;

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
