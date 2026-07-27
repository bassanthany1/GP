// =============================================================================
// lcd_controller.sv
// HD44780 LCD driver  —  8-bit mode, hardware-verified timing
//
// Board  : EasyFPGA A2.2  (EP4CE6E22C8 @ 50 MHz, 1 cycle = 20 ns)
// RW pin : driven LOW by this module  (write-only, no busy-flag polling)
//
// ── HD44780 timing satisfied ─────────────────────────────────────────────────
//   Power-on delay  ≥ 15 ms     → 20 ms   (1 000 000 cycles @ 50 MHz)
//   Init step 1     ≥  4.1 ms   → 5 ms    (250 000 cycles)
//   Init step 2     ≥  100 µs   → 200 µs  ( 10 000 cycles)
//   tAS  RS setup   ≥  40 ns    → 100 ns  (5 cycles)
//   tPW  EN high    ≥ 450 ns    → 600 ns  (30 cycles)
//   tCYC EN cycle   ≥   1 µs    → 1.2 µs  (60 cycle total hi+lo)
//   t_exec (normal) ≥  37 µs    → 50 µs   (2 500 cycles)
//   t_exec (clear)  ≥ 1.52 ms   → 2 ms    (100 000 cycles)
// ─────────────────────────────────────────────────────────────────────────────
//
// Caller interface:
//   send_i  — assert for 1 cycle to request a write
//   rs_i    — 0 = command, 1 = data/character
//   data_i  — byte to write
//   busy_o  — HIGH while controller is busy (init or executing write)
//   done_o  — pulses HIGH for 1 cycle when write completes
// =============================================================================

