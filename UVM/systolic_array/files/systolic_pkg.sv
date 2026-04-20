package systolic_pkg;
import uvm_pkg::*;
`include "uvm_macros.svh"

`include "systolic_seq_item.sv"
`include "systolic_corner_seq.sv"
`include "systolic_rand_seq.sv"
`include "systolic_stress_seq.sv"

`include "systolic_driver.sv"
`include "systolic_monitor.sv"
`include "systolic_agent.sv"

`include "systolic_scoreboard.sv"
`include "systolic_coverage.sv"

`include "systolic_env.sv"

`include "systolic_base_test.sv"
`include "systolic_rand_test.sv"
`include "systolic_stress_test.sv"
`include "systolic_full_test.sv"

endpackage