module requantization_block #(

parameter in_scale = 32'd2147484,  // 0.001 instead of 0.02
parameter we_scale = 32'd2147484,  // 0.001 instead of 0.03
parameter out_scale = 32'd21474836, // 0.01
	parameter sys_row = 2,
	parameter sys_col = 4,
	parameter shift = 24
)(
	input logic clk,
        input logic start,
	input logic rst,
	input logic [31:0] sys_out [0:sys_row-1][0:sys_col-1], // systolic array output
	output logic [7:0] requant_out [0:sys_row-1][0:sys_col-1] // array after requantization
);
	//-------------------------------------
	// conversion of scales into Q1.31
	//-------------------------------------
	logic [63:0] temp_scale;
	logic [31:0] requant_scale;

	always_comb begin
		temp_scale = in_scale * we_scale;    // 64-bit multiplication
		requant_scale = (temp_scale + (out_scale>>1)) / out_scale; //(out_scale>>1) to achieve rounding 
	end

	//-------------------------------------
	// input preparation
	//-------------------------------------
	logic [31:0] buffer [0:sys_row-1][0:sys_col-1];  

	genvar ro, co;
	generate
		for (ro = 0; ro < sys_row; ro = ro + 1) begin : ro_loop
			for (co = 0; co < sys_col; co = co + 1) begin : co_loop
				assign buffer[ro][co] = sys_out[ro][co];  
			end
		end
	endgenerate

	//-------------------------------------
	// requantization calculation
	//-------------------------------------
	logic  [63:0] mult_res;
	logic  [31:0] shift_res;

	genvar row, c;
	generate
		for (row = 0; row < sys_row; row++) begin : row_loop
			for (c = 0; c < sys_col; c++) begin : col_loop
            
				always_ff @(posedge clk ) begin
					if (rst) begin
						mult_res <= 64'd0;
						shift_res <= 32'd0;
					end
					else if(start) begin
	                			//  multiplication
						mult_res = buffer[row][c] * requant_scale; // 64-bit result
                
	                			// right shift + rounding
						shift_res = (mult_res + (1 << (shift-1))) >>> shift;
                
	                			// saturation
						if (shift_res > 255)
							requant_out[row][c] = 8'd255;
						else if (shift_res < 0)
							requant_out[row][c] = 8'd0;
						else
							requant_out[row][c] = shift_res[7:0];
						end
				end
			end
end
	endgenerate


 endmodule 