module lcd_controller #(
    parameter int CLK_HZ = 50_000_000
)(
    input  logic       clk,
    input  logic       rst,       // synchronous, active-high

    input  logic       send_i,
    input  logic       rs_i,
    input  logic [7:0] data_i,
    output logic       busy_o,
    output logic       done_o,

    output logic       lcd_rs,
    output logic       lcd_rw,   // always 0
    output logic       lcd_en,
    output logic [7:0] lcd_data
);

    // ── Timing constants ─────────────────────────────────────────────────────
    localparam int T_PWRON = CLK_HZ / 50;           // 20 ms
    localparam int T_INI1  = CLK_HZ / 200;          //  5 ms
    localparam int T_INI2  = CLK_HZ / 5000;         // 200 µs
    localparam int T_RS    = 5;                      // 100 ns
    localparam int T_EHI   = 30;                     // 600 ns
    localparam int T_ELO   = 30;                     // 600 ns
    localparam int T_EXEC  = 2_500;                  //  50 µs
    localparam int T_CLR   = 100_000;                //   2 ms

    localparam int CW = $clog2(T_PWRON + 1);        // counter width

    // ── Init ROM  (9 steps) ───────────────────────────────────────────────────
    // Step 0: pure power-on delay, no EN pulse
    // Steps 1-8: send command byte + wait
    // ─────────────────────────────────────────────────────────────────────────
    localparam int NSTEPS = 9;
    typedef struct packed {
        logic [7:0]   cmd;
        logic         has_en;   // 1 = emit EN pulse, 0 = delay only
        logic         long_dly; // 1 = use T_CLR, 0 = step-specific delay
        int           dly;      // post-step delay (cycles)
    } init_step_t;

    // Cannot use struct array initialiser in all tools — use separate arrays
    logic [7:0] ic [0:NSTEPS-1];  // command byte
    logic       ie [0:NSTEPS-1];  // has_en
    int         id [0:NSTEPS-1];  // delay (cycles)

    initial begin
        ic[0]=8'h00; ie[0]=0; id[0]=T_PWRON;  // 20 ms power-on
        ic[1]=8'h30; ie[1]=1; id[1]=T_INI1;   //  5 ms  (0x30 #1)
        ic[2]=8'h30; ie[2]=1; id[2]=T_INI2;   // 200 µs (0x30 #2)
        ic[3]=8'h30; ie[3]=1; id[3]=T_EXEC;   //  50 µs (0x30 #3)
        ic[4]=8'h38; ie[4]=1; id[4]=T_EXEC;   // Function Set 8-bit,2L,5×8
        ic[5]=8'h08; ie[5]=1; id[5]=T_EXEC;   // Display OFF
        ic[6]=8'h01; ie[6]=1; id[6]=T_CLR;    // Clear (needs 2 ms)
        ic[7]=8'h06; ie[7]=1; id[7]=T_EXEC;   // Entry Mode: inc, no shift
        ic[8]=8'h0C; ie[8]=1; id[8]=T_EXEC;   // Display ON, cursor off
    end

    // ── FSM states ────────────────────────────────────────────────────────────
    typedef enum logic [3:0] {
        S_IDELAY,   // init: delay phase  (or pure delay step)
        S_IRS,      // init: RS/DATA setup before EN
        S_IEHI,     // init: EN high
        S_IELO,     // init: EN low gap
        S_IPOST,    // init: post-command execution delay
        S_IDLE,     // ready for user request
        S_URS,      // user: RS/DATA setup
        S_UEHI,     // user: EN high
        S_UELO,     // user: EN low
        S_UPOST     // user: post-command delay
    } st_t;

    st_t          state;
    logic [CW-1:0] cnt;
    logic [3:0]   sidx;          // init step index

    // Latched user request
    logic       u_rs;
    logic [7:0] u_data;
    logic       u_long;          // needs T_CLR post-delay

    assign lcd_rw = 1'b0;

    always_ff @(posedge clk) begin
        if (rst) begin
            state    <= S_IDELAY;
            cnt      <= '0;
            sidx     <= '0;
            busy_o   <= 1'b1;
            done_o   <= 1'b0;
            lcd_rs   <= 1'b0;
            lcd_en   <= 1'b0;
            lcd_data <= 8'h38;
            u_rs     <= 1'b0;
            u_data   <= 8'h00;
            u_long   <= 1'b0;
        end else begin
            done_o <= 1'b0;

            case (state)

                // ── Init delay ────────────────────────────────────────────────
                S_IDELAY: begin
                    busy_o <= 1'b1;
                    lcd_en <= 1'b0;
                    if (cnt == CW'(id[sidx] - 1)) begin
                        cnt <= '0;
                        if (ie[sidx]) begin
                            lcd_rs   <= 1'b0;
                            lcd_data <= ic[sidx];
                            state    <= S_IRS;
                        end else begin
                            sidx  <= sidx + 1;
                            state <= S_IDELAY;
                        end
                    end else cnt <= cnt + 1;
                end

                // ── Init RS setup ─────────────────────────────────────────────
                S_IRS: begin
                    if (cnt == CW'(T_RS - 1)) begin
                        cnt <= '0; state <= S_IEHI;
                    end else cnt <= cnt + 1;
                end

                // ── Init EN high ──────────────────────────────────────────────
                S_IEHI: begin
                    lcd_en <= 1'b1;
                    if (cnt == CW'(T_EHI - 1)) begin
                        cnt <= '0; state <= S_IELO;
                    end else cnt <= cnt + 1;
                end

                // ── Init EN low ───────────────────────────────────────────────
                S_IELO: begin
                    lcd_en <= 1'b0;
                    if (cnt == CW'(T_ELO - 1)) begin
                        cnt <= '0; state <= S_IPOST;
                    end else cnt <= cnt + 1;
                end

                // ── Init post-command delay ────────────────────────────────────
                S_IPOST: begin
                    if (cnt == CW'(id[sidx] - 1)) begin
                        cnt <= '0;
                        if (sidx == NSTEPS - 1) begin
                            state  <= S_IDLE;
                            busy_o <= 1'b0;
                        end else begin
                            sidx  <= sidx + 1;
                            state <= S_IDELAY;
                        end
                    end else cnt <= cnt + 1;
                end

                // ── IDLE ─────────────────────────────────────────────────────
                S_IDLE: begin
                    busy_o <= 1'b0;
                    lcd_en <= 1'b0;
                    if (send_i) begin
                        u_rs     <= rs_i;
                        u_data   <= data_i;
                        u_long   <= (!rs_i && (data_i == 8'h01 || data_i == 8'h02));
                        busy_o   <= 1'b1;
                        lcd_rs   <= rs_i;
                        lcd_data <= data_i;
                        cnt      <= '0;
                        state    <= S_URS;
                    end
                end

                // ── User RS setup ─────────────────────────────────────────────
                S_URS: begin
                    if (cnt == CW'(T_RS - 1)) begin
                        cnt <= '0; state <= S_UEHI;
                    end else cnt <= cnt + 1;
                end

                // ── User EN high ──────────────────────────────────────────────
                S_UEHI: begin
                    lcd_en <= 1'b1;
                    if (cnt == CW'(T_EHI - 1)) begin
                        cnt <= '0; state <= S_UELO;
                    end else cnt <= cnt + 1;
                end

                // ── User EN low ───────────────────────────────────────────────
                S_UELO: begin
                    lcd_en <= 1'b0;
                    if (cnt == CW'(T_ELO - 1)) begin
                        cnt   <= '0;
                        state <= S_UPOST;
                    end else cnt <= cnt + 1;
                end

                // ── User post-command delay ───────────────────────────────────
                S_UPOST: begin
                    begin
                        automatic int tgt;
                        tgt = u_long ? T_CLR : T_EXEC;
                        if (cnt == CW'(tgt - 1)) begin
                            done_o <= 1'b1;
                            busy_o <= 1'b0;
                            cnt    <= '0;
                            state  <= S_IDLE;
                        end else cnt <= cnt + 1;
                    end
                end

                default: state <= S_IDELAY;
            endcase
        end
    end

endmodule
