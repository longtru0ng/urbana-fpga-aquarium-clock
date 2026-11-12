# Architecture

## Data flow

```text
100 MHz FPGA clock
  ├── Timekeeping and rotary encoder inputs
  ├── Nine-animal position, direction, pause and grouping state
  ├── Grass and bubble animation state
  └── Dirty-region update scheduler
       ├── 160x120 RGB565 reef background ROM
       ├── 4-bit palette-indexed sprite ROM
       ├── HH:MM clock renderer
       ├── Scene compositor (animals above clock digits)
       └── ILI9341 10 MHz SPI transmitter → 320x240 TFT
```

The ROMs are loaded with Verilog `$readmemh`. Include both `.mem` files in Vivado.

V10.5 separates animal motion from SPI transmission. Unchanged animals do not require a redraw. When an animal moves, redraw the combined old/new rectangle; refresh vegetation and bubbles less often.

This is a 100 MHz digital design with a relatively slow SPI display. 40 movement ticks/s is not equivalent to 40 achieved screen frames/s. Check post-implementation WNS/TNS, verify the memory contents and measure actual display throughput on hardware.

V10.5 has not been synthesized or validated on physical hardware in this repository.
