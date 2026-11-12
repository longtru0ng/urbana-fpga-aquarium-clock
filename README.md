# FPGA Aquarium Clock 🐠

A colorful **pixel-art aquarium clock** built in **Verilog** for the **RealDigital Urbana (Spartan-7)** FPGA and a **3.2-inch ILI9341 SPI TFT**. Nine animated sea animals swim through a reef scene and pass in front of a configurable HH:MM clock. A rotary encoder adjusts the time, digit color, and background.

> **Project version:** V10.5 — natural swimming + performance-oriented partial redraws  
> **Build status:** Source checks and a Python motion model have been run. **Vivado implementation/timing and real-hardware testing of V10.5 are not yet verified.**

![Pixel-art aquarium scene mockup](assets/previews/screen_sprite_preview_2x.png)

*Static artwork preview from V10.4; not a screenshot of V10.5 running on the TFT.*

## Features

- **Nine detailed pixel-art animals:** dolphin, swordfish, killer whale, shrimp, sea turtle, crab, jellyfish, clownfish, and blue tang
- **Natural movement:** turns, pauses, small depth changes, and a clownfish/blue-tang pair that follows a shared route
- **Efficient partial updates:** redraw changed sprite areas rather than the entire 320×240 screen each tick
- **Animated environment:** slow grass movement, floating bubbles, and jellyfish tentacles
- **Customizable clock:** HH:MM time display, digit colors, and scene themes; fish can pass **in front of the digits**
- **Standalone operation:** after correctly flashing the configuration memory, the board can start from a USB power source

## Hardware

| Part | Purpose |
| --- | --- |
| RealDigital Urbana with Spartan-7 XC7S50 | FPGA development board |
| 3.2-inch 320×240 SPI TFT, ILI9341 | Aquarium display |
| Rotary encoder with button + slide switch | Clock and scene controls |
| Jumper wires and regulated USB power | Connections/power |

**All FPGA digital I/O is 3.3 V.** Do not connect 5 V signal levels to Pmod pins. Consult the TFT module documentation for its correct power and logic requirements.

### FPGA signals

| Signal | FPGA pin |
| --- | --- |
| 100 MHz clock | N15 |
| TFT CS | F14 |
| TFT DC | F15 |
| TFT RST | H13 |
| TFT MOSI | H14 |
| TFT SCK | J13 |
| Encoder A | H16 |
| Encoder B | H17 |
| Encoder button | K16 |
| Encoder switch | J16 |

See [`constraints/urbana_tft_clock.xdc`](constraints/urbana_tft_clock.xdc) for the complete pin map and input pull-ups.

## Project structure

```text
urbana-fpga-aquarium-clock/
├── rtl/urbana_tft_clock.v          # Verilog top module and SPI transmitter
├── constraints/urbana_tft_clock.xdc # Clock and FPGA pin constraints
├── assets/
│   ├── rom/reef_background.mem     # 160x120 RGB565 reef ROM
│   ├── rom/fish_sprites_4b.mem     # Indexed nine-animal sprite frames
│   └── previews/                  # Static artwork illustrations
├── tests/                          # Python source and movement sanity checks
├── docs/                           # Architecture, troubleshooting, asset notes
└── README.md
```

## Building with Vivado 2022.1

1. Create a **new RTL Project** and select the board's correct Spartan-7 part. On this design the previously used part was **XC7S50-CSGA324-2**; verify your particular board.
2. Add [`rtl/urbana_tft_clock.v`](rtl/urbana_tft_clock.v) as a design source; set **`urbana_tft_clock`** as the top module.
3. **Add both memory files as design sources**: `assets/rom/reef_background.mem` and `assets/rom/fish_sprites_4b.mem`. Vivado must find these names when it processes `$readmemh(...)`.
4. Add [`constraints/urbana_tft_clock.xdc`](constraints/urbana_tft_clock.xdc) as the only active pin constraints file.
5. Run **Synthesis → Implementation → Generate Bitstream**.
6. Open **Implemented Design → Timing Summary**. Check **WNS ≥ 0 ns**, **TNS = 0 ns**, and no critical timing errors. Inspect memory initialization warnings.
7. With the board plugged into the programming computer, test using **Hardware Manager → Program Device** (the `.bit` file). **Do not replace a known-working flash configuration until this test succeeds.**

If Vivado picks up old sprites, remove the prior `fish_sprites_4b.mem` from the project and add the new file. Be sure the project has only one active memory file with that filename.

## Using the clock

Press the rotary encoder button to cycle between **Run**, **Hour**, **Minute**, **Digit Color**, and **Background**. Turn the encoder to change the selected setting. The slide switch controls whether animation is enabled (polarity depends on the wired switch position).

The clock currently counts time from the FPGA system clock. **Time does not survive a power interruption.** A future version could use an external RTC module.

## Design notes

- FPGA system clock: **100 MHz**.
- ILI9341 SPI: **10 MHz** using `SPI_HALF_DIV=5`.
- Animation: **40 movement ticks/s target**, not a measured 40 displayed FPS.
- Background: **160×120 ROM upscaled 2×** to 320×240.
- Updated sprite regions use old/new bounds and skip updates for stationary sprites.
- Grass and bubbles update at a lower cadence than animal movement.

Read [the architecture notes](docs/ARCHITECTURE.md) for the display pipeline and [the troubleshooting guide](docs/TROUBLESHOOTING.md) if you encounter glitches or timing violations.

## Checks (Python)

```bash
python tests/validate_v10_5.py
python tests/simulate_motion_model.py
```

These are **not Verilog synthesis or hardware tests**. The modeled SPI traffic reduction is not a measured FPS increase.

## Artwork, reuse, and publishing

The image assets include reef imagery adapted from material supplied during development; redistributable rights have **not been verified**. See [asset and licensing notes](docs/ASSETS_AND_LICENSE.md) before making this repository public. **No open-source license is granted by this package.**

## Future improvements

- Measure actual TFT frame/update throughput on hardware.
- Reduce animation traffic further with dirty-region coalescing and controlled refresh rates.
- Add an RTC for accurate time across power cycles.
- Add optional alarms, sound effects, or touch controls.