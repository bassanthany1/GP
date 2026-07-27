# =============================================================================
# proto_fc3_top.sdc
# Timing Constraints for the malaria classifier (proto_fc3_top as top level)
# Board: EasyFPGA / RZ-EasyFPGA A2.2
# Device: Cyclone IV E - EP4CE6E22C8
# Clock: 50 MHz onboard oscillator, PIN_23 (confirmed against the verified
#        pin table - PIN_24 was only ever a stale comment in an older file)
# =============================================================================

# =============================================================================
# 1. CLOCK DEFINITION
# =============================================================================
create_clock \
    -name  clk \
    -period 20.000 \
    -waveform {0 10} \
    [get_ports clk]

# =============================================================================
# 2. CLOCK UNCERTAINTY
# =============================================================================
set_clock_uncertainty -rise_from [get_clocks clk] \
                      -rise_to   [get_clocks clk] 0.5
set_clock_uncertainty -fall_from [get_clocks clk] \
                      -fall_to   [get_clocks clk] 0.5

# =============================================================================
# 3. INPUT DELAYS / FALSE PATHS - rst_n and start_n
#
# rst_n is the raw physical RESET button. start_n is the raw physical START
# button (KEY1), fed straight into proto_fc3_top's own internal 2-stage
# synchronizer + ~21ms debounce counter. Neither has a real setup/hold
# requirement relative to clk - both are async and are cut entirely rather
# than given an artificial input delay budget.
# =============================================================================
set_input_delay -clock clk -max 2.000 [get_ports rst_n]
set_input_delay -clock clk -min 0.500 [get_ports rst_n]

set_input_delay -clock clk -max 2.000 [get_ports start_n]
set_input_delay -clock clk -min 0.500 [get_ports start_n]

set_false_path -from [get_ports rst_n]   -to [get_clocks clk]
set_false_path -from [get_ports start_n] -to [get_clocks clk]

# =============================================================================
# 4. OUTPUT DELAYS / FALSE PATHS - status outputs
#
# seg[*], dig_sel[*], led_green, buzzer, done_led all drive purely visual or
# audible indicators (7-seg digits, an LED, a piezo buzzer). None have a real
# timing requirement - relaxed output delays plus false paths.
# =============================================================================
set_output_delay -clock clk -max 2.000  [get_ports {seg[*]}]
set_output_delay -clock clk -min -2.000 [get_ports {seg[*]}]

set_output_delay -clock clk -max 2.000  [get_ports {dig_sel[*]}]
set_output_delay -clock clk -min -2.000 [get_ports {dig_sel[*]}]

set_output_delay -clock clk -max 2.000  [get_ports led_green]
set_output_delay -clock clk -min -2.000 [get_ports led_green]

set_output_delay -clock clk -max 2.000  [get_ports buzzer]
set_output_delay -clock clk -min -2.000 [get_ports buzzer]

set_output_delay -clock clk -max 2.000  [get_ports done_led]
set_output_delay -clock clk -min -2.000 [get_ports done_led]

set_false_path -from [get_clocks clk] -to [get_ports {seg[*]}]
set_false_path -from [get_clocks clk] -to [get_ports {dig_sel[*]}]
set_false_path -from [get_clocks clk] -to [get_ports led_green]
set_false_path -from [get_clocks clk] -to [get_ports buzzer]
set_false_path -from [get_clocks clk] -to [get_ports done_led]

# =============================================================================
# 5. MULTICYCLE PATHS (optional - uncomment if timing fails at 50 MHz)
#
# The systolic array accumulator has a long path. If Timing Analyzer reports
# negative slack on internal paths, uncomment these to allow 2 cycles.
# Safe because the systolic array already takes many cycles to compute and
# the controller waits for valid_out before reading.
# =============================================================================
# set_multicycle_path -from [get_registers *PE_C_REG*] \
#                     -to   [get_registers *PE_C_REG*] \
#                     -setup 2
# set_multicycle_path -from [get_registers *PE_C_REG*] \
#                     -to   [get_registers *PE_C_REG*] \
#                     -hold  1

# =============================================================================
# 6. IF 50 MHz FAILS: switch to 25 MHz
# =============================================================================
# create_clock \
#     -name  clk \
#     -period 40.000 \
#     -waveform {0 20} \
#     [get_ports clk]

# =============================================================================
# END OF CONSTRAINTS
# =============================================================================
