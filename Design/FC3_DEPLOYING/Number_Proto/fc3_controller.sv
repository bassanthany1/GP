module fc3_controller (
    input  logic clk,
    input  logic rst,
    input  logic start_btn,          // NEW: debounced active-high pulse
    input  logic layer_done,

    output logic start_layer,
    output logic done_led
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
            start_layer <= 1'b0;

            case (state)
                // CHANGED: now waits for button press instead of auto-advancing
                S_IDLE: begin
                    if (start_btn)
                        state <= S_START;
                end

                S_START: begin
                    start_layer <= 1'b1;
                    state       <= S_WAIT;
                end

                S_WAIT: begin
                    if (layer_done)
                        state <= S_DONE;
                end

                S_DONE: begin
                    done_led <= 1'b1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule