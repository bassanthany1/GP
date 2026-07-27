// =============================================================================
// fc2_output_rom.sv
//
// Stores the 84 INT8 activations from FC2 (the input to FC3).
// Single-port version: plain scalar ports, no unpacked arrays.
// 1-cycle read latency to match feature_map_sram_5port behaviour.
//
// File needed: fc2_golden_reference.mem (84 lines, 2-digit hex each)
// =============================================================================

module fc2_output_rom #(
    parameter DATA_WIDTH = 8
)(
    input  logic                          clk,

    // Single read port
    input  logic [9:0]                    sram_addr,
    input  logic                          sram_read_req,
    output logic signed [DATA_WIDTH-1:0]  sram_data,
    output logic                          sram_valid
);
    // 84 entries; declare 128 so out-of-range addresses safely return 0
    logic signed [DATA_WIDTH-1:0] mem [0:127];

    initial begin
        for (int i = 0; i < 128; i++) mem[i] = '0;
        //$readmemh("D:/GP/ALL_FLOW_FILES/f3_layer_files/fc2_golden_reference_un.mem", mem, 0, 63);
		  $readmemh("E:/GP_Proto/fc2_golden_reference.mem", mem, 0, 83);
    end

    // 1-cycle latency
    always_ff @(posedge clk) begin
        sram_valid <= sram_read_req;
        if (sram_read_req)
            sram_data <= mem[sram_addr];
        else
            sram_data <= '0;
    end

endmodule
