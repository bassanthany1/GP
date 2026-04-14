// =============================================================================
// bias_rom_loader.sv
// Automatically loads all 236 INT32 biases into cnn_top after reset.
// Reads from biases.mem (hex format, one 32-bit word per line, big-endian).
//
// Timing:
//   - Starts after rst deasserts
//   - Writes one bias (32-bit) per clock cycle
//   - loading_done pulses HIGH after last address written
//   - Total load time: 236 clock cycles = ~2.36 µs at 100 MHz
//
// Usage:
//   - Add biases.mem to your Vivado project sources
//   - biases.mem format: one 8-digit hex word per line, e.g.:
//       0000FF3A
//       FFFF0012
//       ...  (236 lines total)
//
//   Generate with Python:
//       biases = np.load('biases_int32.npy').flatten().astype(np.int32)
//       with open('biases.mem', 'w') as f:
//           for b in biases:
//               f.write(f'{b & 0xFFFFFFFF:08X}\n')
// =============================================================================

module bias_rom_loader #(
    parameter TOTAL_BIASES = 236,                           // must match cnn_top
    parameter ADDR_WIDTH   = 8,                             // clog2(236) = 8
    parameter DATA_WIDTH   = 32                             // INT32 bias
)(
    input  logic                    clk,
    input  logic                    rst,                    // active-high sync reset

    // Drives cnn_top bias write ports
    output logic [ADDR_WIDTH-1:0]   bias_write_addr,
    output logic [DATA_WIDTH-1:0]   bias_write_data,
    output logic                    bias_write_enable,

    output logic                    loading_done            // stays HIGH when complete
);

    // -------------------------------------------------------------------------
    // ROM — synthesizes to BRAM or LUT-RAM depending on size
    // 236 × 32-bit = 7,552 bits — fits easily in one BRAM18 on Arty A7
    // -------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] rom [0:TOTAL_BIASES-1];

    initial begin
        $readmemh("all_biases_zp_fixed.mem", rom);
    end

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic { LOADING = 1'b0, DONE = 1'b1 } state_t;
    state_t state;

    logic [ADDR_WIDTH-1:0] addr_cnt;

    always_ff @(posedge clk) begin
        if (rst) begin
            state              <= LOADING;
            addr_cnt           <= '0;
            bias_write_enable  <= 1'b0;
            bias_write_addr    <= '0;
            bias_write_data    <= '0;
            loading_done       <= 1'b0;
        end else begin
            case (state)

                LOADING: begin
                    bias_write_enable <= 1'b1;
                    bias_write_addr   <= addr_cnt;
                    bias_write_data   <= rom[addr_cnt];

                    if (addr_cnt == ADDR_WIDTH'(TOTAL_BIASES - 1)) begin
                        state             <= DONE;
                        bias_write_enable <= 1'b0;
                        loading_done      <= 1'b1;
                    end else begin
                        addr_cnt <= addr_cnt + 1'b1;
                    end
                end

                DONE: begin
                    bias_write_enable <= 1'b0;
                    loading_done      <= 1'b1;
                end

            endcase
        end
    end

endmodule
