# Troubleshooting

## Colored stripes or frozen display
Check Vivado **Implemented Design → Timing Summary**. A negative WNS indicates failed setup timing. Do not overwrite a known-working flash image until timing closes and the display has been tested.

## Missing fish or wrong reef colors
Ensure `reef_background.mem` and `fish_sprites_4b.mem` are added to the project as design sources, at the exact filenames referenced by `$readmemh`. Avoid duplicate older files.

## Powering without a laptop
A JTAG-loaded `.bit` is temporary. Generate the correct flash `.mcs`, program and verify the configuration memory, then boot from flash. Previously verified board setup: J14 installed, J16 set to USB. Disconnect power before adjusting jumpers, use a regulated 5 V USB charger, and check DONE.

## Animation appears frozen
Check the encoder slide-switch state and inspect the frame tick counter. The frame tick is not equal to achieved TFT FPS.

## Time resets on power loss
The current design has no battery-backed RTC. Set the time after power cycling, or add a DS3231 RTC in a later version.
