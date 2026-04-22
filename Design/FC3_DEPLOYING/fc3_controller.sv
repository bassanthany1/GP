// =============================================================================
// fc3_controller.sv
//
// Tiny 4-state FSM that replaces the full cnn_controller.
// Waits 2 cycles after reset then fires start_layer once.
// Waits for layer_done then asserts done_led forever.
//
// All layer config signals are hardwired constants - no ROM needed.
// =============================================================================

module fc3_controller (
    input  logic clk,
    input  logic rst,
    input  logic layer_done,         // from lenet5_npu_complete

    output logic start_layer,        // to lenet5_npu_complete
    output logic done_led            // lights up when inference is complete
);
    typedef enum logic [1:0] {
        S_IDLE  = 2'd0,
        S_START = 2'd1,
        S_WAIT  = 2'd2,
        S_DONE  = 2'd3
    } state_t;

    state_t state;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= S_IDLE;
            start_layer <= 1'b0;
            done_led    <= 1'b0;
        end else begin
            start_layer <= 1'b0;   // default: deasserted

            case (state)
                // Wait 1 cycle after reset to let everything settle
                S_IDLE: begin
                    state <= S_START;
                end

                // Fire start_layer for exactly 1 clock cycle
                S_START: begin
                    start_layer <= 1'b1;
                    state       <= S_WAIT;
                end

                // Wait for layer_done from npu_complete
                S_WAIT: begin
                    if (layer_done)
                        state <= S_DONE;
                end

                // Inference finished - light LED, stay here forever
                S_DONE: begin
                    done_led <= 1'b1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
