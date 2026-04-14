// =============================================================================
// weight_rom_loader.sv
// Automatically loads all 44,190 INT8 weights into cnn_top after reset.
// Reads from weights.mem (hex format, one byte per line).
// Drives cnn_top's weight_write_* ports directly.
//
// Timing:
//   - Starts writing on the first cycle after rst deasserts
//   - Writes one weight per clock cycle
//   - loading_done pulses HIGH (and stays HIGH) after last address written
//   - Total load time: 44,190 clock cycles = ~0.44 ms at 100 MHz
//
// Usage:
//   - Add weights.mem to your Vivado project sources
//   - weights.mem format: one 2-digit hex byte per line, e.g.:
//       FF
//       3A
//       01
//       ...  (44190 lines total)
// =============================================================================

module weight_rom_loader #(
    parameter TOTAL_WEIGHTS = 44190,                        // must match cnn_top
    parameter ADDR_WIDTH    = 16,                           // clog2(44190) = 16
    parameter DATA_WIDTH    = 8                             // INT8
)(
    input  logic                    clk,
    input  logic                    rst,                    // active-high sync reset

    // Drives cnn_top weight write ports
    output logic [ADDR_WIDTH-1:0]   weight_write_addr,
    output logic [DATA_WIDTH-1:0]   weight_write_data,
    output logic                    weight_write_enable,

    output logic                    loading_done            // stays HIGH when complete
);

    // -------------------------------------------------------------------------
    // ROM — synthesizes to BRAM on Arty A7
    // Vivado reads weights.mem at synthesis time and bakes values into bitstream
    // -------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] rom [0:TOTAL_WEIGHTS-1];

    initial begin
        $readmemh("all_weights.mem", rom);
    end

    // -------------------------------------------------------------------------
    // FSM — two states: LOADING and DONE
    // -------------------------------------------------------------------------
    typedef enum logic { LOADING = 1'b0, DONE = 1'b1 } state_t;
    state_t state;

    logic [ADDR_WIDTH-1:0] addr_cnt;

    always_ff @(posedge clk) begin
        if (rst) begin
            state               <= LOADING;
            addr_cnt            <= '0;
            weight_write_enable <= 1'b0;
            weight_write_addr   <= '0;
            weight_write_data   <= '0;
            loading_done        <= 1'b0;
        end else begin
            case (state)

                LOADING: begin
                    weight_write_enable <= 1'b1;
                    weight_write_addr   <= addr_cnt;
                    weight_write_data   <= rom[addr_cnt];

                    if (addr_cnt == ADDR_WIDTH'(TOTAL_WEIGHTS - 1)) begin
                        // Last address written this cycle
                        state               <= DONE;
                        weight_write_enable <= 1'b0;
                        loading_done        <= 1'b1;
                    end else begin
                        addr_cnt <= addr_cnt + 1'b1;
                    end
                end

                DONE: begin
                    // Hold outputs stable, never re-write
                    weight_write_enable <= 1'b0;
                    loading_done        <= 1'b1;
                end

            endcase
        end
    end

endmodule
