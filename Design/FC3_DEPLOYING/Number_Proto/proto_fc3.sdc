# =============================================================================
# proto_fc3.sdc  — CORRECTED v3
#
# Board  : EasyFPGA / RZ-EasyFPGA A2.2
# Device : Cyclone IV E - EP4CE6E22C8
# Clock  : 50 MHz onboard oscillator on PIN_23
#
# Changes vs v2:
#
#   [FIX-7]  set_false_path -to [get_clocks clk] replaced with
#            set_false_path -from [get_ports rst_n] (no -to clause).
#
#            In Synopsys SDC / Quartus TimeQuest, the -to argument of
#            set_false_path must be a TIMING ENDPOINT — i.e. a register
#            data-input pin or a port — NOT a clock object.
#            Writing "-to [get_clocks clk]" is invalid syntax and causes
#            the Timing Analyser to silently ignore the constraint or
#            report it as a warning, leaving spurious setup violations on
#            rst_n in place.
#
#            The same error existed for start_n in v2 and is also fixed.
#
#            Correct idiom for an asynchronous reset that must not be
#            analysed by the Timing Analyser at all:
#
#              set_false_path -from [get_ports rst_n]
#
#            This cuts EVERY path that originates from rst_n, which is
#            exactly right for an async reset — it never needs to meet
#            setup/hold to a clock edge.
#
#   [FIX-8]  Output false paths corrected for the same reason.
#            "-from [get_clocks clk]" is valid SDC (a launch clock is
#            a legal false-path source), so those lines were already
#            correct and are kept as-is.
# =============================================================================

# =============================================================================
# 1. CLOCK DEFINITION
# 50 MHz = 20 ns period
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
# 3. INPUT DELAYS AND FALSE PATHS
# =============================================================================

# rst_n — active-low async reset button
# Nominal delays tell the Fitter where to place the I/O cell.
# The false path cuts timing analysis entirely: rst_n feeds an async
# reset (posedge rst_n / negedge rst_n) and is never sampled at a
# clock edge, so no setup/hold analysis is meaningful.
# [FIX-7] -to clause removed; set_false_path -from [get_ports X] is the
#         correct idiom for async reset ports.
set_input_delay -clock clk -max 2.000 [get_ports rst_n]
set_input_delay -clock clk -min 0.500 [get_ports rst_n]
set_false_path  -from [get_ports rst_n]

# start_n — active-low button; passes through 2-flop synchroniser and
# 2^20-cycle debounce counter. False path suppresses spurious violations.
# [FIX-7] Same fix applied.
set_input_delay -clock clk -max 2.000 [get_ports start_n]
set_input_delay -clock clk -min 0.500 [get_ports start_n]
set_false_path  -from [get_ports start_n]

# =============================================================================
# 4. OUTPUT DELAYS AND FALSE PATHS — LCD (argmax_lcd.sv)
#
# Note: set_output_delay is declared even when set_false_path is used.
# The delays guide I/O placement; the false path suppresses Timing
# Analyser reporting.  Both are needed.
# The "-from [get_clocks clk]" form is valid SDC (launch-clock source).
# =============================================================================
set_output_delay -clock clk -max  2.000 [get_ports lcd_rs]
set_output_delay -clock clk -min -2.000 [get_ports lcd_rs]
set_false_path   -from [get_clocks clk] -to [get_ports lcd_rs]

set_output_delay -clock clk -max  2.000 [get_ports lcd_en]
set_output_delay -clock clk -min -2.000 [get_ports lcd_en]
set_false_path   -from [get_clocks clk] -to [get_ports lcd_en]

set_output_delay -clock clk -max  2.000 [get_ports {lcd_data[*]}]
set_output_delay -clock clk -min -2.000 [get_ports {lcd_data[*]}]
set_false_path   -from [get_clocks clk] -to [get_ports {lcd_data[*]}]

set_output_delay -clock clk -max  2.000 [get_ports done_led]
set_output_delay -clock clk -min -2.000 [get_ports done_led]
set_false_path   -from [get_clocks clk] -to [get_ports done_led]

# =============================================================================
# 5. OUTPUT DELAYS — 7-SEGMENT (commented out; re-enable if reverting)
# =============================================================================
set_output_delay -clock clk -max  2.000 [get_ports {seg[*]}]
set_output_delay -clock clk -min -2.000 [get_ports {seg[*]}]
 set_output_delay -clock clk -max  2.000 [get_ports seg_en]
set_output_delay -clock clk -min -2.000 [get_ports seg_en]
 set_false_path -from [get_clocks clk] -to [get_ports {seg[*]}]
 set_false_path -from [get_clocks clk] -to [get_ports seg_en]

# =============================================================================
# 6. MULTICYCLE PATHS
# Uncomment if 50 MHz timing fails on the NPU systolic array (PE registers).
# A 2-cycle setup multicycle path gives the combinatorial accumulate path
# 40 ns instead of 20 ns to meet timing — required for wider data widths.
# The matching hold = 1 prevents the hold check from over-constraining.
# =============================================================================
 set_multicycle_path -from [get_registers *PE_C_REG*] \
                     -to   [get_registers *PE_C_REG*] \
                     -setup 2
 set_multicycle_path -from [get_registers *PE_C_REG*] \
                     -to   [get_registers *PE_C_REG*] \
                     -hold  1

# =============================================================================
# END OF CONSTRAINTS
# =============================================================================
