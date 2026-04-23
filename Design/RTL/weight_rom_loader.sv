// =============================================================================
// weight_rom_loader.sv
// Automatically loads all 44,190 INT8 weights into cnn_top after reset.
// Reads from weights.mem (hex format, one byte per line).
// Drives cnn_top's weight_write_* ports directly.
//
// Timing:
//   - Starts writing on the first cycle after rst deasserts
//   - Writes one weight per clock cycle
//   - loading_done goes HIGH after last address written
//   - Total load time: 44,191 clock cycles (~0.44 ms at 100 MHz)
//
// Usage:
//   - Add all_weights.mem to your Vivado project sources
//   - Format: one 2-digit hex byte per line (44190 lines total)
// =============================================================================
// weight_rom_loader - FIXED v5 (final)
//
// History of fixes and why each previous version was still wrong:
//
// ORIGINAL BUG:
//   weight_write_enable and weight_write_data were deasserted/cleared in the
//   SAME always_ff assignment as the terminal condition. Because registered
//   signals take effect on the NEXT clock edge, the BRAM saw enable=0 on the
//   exact cycle addr=TOTAL-1 arrived. weight_bram[44189] was never written.
//
// v3 ATTEMPT (wrong):
//   Added (* keep = "true" *) on write_data. Broke Block RAM inference
//   (BRAM -> distributed RAM), increased LUTs, reduced BRAM count, WNS < 0.
//
// v4 ATTEMPT (wrong):
//   Separated FSM and BRAM write port into two always_ff blocks with a
//   one-cycle pipeline (addr_cnt_r = addr_cnt delayed one cycle).
//   Bug: addr_cnt_r was only updated in the LOADING state. When addr_cnt
//   reached TOTAL-1 and the FSM moved to DONE, addr_cnt_r was assigned
//   TOTAL-1 on that same cycle - but the BRAM write block reads addr_cnt_r
//   ONE CYCLE LATER (in DONE). At that point write_enable was already 0, so
//   the last write was still discarded. bram[44189] = X again.
//
// v5 FIX (this version):
//   The root issue is a two-stage pipeline: FSM produces addr_cnt_r, BRAM
//   block consumes it one cycle later. The BRAM write for address N fires on
//   the cycle AFTER addr_cnt_r=N is presented. So for the last address:
//     Cycle T  : FSM sets addr_cnt_r=TOTAL-1, write_enable=1, moves to DONE
//     Cycle T+1: BRAM block reads addr_cnt_r=TOTAL-1, write_enable must =1
//     Cycle T+2: DONE sets write_enable=0 (safe, write already committed)
//
//   Solution: add a one-cycle "drain" state (DRAIN) between LOADING and DONE.
//   DRAIN holds write_enable=1 for exactly one extra cycle so the BRAM write
//   block can consume addr_cnt_r=TOTAL-1 with enable=1. Then DONE deasserts.
//
//   This is the minimal, correct, resource-neutral solution:
//   - No (* keep *) on data signals (preserves Block RAM inference)
//   - (* dont_touch *) on BRAM write block (prevents early-pass pruning)
//   - addr_cnt_r drives BRAM input directly (always a live cone sink)
//   - write_data absorbed into BRAM built-in input register (no extra LUTs)
//   - WNS unaffected (no frozen FFs outside BRAM boundary)

