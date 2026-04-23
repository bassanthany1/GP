// ============================================================================
// Weight SRAM for LeNet-5 CNN Accelerator (FIXED - NBA race removed)
// ============================================================================

module weight_sram_lenet5_actual #(
    parameter DATA_WIDTH        = 8,
    parameter MAX_BURST_LEN     = 512,
    parameter MAX_WEIGHTS       = 30720,
    parameter TOTAL_WEIGHTS     = 44190
)(
    input  logic clk,
    input  logic rst,

    // Configuration
    input  logic [$clog2(TOTAL_WEIGHTS+1)-1:0] layer_offset,

    // Write port
    input  logic [$clog2(TOTAL_WEIGHTS)-1:0]   write_addr,
    input  logic signed [DATA_WIDTH-1:0]       write_data,
    input  logic                              write_enable,

    // Read port (burst)
    input  logic [$clog2(MAX_WEIGHTS)-1:0]     read_addr,
    input  logic [$clog2(MAX_BURST_LEN+1)-1:0] burst_length,
    input  logic                              read_request,
    output logic signed [DATA_WIDTH-1:0]       read_data,
    output logic                              read_valid,
    output logic                              burst_complete
);

    // =========================================================================
    // Memory
    // =========================================================================

    localparam BRAM_DEPTH = 65536;
    localparam ADDR_WIDTH = $clog2(BRAM_DEPTH);

    (* ram_style = "block" *)
    logic signed [DATA_WIDTH-1:0] weight_bram [BRAM_DEPTH];

    // =========================================================================
    // Internal Signals
    // =========================================================================

    logic [ADDR_WIDTH-1:0] bram_addr;
    logic [ADDR_WIDTH-1:0] absolute_read_addr;

    logic [ADDR_WIDTH-1:0] current_read_addr;

    logic [$clog2(MAX_BURST_LEN+1)-1:0] burst_counter;
    logic [$clog2(MAX_BURST_LEN+1)-1:0] burst_target;

    logic burst_active;
    logic [1:0] valid_pipe;
    logic burst_complete_reg;

    // FSM
    typedef enum logic [1:0] {
        S_IDLE  = 2'd0,
        S_LATCH = 2'd1,
        S_BURST = 2'd2
    } state_t;

    state_t state;

    // =========================================================================
    // Address Calculation
    // =========================================================================

    always_comb begin
        absolute_read_addr = layer_offset + read_addr;
    end

    // BRAM address mux
    always_comb begin
        if (write_enable) begin
            bram_addr = write_addr;
        end else begin
            bram_addr = current_read_addr;
        end
    end

    // =========================================================================
    // BRAM Access (SYNC READ)
    // =========================================================================

    always_ff @(posedge clk) begin
        if (write_enable) begin
            weight_bram[bram_addr] <= write_data;
        end
        read_data <= weight_bram[bram_addr];
    end

    // =========================================================================
    // Burst FSM (FIXED)
    // =========================================================================

    always_ff @(posedge clk) begin
        if (rst) begin
            state              <= S_IDLE;
            burst_active       <= 1'b0;
            burst_counter      <= '0;
            burst_target       <= '0;
            current_read_addr  <= '0;
            valid_pipe         <= 2'b00;
            burst_complete_reg <= 1'b0;
        end else begin

            // Default pipeline behavior
            valid_pipe         <= {valid_pipe[0], 1'b0};
            burst_complete_reg <= 1'b0;

            case (state)

                // =============================================================
                S_IDLE: begin
                    if (read_request && !write_enable) begin
                        current_read_addr <= absolute_read_addr; // NBA
                        burst_target      <= burst_length;
                        burst_counter     <= 1;
                        burst_active      <= 1'b1;
                        state             <= S_LATCH; // ? FIX
                    end
                end

                // =============================================================
                S_LATCH: begin
                    // Wait 1 cycle for address to settle
                    valid_pipe[0] <= 1'b1;
                    state         <= S_BURST;
                end

                // =============================================================
                S_BURST: begin
                    if (burst_counter < burst_target) begin
                        current_read_addr <= current_read_addr + 1;
                        burst_counter     <= burst_counter + 1;
                        valid_pipe[0]     <= 1'b1;
                    end else begin
                        valid_pipe[0] <= 1'b0;
                        burst_active  <= 1'b0;
                        state         <= S_IDLE;
                    end

                    // Burst complete pulse
                    if (!burst_active && burst_counter == burst_target &&
                        valid_pipe[1] && !valid_pipe[0]) begin
                        burst_complete_reg <= 1'b1;
                        burst_counter      <= '0;
                    end
                end

            endcase

            // Write overrides read FSM
            if (write_enable) begin
                state         <= S_IDLE;
                burst_active  <= 1'b0;
                valid_pipe    <= 2'b00;
                burst_counter <= '0;
            end
        end
    end

    // =========================================================================
    // Outputs
    // =========================================================================

    assign read_valid     = valid_pipe[1];
    assign burst_complete = burst_complete_reg;

endmodule
