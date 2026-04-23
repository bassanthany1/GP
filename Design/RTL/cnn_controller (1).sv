// cnn_controller.sv  (FIXED)
// Change summary:
//   ADDED: layer_done_prev register + layer_done_rise edge detector
//   CHANGED: S_WAIT now waits for RISING EDGE of layer_done, not level
//   REASON: layer_done stays high for multiple cycles at end of FC layer.
//           When the next FC layer starts, layer_done from the previous
//           layer is still asserted, causing S_WAIT to exit immediately
//           and skip the new layer entirely.
// Everything else is identical to the original.

module cnn_controller #(
    parameter MAX_KERNEL_SIZE  = 5,
    parameter MAX_IN_CHANNELS  = 256,
    parameter MAX_OUT_CHANNELS = 120,
    parameter MAX_INPUT_HEIGHT = 28,
    parameter MAX_INPUT_WIDTH  = 28,
    parameter TOTAL_WEIGHTS    = 44190,
    parameter MAX_WEIGHTS      = 30720,
    parameter TOTAL_BIASES     = 236,
    parameter MAX_BIASES       = 120,
    parameter NUM_LAYERS       = 5
)(
    input  logic clk,
    input  logic rst,

    input  logic start_inference,
    output logic inference_done,
    output logic [2:0] current_layer,

    output logic start_layer,
    input  logic layer_done,

    output logic [$clog2(MAX_KERNEL_SIZE+1)-1:0]  kernel_size,
    output logic [$clog2(MAX_IN_CHANNELS+1)-1:0]  in_channels,
    output logic [$clog2(MAX_OUT_CHANNELS+1)-1:0] out_channels,
    output logic [$clog2(MAX_INPUT_HEIGHT+1)-1:0] input_height,
    output logic [$clog2(MAX_INPUT_WIDTH+1)-1:0]  input_width,

    output logic fc_mode,
    output logic enable_relu,

    output logic [31:0]       requant_scale,
    output logic [5:0]        requant_shift,
    output logic signed [7:0] ZP_next,

    output logic [$clog2(TOTAL_WEIGHTS+1)-1:0] weight_layer_offset,

    output logic [$clog2(TOTAL_BIASES+1)-1:0]  bias_layer_offset
 


);

    // =========================================================================
    // Layer configuration ROM
    // =========================================================================
    logic [2:0]  cfg_kernel   [NUM_LAYERS];
    logic [8:0]  cfg_in_ch    [NUM_LAYERS];
    logic [7:0]  cfg_out_ch   [NUM_LAYERS];
    logic [5:0]  cfg_in_h     [NUM_LAYERS];
    logic [5:0]  cfg_in_w     [NUM_LAYERS];
    logic        cfg_fc_mode  [NUM_LAYERS];
    logic        cfg_relu     [NUM_LAYERS];
    logic [31:0] cfg_rq_scale [NUM_LAYERS];
    logic [5:0]  cfg_rq_shift [NUM_LAYERS];
    logic [7:0]  cfg_zp_next  [NUM_LAYERS];
    logic [15:0] cfg_w_off    [NUM_LAYERS];
    
    logic [7:0]  cfg_b_off    [NUM_LAYERS];


    always_comb begin
        // Layer 0 - C1
        cfg_kernel  [0] = 3'd5;
        cfg_in_ch   [0] = 8'd1;
        cfg_out_ch  [0] = 8'd6;
        cfg_in_h    [0] = 6'd28;
        cfg_in_w    [0] = 6'd28;
        cfg_fc_mode [0] = 1'b0;
        cfg_relu    [0] = 1'b1;
        cfg_rq_scale[0] = 32'd2133656752;
        cfg_rq_shift[0] = 6'd40;
        cfg_zp_next [0] = 8'(-128);
        cfg_w_off   [0] = 16'd0;
    
        cfg_b_off   [0] = 8'd0;
      
 

        // Layer 1 - C2
        cfg_kernel  [1] = 3'd5;
        cfg_in_ch   [1] = 8'd6;
        cfg_out_ch  [1] = 8'd16;
        cfg_in_h    [1] = 6'd12;
        cfg_in_w    [1] = 6'd12;
        cfg_fc_mode [1] = 1'b0;
        cfg_relu    [1] = 1'b1;
        cfg_rq_scale[1] = 32'd1177891675;
        cfg_rq_shift[1] = 6'd38;
        cfg_zp_next [1] = 8'(-128);
        cfg_w_off   [1] = 16'd150;
       
        cfg_b_off   [1] = 8'd6;
     
      

        // Layer 2 - FC1
        cfg_kernel  [2] = 3'd1;
        cfg_in_ch   [2] = 9'd256;
        cfg_out_ch  [2] = 8'd120;
        cfg_in_h    [2] = 6'd1;
        cfg_in_w    [2] = 6'd1;
        cfg_fc_mode [2] = 1'b1;
        cfg_relu    [2] = 1'b1;
        cfg_rq_scale[2] = 32'd1773475289;
        cfg_rq_shift[2] = 6'd38;
        cfg_zp_next [2] = 8'(-128);
        cfg_w_off   [2] = 16'd2550;
     
        cfg_b_off   [2] = 8'd22;
       
     

        // Layer 3 - FC2
        cfg_kernel  [3] = 3'd1;
        cfg_in_ch   [3] = 8'd120;
        cfg_out_ch  [3] = 8'd84;
        cfg_in_h    [3] = 6'd1;
        cfg_in_w    [3] = 6'd1;
        cfg_fc_mode [3] = 1'b1;
        cfg_relu    [3] = 1'b1;
        cfg_rq_scale[3] = 32'd1132918009;
        cfg_rq_shift[3] = 6'd37;
        cfg_zp_next [3] = 8'(-128);
        cfg_w_off   [3] = 16'd33270;
        
        cfg_b_off   [3] = 8'd142;
     
       

        // Layer 4 - FC3 / Output
        cfg_kernel  [4] = 3'd1;
        cfg_in_ch   [4] = 8'd84;
        cfg_out_ch  [4] = 8'd10;
        cfg_in_h    [4] = 6'd1;
        cfg_in_w    [4] = 6'd1;
        cfg_fc_mode [4] = 1'b1;
        cfg_relu    [4] = 1'b0;
        cfg_rq_scale[4] = 32'd1539601606;
        cfg_rq_shift[4] = 6'd38;
        cfg_zp_next [4] = 8'd26;
        cfg_w_off   [4] = 16'd43350;
      
        cfg_b_off   [4] = 8'd226;
      
    
    end

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [2:0] {
        S_IDLE,
        S_SETUP,
        S_START,
        S_WAIT,
        S_NEXT,
        S_DONE
    } fsm_t;

    fsm_t       state;
    logic [2:0] layer_idx;
    logic       start_pulse_sent;

    // =========================================================================
    // FIX: layer_done edge detector
    //
    // Problem: layer_done is a LEVEL signal that stays high for multiple cycles
    //          at the end of each FC layer. When the next FC layer starts and
    //          the controller enters S_WAIT, layer_done from the previous layer
    //          is still asserted, causing S_WAIT to exit immediately and skip
    //          the new layer entirely.
    //
    // Fix: register layer_done and only act on its RISING EDGE (0->1 transition)
    //      This guarantees the controller sees exactly one done event per layer
    //      regardless of how long layer_done stays high.
    // =========================================================================
    logic layer_done_prev;   // layer_done delayed by 1 cycle
    logic layer_done_rise;   // true only on the rising edge of layer_done

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            layer_done_prev <= 1'b0;
        else
            layer_done_prev <= layer_done;
    end

    // Rising edge: layer_done just went 0->1
    assign layer_done_rise = layer_done && !layer_done_prev;

    // =========================================================================
    // Main FSM
    // =========================================================================
    always_ff @(posedge clk or posedge rst ) begin
        if (rst) begin
            state            <= S_IDLE;
            layer_idx        <= '0;
            start_layer      <= 1'b0;
            inference_done   <= 1'b0;
            start_pulse_sent <= 1'b0;
        end else begin
            // Defaults
            start_layer    <= 1'b0;
            inference_done <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (start_inference) begin
                        layer_idx <= 3'd0;
                        state     <= S_SETUP;
                    end
                end

                S_SETUP: begin
                    start_pulse_sent <= 1'b0;
                    state            <= S_START;
                    // S_SETUP gives one idle cycle so layer_done_prev
                    // has time to reflect the previous layer_done level.
                    // By the time we reach S_WAIT (2 cycles later),
                    // layer_done_rise will be 0 if layer_done was already
                    // high before start_layer fired.
                end

                S_START: begin
                    if (!start_pulse_sent) begin
                        start_layer      <= 1'b1;
                        start_pulse_sent <= 1'b1;
                        state            <= S_WAIT;
                    end
                end

                // ---------------------------------------------------------
                // KEY FIX: wait for RISING EDGE of layer_done
                // not just its level ? prevents false triggering from
                // previous layer's layer_done still being asserted
                // ---------------------------------------------------------
                S_WAIT: begin
                    if (layer_done_rise) begin   // was: if (layer_done)
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    if (layer_idx == NUM_LAYERS - 1) begin
                        state <= S_DONE;
                    end else begin
                        layer_idx <= layer_idx + 1'b1;
                        state     <= S_SETUP;
                    end
                end

                S_DONE: begin
                    inference_done <= 1'b1;
                    state          <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Output mux
    // =========================================================================
    assign current_layer = layer_idx;

    always_comb begin
        kernel_size         = cfg_kernel  [layer_idx];
        in_channels         = cfg_in_ch   [layer_idx];
        out_channels        = cfg_out_ch  [layer_idx];
        input_height        = cfg_in_h    [layer_idx];
        input_width         = cfg_in_w    [layer_idx];
        fc_mode             = cfg_fc_mode [layer_idx];
        enable_relu         = cfg_relu    [layer_idx];
        requant_scale       = cfg_rq_scale[layer_idx];
        requant_shift       = cfg_rq_shift[layer_idx];
        ZP_next             = signed'(cfg_zp_next[layer_idx]);
        weight_layer_offset = cfg_w_off   [layer_idx];
    
        bias_layer_offset   = cfg_b_off   [layer_idx];
   
    
    end

endmodule