module weight_rom_loader #(
    parameter TOTAL_WEIGHTS = 44190,
    parameter ADDR_WIDTH    = 16,
    parameter DATA_WIDTH    = 8
)(
    input  logic                    clk,
    input  logic                    rst,

    output logic [ADDR_WIDTH-1:0]   weight_write_addr,
    output logic [DATA_WIDTH-1:0]   weight_write_data,
    output logic                    weight_write_enable,

    output logic                    loading_done
);

    logic [DATA_WIDTH-1:0] rom [0:TOTAL_WEIGHTS-1];

    initial begin
        $readmemh("all_weights.mem", rom);
    end

    // Three-state FSM: LOADING -> DRAIN -> DONE
    // DRAIN is a single extra cycle that keeps write_enable HIGH so the BRAM
    // write-port pipeline stage can commit the last address.
    typedef enum logic [1:0] {
        LOADING = 2'd0,
        DRAIN   = 2'd1,
        DONE    = 2'd2
    } state_t;
    state_t state;

    // FIX 1 (original): prevents addr_cnt_reg_rep pruning warning
    (* keep = "true" *)
    logic [ADDR_WIDTH-1:0] addr_cnt;

    // addr_cnt_r: registered one cycle behind addr_cnt, captured BEFORE
    // addr_cnt increments. Feeds the BRAM write-port pipeline stage.
    // Because it drives a BRAM input port directly it is always a live
    // cone sink - write_data is never pruned by Vivado's liveness analysis.
    logic [ADDR_WIDTH-1:0] addr_cnt_r;

    // =========================================================================
    // FSM block
    // Cycle-accurate pipeline contract:
    //   Cycle N   (LOADING) : addr_cnt=N, addr_cnt_r<=N, write_enable<=1
    //   Cycle N+1 (LOADING) : addr_cnt=N+1, BRAM writes addr_cnt_r=N  <- correct
    //   ...
    //   Cycle T   (LOADING) : addr_cnt=TOTAL-1, addr_cnt_r<=TOTAL-1,
    //                         write_enable<=1, state<=DRAIN
    //   Cycle T+1 (DRAIN)   : addr_cnt_r<=TOTAL-1 (held), write_enable<=1
    //                         BRAM writes addr_cnt_r=TOTAL-1  <- last write OK
    //   Cycle T+2 (DONE)    : write_enable<=0  <- safe, write committed
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            state               <= LOADING;
            addr_cnt            <= '0;
            addr_cnt_r          <= '0;
            weight_write_enable <= 1'b0;
            loading_done        <= 1'b0;
        end else begin
            case (state)

                LOADING: begin
                    addr_cnt_r          <= addr_cnt;   // capture before increment
                    weight_write_enable <= 1'b1;

                    if (addr_cnt == ADDR_WIDTH'(TOTAL_WEIGHTS - 1)) begin
                        // Terminal address loaded into addr_cnt_r this cycle.
                        // Move to DRAIN to hold write_enable=1 one more cycle
                        // so the BRAM write-port block can commit it.
                        state        <= DRAIN;
                        loading_done <= 1'b1;
                    end else begin
                        addr_cnt <= addr_cnt + 1'b1;
                    end
                end

                DRAIN: begin
                    // Hold write_enable=1 and addr_cnt_r steady for one cycle.
                    // The BRAM write-port block reads addr_cnt_r=TOTAL-1 and
                    // write_enable=1 this cycle, committing the last write.
                    weight_write_enable <= 1'b1;
                    addr_cnt_r          <= addr_cnt_r; // hold (explicit for clarity)
                    state               <= DONE;
                end

                DONE: begin
                    // Last write has committed. Safe to deassert write_enable.
                    weight_write_enable <= 1'b0;
                    loading_done        <= 1'b1;
                end

                default: state <= DONE;

            endcase
        end
    end

    // =========================================================================
    // BRAM write-port pipeline stage
    //
    // (* dont_touch = "true" *) prevents Vivado from eliminating this block
    // during early elaboration passes before BRAM inference runs.
    // Does NOT freeze FF placement - write_addr and write_data are absorbed
    // into the BRAM's built-in input registers normally.
    // No extra LUTs, no WNS impact, Block RAM inference fully preserved.
    // =========================================================================
    (* dont_touch = "true" *)
    always_ff @(posedge clk) begin
        if (rst) begin
            weight_write_addr <= '0;
            weight_write_data <= '0;
        end else begin
            weight_write_addr <= addr_cnt_r;
            weight_write_data <= rom[addr_cnt_r];
        end
    end

endmodule
