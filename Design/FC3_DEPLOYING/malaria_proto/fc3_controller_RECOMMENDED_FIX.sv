// =============================================================================
// fc3_controller.sv  (RECOMMENDED FIX - NOT auto-applied)
//
// FINDING: the fc3_controller.sv reviewed in this project has NO exit
// transition out of S_DONE. Once one inference completes, `state` is stuck
// at S_DONE forever - a second start_btn pulse is silently ignored until
// the next power-on/hardware reset. This matches a bug already flagged and
// fixed in an earlier session, but that fix apparently lives in a
// differently-named file (fc3_controller_malaria.sv) that isn't among the
// files reviewed here - so the copy actually wired into proto_fc3_top.sv
// still has the original bug.
//
// This file restores the exit transition, allowing back-to-back inferences
// (new button press -> new classification) without a full board reset.
// It does NOT touch FC3 datapath/systolic/ROM/requantization logic - only
// the controller FSM's housekeeping.
//
// ONE CHANGE vs the version in the project:
//   S_DONE now returns to S_IDLE once start_btn is released and a new
//   press comes in, instead of latching forever. done_led is now cleared
//   when a new inference starts, so it correctly reflects only the most
//   recent result.
// =============================================================================

module fc3_controller (
    input  logic clk,
    input  logic rst,
    input  logic start_btn,          // debounced active-high pulse
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
                S_IDLE: begin
                    if (start_btn) begin
                        done_led <= 1'b0;   // FIX: clear stale result indicator
                        state    <= S_START;
                    end
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
                    // FIX: a fresh start_btn pulse while already in S_DONE
                    // kicks off a brand-new inference directly (instead of
                    // being silently ignored forever, as in the original).
                    if (start_btn) begin
                        done_led    <= 1'b0;
                        start_layer <= 1'b1;
                        state       <= S_WAIT;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
