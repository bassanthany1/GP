
// conv_controller_sequences.svh - UVM Sequences for conv_controller
`ifndef CONV_CONTROLLER_SEQUENCES_SVH
`define CONV_CONTROLLER_SEQUENCES_SVH

// Base sequence
class conv_controller_base_seq extends uvm_sequence #(conv_controller_seq_item);
    `uvm_object_utils(conv_controller_base_seq)

    function new(string name = "conv_controller_base_seq");
        super.new(name);
    endfunction
endclass

// Basic convolution sequence
class conv_controller_basic_seq extends conv_controller_base_seq;
    `uvm_object_utils(conv_controller_basic_seq)

    function new(string name = "conv_controller_basic_seq");
        super.new(name);
    endfunction

    task body();
        conv_controller_seq_item item;

        item = conv_controller_seq_item::type_id::create("item");
        start_item(item);
        if(!item.randomize() with {
            kernel_size == 3;
            out_channels == 16;
            input_height == 28;
            input_width == 28;
            fc_mode == 0;
        }) begin
            `uvm_error("SEQ", "Randomization failed for basic sequence")
        end
        finish_item(item);
    endtask
endclass

// Random convolution sequence
class conv_controller_random_seq extends conv_controller_base_seq;
    `uvm_object_utils(conv_controller_random_seq)

    int num_transactions;

    function new(string name = "conv_controller_random_seq");
        super.new(name);
        num_transactions = 10;
    endfunction

    task body();
        conv_controller_seq_item item;

        repeat(num_transactions) begin
            item = conv_controller_seq_item::type_id::create("item");
            start_item(item);
            if(!item.randomize()) begin
                `uvm_error("SEQ", "Randomization failed for random sequence")
            end
            finish_item(item);
        end
    endtask
endclass

// FC mode sequence
class conv_controller_fc_seq extends conv_controller_base_seq;
    `uvm_object_utils(conv_controller_fc_seq)

    function new(string name = "conv_controller_fc_seq");
        super.new(name);
    endfunction

    task body();
        conv_controller_seq_item item;

        item = conv_controller_seq_item::type_id::create("item");
        start_item(item);
        if(!item.randomize() with {
            fc_mode == 1;
            kernel_size == 5;
            out_channels == 64;
            input_height == 28;
            input_width == 28;
        }) begin
            `uvm_error("SEQ", "Randomization failed for FC sequence")
        end
        finish_item(item);
    endtask
endclass

// Max parameters sequence
class conv_controller_max_params_seq extends conv_controller_base_seq;
    `uvm_object_utils(conv_controller_max_params_seq)

    function new(string name = "conv_controller_max_params_seq");
        super.new(name);
    endfunction

    task body();
        conv_controller_seq_item item;

        item = conv_controller_seq_item::type_id::create("item");
        start_item(item);
        if(!item.randomize() with {
            kernel_size == 5;
            out_channels == 120;
            input_height == 28;
            input_width == 28;
            fc_mode == 0;
        }) begin
            `uvm_error("SEQ", "Randomization failed for max params sequence")
        end
        finish_item(item);
    endtask
endclass

`endif // CONV_CONTROLLER_SEQUENCES_SVH
