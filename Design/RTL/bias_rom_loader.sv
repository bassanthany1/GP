// bias_rom_loader - FIXED v5 (final)
//
// History of fixes and why each previous version was still wrong:
//
// ORIGINAL BUG:
//   bias_write_enable cleared on same cycle as addr_cnt==TOTAL-1.
//   bias_bram[235] (FC3 class-9 bias) never written -> X in ModelSim,
//   0 in Vivado post-synth -> digit-9 vs digit-5 tool mismatch.
//
// v3 ATTEMPT (wrong):
//   (* keep = "true" *) on bias_write_data_kept broke Block RAM inference,
//   increased LUTs, decreased BRAM count, caused negative WNS.
//
// v4 ATTEMPT (wrong):
//   Two-block pipeline with addr_cnt_r. addr_cnt_r was not updated in DONE,
//   so the BRAM write block read addr_cnt_r=TOTAL-2 (stale) with enable=0
//   on the cycle it needed to write TOTAL-1. bias_bram[235] still X.
//
// v5 FIX (this version):
//   Adds a DRAIN state between LOADING and DONE. DRAIN holds write_enable=1
//   and addr_cnt_r=TOTAL-1 for exactly one cycle so the BRAM write-port
//   pipeline stage can commit the last entry with enable=1. DONE then
//   deasserts write_enable cleanly.
//
//   Cycle timeline for last write:
//     Cycle T   (LOADING): addr_cnt=235, addr_cnt_r<=235, enable<=1 -> DRAIN
//     Cycle T+1 (DRAIN)  : addr_cnt_r<=235 (held), enable<=1
//                          BRAM writes bias_bram[235]=rom[235] <- OK
//     Cycle T+2 (DONE)   : enable<=0  <- safe

module bias_rom_loader #(
    parameter TOTAL_BIASES = 236,
    parameter ADDR_WIDTH   = 8,
    parameter DATA_WIDTH   = 32
)(
    input  logic                    clk,
    input  logic                    rst,

    output logic [ADDR_WIDTH-1:0]   bias_write_addr,
    output logic [DATA_WIDTH-1:0]   bias_write_data,
    output logic                    bias_write_enable,

    output logic                    loading_done
);

    logic [DATA_WIDTH-1:0] rom [0:TOTAL_BIASES-1];

    initial begin
        $readmemh("all_biases_zp_fixed.mem", rom);
    end

    // Three-state FSM: LOADING -> DRAIN -> DONE
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
    // Drives BRAM input directly - always a live cone sink, never pruned.
    logic [ADDR_WIDTH-1:0] addr_cnt_r;

    // =========================================================================
    // FSM block
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            state             <= LOADING;
            addr_cnt          <= '0;
            addr_cnt_r        <= '0;
            bias_write_enable <= 1'b0;
            loading_done      <= 1'b0;
        end else begin
            case (state)

                LOADING: begin
                    addr_cnt_r        <= addr_cnt;   // capture before increment
                    bias_write_enable <= 1'b1;

                    if (addr_cnt == ADDR_WIDTH'(TOTAL_BIASES - 1)) begin
                        // addr_cnt_r=TOTAL-1 captured this cycle.
                        // DRAIN will hold write_enable=1 one more cycle so
                        // the BRAM write-port block commits addr_cnt_r=TOTAL-1.
                        state        <= DRAIN;
                        loading_done <= 1'b1;
                    end else begin
                        addr_cnt <= addr_cnt + 1'b1;
                    end
                end

                DRAIN: begin
                    // Keep write_enable=1 and addr_cnt_r steady for one cycle.
                    // BRAM write-port block commits bias_bram[TOTAL-1] here.
                    bias_write_enable <= 1'b1;
                    addr_cnt_r        <= addr_cnt_r; // hold steady
                    state             <= DONE;
                end

                DONE: begin
                    // Last write committed. Safe to deassert.
                    bias_write_enable <= 1'b0;
                    loading_done      <= 1'b1;
                end

                default: state <= DONE;

            endcase
        end
    end

    // =========================================================================
    // BRAM write-port pipeline stage
    // (* dont_touch = "true" *) prevents early-pass elimination without
    // breaking Block RAM inference, adding LUTs, or affecting timing.
    // =========================================================================
    (* dont_touch = "true" *)
    always_ff @(posedge clk) begin
        if (rst) begin
            bias_write_addr <= '0;
            bias_write_data <= '0;
        end else begin
            bias_write_addr <= addr_cnt_r;
            bias_write_data <= rom[addr_cnt_r];
        end
    end

endmodule
