"""Sanity check for V10.5 source/ROM files. Not a Vivado replacement."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
rtl = (root / "rtl" / "urbana_tft_clock.v").read_text()
xdc = (root / "constraints" / "urbana_tft_clock.xdc").read_text()

assert rtl.count("module urbana_tft_clock") == 1
assert rtl.count("module aquarium_spi_tx") == 1
assert "(* rom_style = \"block\" *) reg [3:0] fish_sprite_rom [0:36863];" in rtl
assert "if(sprite_valid) c = sprite_rgb;" in rtl
assert "R_FISH_LAST=11" in rtl and "R_GRASS=20" in rtl
assert "snap_animal_y[fish_probe]" in rtl
for name, length in [("reef_background.mem", 160*120),
                     ("fish_sprites_4b.mem", 9*2*64*32)]:
    vals = (root / "assets" / "rom" / name).read_text().splitlines()
    assert len(vals) == length, (name, len(vals), length)
    assert all(re.fullmatch("[0-9a-fA-F]+", s) for s in vals)
for pin in ("H16", "H17", "K16", "J16"):
    assert "PACKAGE_PIN " + pin in xdc
print("PASS: source, ROM depths, and encoder pins")
print("NOTE: run Vivado synthesis, implementation and hardware tests separately.")
