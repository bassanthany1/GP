
// conv_controller_seq_item.svh - UVM Sequence Item for conv_controller
`ifndef CONV_CONTROLLER_SEQ_ITEM_SVH
`define CONV_CONTROLLER_SEQ_ITEM_SVH

class conv_controller_seq_item extends uvm_sequence_item;

    // Configuration parameters
    rand logic [$clog2(5+1)-1:0]  kernel_size;
    rand logic [$clog2(120+1)-1:0] out_channels;
    rand logic [$clog2(28+1)-1:0] input_height;
    rand logic [$clog2(28+1)-1:0] input_width;
    rand logic                    fc_mode;

    // Response signals
    logic                         conv_done;
    logic                         start_im2col;
    logic                         im2col_tile_ready;
    logic                         start_weight;
    logic                         weight_tile_ready;
    logic                         systolic_load;
    logic                         systolic_valid;
    logic signed [31:0]           systolic_out [4][4];
    logic                         output_valid;
    logic signed [31:0]           output_data [4][4];
    logic [$clog2(120)-1:0]       output_channel_start;
    logic [$clog2(28*28)-1:0]     output_window_idx_start;

    // Randomization constraints
    constraint valid_kernel_size_c {
        kernel_size inside {[3:5]};
    }

    constraint valid_out_channels_c {
        out_channels inside {[1:120]};
    }

    constraint valid_input_height_c {
        input_height inside {[5:28]};
    }

    constraint valid_input_width_c {
        input_width inside {[5:28]};
    }

    `uvm_object_utils_begin(conv_controller_seq_item)
        `uvm_field_int(kernel_size, UVM_ALL_ON)
        `uvm_field_int(out_channels, UVM_ALL_ON)
        `uvm_field_int(input_height, UVM_ALL_ON)
        `uvm_field_int(input_width, UVM_ALL_ON)
        `uvm_field_int(fc_mode, UVM_ALL_ON)
        `uvm_field_int(conv_done, UVM_ALL_ON)
        `uvm_field_int(start_im2col, UVM_ALL_ON)
        `uvm_field_int(im2col_tile_ready, UVM_ALL_ON)
        `uvm_field_int(start_weight, UVM_ALL_ON)
        `uvm_field_int(weight_tile_ready, UVM_ALL_ON)
        `uvm_field_int(systolic_load, UVM_ALL_ON)
        `uvm_field_int(systolic_valid, UVM_ALL_ON)
        `uvm_field_int(output_valid, UVM_ALL_ON)
        `uvm_field_int(output_channel_start, UVM_ALL_ON)
        `uvm_field_int(output_window_idx_start, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "conv_controller_seq_item");
        super.new(name);
    endfunction

endclass

`endif // CONV_CONTROLLER_SEQ_ITEM_SVH
