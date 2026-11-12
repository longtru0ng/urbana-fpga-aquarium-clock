# Exact FPGA pin assignments from RealDigital Urbana Board Constraints V2I1.
# TFT connections are FPGA 3.3V outputs. Do NOT connect external 5V logic to pins.
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports CLK_100MHZ]
create_clock -name sys_clk -period 10.000 [get_ports CLK_100MHZ]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.Config.SPI_buswidth 4 [current_design]

# Connector signal names JA1_P etc use official RealDigital PMOD+ pin drawing.
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports tft_cs]    ;# JA1_P
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports tft_dc]    ;# JA1_N
set_property -dict {PACKAGE_PIN H13 IOSTANDARD LVCMOS33} [get_ports tft_rst]   ;# JA2_P
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33} [get_ports tft_mosi]  ;# JA2_N
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports tft_sck]   ;# JA3_P
# Rotary encoder on PmodB LEFT column, bottom to top H16,H17,K16,J16.
# Digilent PmodENC outputs: A, B, BTN, SWT (NOT GND).
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports enc_a]     ;# JB3_P
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports enc_b]     ;# JB3_N
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33} [get_ports enc_sw]    ;# JB4_P : BTN
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS33} [get_ports enc_swt]   ;# JB4_N : SWT slide switch
# Weak pullups for switches and quadrature signals.
set_property PULLUP true [get_ports {enc_a enc_b enc_sw enc_swt}]
