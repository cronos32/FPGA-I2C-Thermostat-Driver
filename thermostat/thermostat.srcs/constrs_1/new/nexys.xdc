# =================================================
# Nexys A7-50T - General Constraints File
# Based on https://github.com/Digilent/digilent-xdc
# =================================================

# -----------------------------------------------
# Voltage
# -----------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# -----------------------------------------------
# Clock
# -----------------------------------------------
set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports {clk}];
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports {clk}];

# -----------------------------------------------
# Push buttons
# -----------------------------------------------
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports {btnc}];
set_property -dict { PACKAGE_PIN M18 IOSTANDARD LVCMOS33 } [get_ports {btnu}];
set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports {btnd}];

# -----------------------------------------------
#Temperature Sensor
# -----------------------------------------------
set_property -dict  { PACKAGE_PIN C14   IOSTANDARD LVCMOS33 PULLUP true} [get_ports { TMP_SCL }]; #IO_L1N_T0_AD0N_15 Sch=tmp_scl
set_property -dict { PACKAGE_PIN C15   IOSTANDARD LVCMOS33 PULLUP true} [get_ports { TMP_SDA }]; #IO_L12N_T1_MRCC_15 Sch=tmp_sda

# -----------------------------------------------
# Seven-segment cathodes CA..CG + DP (active-low)
# seg[6]=A ... seg[0]=G
# -----------------------------------------------
set_property PACKAGE_PIN T10 [get_ports {seg[6]}]; # CA
set_property PACKAGE_PIN R10 [get_ports {seg[5]}]; # CB
set_property PACKAGE_PIN K16 [get_ports {seg[4]}]; # CC
set_property PACKAGE_PIN K13 [get_ports {seg[3]}]; # CD
set_property PACKAGE_PIN P15 [get_ports {seg[2]}]; # CE
set_property PACKAGE_PIN T11 [get_ports {seg[1]}]; # CF
set_property PACKAGE_PIN L18 [get_ports {seg[0]}]; # CG
set_property PACKAGE_PIN H15 [get_ports {dp}];
set_property IOSTANDARD LVCMOS33 [get_ports {seg[*] dp}]

# -----------------------------------------------
# Seven-segment anodes AN7..AN0 (active-low)
# -----------------------------------------------
set_property PACKAGE_PIN J17 [get_ports {an[0]}];
set_property PACKAGE_PIN J18 [get_ports {an[1]}];
set_property PACKAGE_PIN T9  [get_ports {an[2]}];
set_property PACKAGE_PIN J14 [get_ports {an[3]}];
set_property PACKAGE_PIN P14 [get_ports {an[4]}];
set_property PACKAGE_PIN T14 [get_ports {an[5]}];
set_property PACKAGE_PIN K2  [get_ports {an[6]}];
set_property PACKAGE_PIN U13 [get_ports {an[7]}];
set_property IOSTANDARD LVCMOS33 [get_ports {an[*]}]

# -----------------------------------------------
# RGB LEDs
# -----------------------------------------------
set_property -dict { PACKAGE_PIN N15 IOSTANDARD LVCMOS33 } [get_ports {led16_r}];
set_property -dict { PACKAGE_PIN M16 IOSTANDARD LVCMOS33 } [get_ports {led16_g}];
set_property -dict { PACKAGE_PIN R12 IOSTANDARD LVCMOS33 } [get_ports {led16_b}];

# -----------------------------------------------
## Pmod Header JA
# -----------------------------------------------
set_property -dict { PACKAGE_PIN C17   IOSTANDARD LVCMOS33 } [get_ports { heat_en }]; #Sch=ja[1]
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { cool_en }]; #Sch=ja[2]
