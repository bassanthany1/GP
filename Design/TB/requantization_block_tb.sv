`timescale 1ns/1ps

module requantization_tb;

    // Parameters
    parameter in_scale = 32'd42949673;
    parameter we_scale = 32'd64424509;
    parameter out_scale =32'd21474836;
    parameter sys_row = 3;
    parameter sys_col = 3;
    parameter shift = 24;

    // Clock & Reset
    logic clk;
    logic rst;

    // Inputs & Outputs
    logic [31:0] sys_out [0:sys_row-1][0:sys_col-1];
    logic [7:0] requant_out [0:sys_row-1][0:sys_col-1];

    // Golden output from MATLAB
    logic [7:0] golden_out [0:sys_row-1][0:sys_col-1];

    // Instantiate DUT
    requantization_block #(
        .in_scale(in_scale),
        .we_scale(we_scale),
        .out_scale(out_scale),
        .sys_row(sys_row),
        .sys_col(sys_col),
        .shift(shift)
    ) DUT (
        .clk(clk),
        .rst(rst),
        .sys_out(sys_out),
        .requant_out(requant_out)
    );

    // Clock generation

    initial clk = 0;
    always #5 clk = ~clk; // 10ns period

    // Task to read CSV decimal file
    task read_csv(input string filename, output logic [31:0] array [0:sys_row-1][0:sys_col-1]);
        integer fd;
        integer r, c;
        integer ret;
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $display("Error opening file: %s", filename);
            $finish;
        end
        for (r = 0; r < sys_row; r = r + 1) begin
            for (c = 0; c < sys_col; c = c + 1) begin
                ret = $fscanf(fd, "%d,", array[r][c]);
                if (ret != 1) begin
                    $display("Error reading value at row %0d col %0d", r, c);
                    $finish;
                end
            end
        end
        $fclose(fd);
    endtask

    // Task to read 8-bit golden output
    task read_csv8(input string filename, output logic [7:0] array [0:sys_row-1][0:sys_col-1]);
        integer fd;
        integer r, c;
        integer val;
        integer ret;
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $display("Error opening file: %s", filename);
            $finish;
        end
        for (r = 0; r < sys_row; r = r + 1) begin
            for (c = 0; c < sys_col; c = c + 1) begin
                ret = $fscanf(fd, "%d,", val);
                if (ret != 1) begin
                    $display("Error reading value at row %0d col %0d", r, c);
                    $finish;
                end
                array[r][c] = val[7:0];
            end
        end
        $fclose(fd);
    endtask

    // Task to print a 2D array
    task print_array32(input string name, input logic [31:0] array [0:sys_row-1][0:sys_col-1]);
        integer r, c;
        $display("%s:", name);
        for (r = 0; r < sys_row; r = r + 1) begin
            $write("Row %0d: ", r);
            for (c = 0; c < sys_col; c = c + 1) $write("%0d ", array[r][c]);
            $write("\n");
        end
    endtask

    task print_array8(input string name, input logic [7:0] array [0:sys_row-1][0:sys_col-1]);
        integer r, c;
        $display("%s:", name);
        for (r = 0; r < sys_row; r = r + 1) begin
            $write("Row %0d: ", r);
            for (c = 0; c < sys_col; c = c + 1) $write("%0d ", array[r][c]);
            $write("\n");
        end
    endtask

    // Task to compare DUT output with golden reference
    task check_output;
        integer i, j;
        integer errors;
        errors = 0;
        for (i = 0; i < sys_row; i = i + 1) begin
            for (j = 0; j < sys_col; j = j + 1) begin
                if (requant_out[i][j] !== golden_out[i][j]) begin
                    $display("Mismatch at [%0d][%0d]: DUT = %0d, Golden = %0d", i, j, requant_out[i][j], golden_out[i][j]);
                    errors = errors + 1;
                end
            end
        end
        if (errors == 0)
            $display("All outputs match the golden reference. PASS!");
        else
            $display("Total mismatches: %0d. FAIL!", errors);
    endtask

    // Test sequence
    initial begin
        rst = 1;
        #20;
        rst = 0;

        $display("Reading sys_out from CSV...");
        read_csv("F:/modelsim/graduation/sys_out.csv", sys_out);
        print_array32("sys_out", sys_out);

        $display("Reading golden output from CSV...");
        read_csv8("F:/modelsim/graduation/requant_out.csv", golden_out);
        print_array8("golden_out", golden_out);

        #20; // wait a few clocks

        print_array8("requant_out (DUT output)", requant_out);

        // Check outputs
        check_output();

        #50;
        $finish;
    end

endmodule

