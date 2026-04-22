# =============================================================================
# proto_fc3.sdc
# Timing Constraints for FC3 Prototype
# Board: EasyFPGA / RZ-EasyFPGA A2.2
# Device: Cyclone IV E - EP4CE6E22C8
# Clock: 50 MHz onboard oscillator on PIN_24
# =============================================================================

# =============================================================================
# 1. CLOCK DEFINITION
# 50 MHz = 20 ns period
# PIN_24 is the 50 MHz oscillator on EasyFPGA board
# =============================================================================
create_clock \
    -name  clk \
    -period 20.000 \
    -waveform {0 10} \
    [get_ports clk]

# =============================================================================
# 2. CLOCK UNCERTAINTY
# Accounts for jitter and skew on the board oscillator
# =============================================================================
set_clock_uncertainty -rise_from [get_clocks clk] \
                      -rise_to   [get_clocks clk] 0.5
set_clock_uncertainty -fall_from [get_clocks clk] \
                      -fall_to   [get_clocks clk] 0.5

# =============================================================================
# 3. INPUT DELAYS
# rst_n and any other inputs - set conservative 2ns delay
# =============================================================================
set_input_delay \
    -clock clk \
    -max 2.000 \
    [get_ports rst_n]

set_input_delay \
    -clock clk \
    -min 0.500 \
    [get_ports rst_n]

# =============================================================================
# 4. OUTPUT DELAYS
# seg[6:0], seg_en, done_led - these go to on-board 7-seg and LED
# Very relaxed because the 7-seg display has no timing requirement
# =============================================================================
set_output_delay \
    -clock clk \
    -max 2.000 \
    [get_ports {seg[*]}]

set_output_delay \
    -clock clk \
    -min -2.000 \
    [get_ports {seg[*]}]

set_output_delay \
    -clock clk \
    -max 2.000 \
    [get_ports seg_en]

set_output_delay \
    -clock clk \
    -min -2.000 \
    [get_ports seg_en]

set_output_delay \
    -clock clk \
    -max 2.000 \
    [get_ports done_led]

set_output_delay \
    -clock clk \
    -min -2.000 \
    [get_ports done_led]

# =============================================================================
# 5. FALSE PATHS
# Cut timing paths to/from outputs that have no real timing requirement.
# The 7-segment display and LED are purely visual - no setup/hold needed.
# This removes them from the critical path report so you can focus on
# the real timing issues inside the compute logic.
# =============================================================================
set_false_path -from [get_clocks clk] -to [get_ports {seg[*]}]
set_false_path -from [get_clocks clk] -to [get_ports seg_en]
set_false_path -from [get_clocks clk] -to [get_ports done_led]
set_false_path -from [get_ports rst_n] -to [get_clocks clk]

# =============================================================================
# 6. MULTICYCLE PATHS (optional - uncomment if timing fails at 50 MHz)
#
# The systolic array accumulator has a long path.
# If Timing Analyzer reports negative slack on internal paths,
# uncomment these lines to allow 2 cycles for those paths.
# This is safe because the systolic array already takes many cycles
# to compute and the controller waits for valid_out before reading.
# =============================================================================
# set_multicycle_path -from [get_registers *PE_C_REG*] \
#                     -to   [get_registers *PE_C_REG*] \
#                     -setup 2
# set_multicycle_path -from [get_registers *PE_C_REG*] \
#                     -to   [get_registers *PE_C_REG*] \
#                     -hold  1

# =============================================================================
# 7. IF 50 MHz FAILS: Switch to 25 MHz
#
# If after running Timing Analysis you see negative slack,
# comment out the 50 MHz clock above and uncomment this instead:
# =============================================================================
# create_clock \
#     -name  clk \
#     -period 40.000 \
#     -waveform {0 20} \
#     [get_ports clk]

# =============================================================================
# END OF CONSTRAINTS
# =============================================================================
