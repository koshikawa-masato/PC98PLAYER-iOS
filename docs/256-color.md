# BIOS-free 256-color display

`VideoColors=256` exposes the PC-9821 extended-graphics capability through the existing HLE work area. Reset still starts in the ordinary display mode. Guest software selects its original 256-color driver and switches display mode through I/O. `VideoColors=16` is the default and keeps the old capability flags and rendering path.

The implementation is independently written for this project. No firmware images, other emulator code, or patched game executables are included. Register behavior was checked against the public hardware description at https://www.satotomi.com/sl9821/sl9821_tec5.html .

The current target is 640×400 banked packed-pixel graphics: 512 KiB of VRAM, two 32 KiB CPU windows, 256 RGB palette entries, and display pages. Basic planar CPU/latch transfers, plane/bit masks and ROP operations support the game's drawing path. Text uses the existing overlay. PEGC state is saved in an optional snapshot chunk; older snapshots remain readable.

This is not a complete PC-9821 hardware model. 480-line/31 kHz output, the high-address linear framebuffer, and advanced 32-bit planar shift/transfer behavior are not covered. N88-BASIC remains outside this feature.

Validation: the regression test checks palette readback, 256 distinct output colors, both VRAM windows and their boundary, page selection, planar masks/ROP, snapshot roundtrip and legacy snapshots. Existing 16-color/core/overlay tests also pass. Rance IV selects its bundled AGS_9821 driver without modification and reaches the opening game scene with extended graphics active. Full-game compatibility requires further play testing.

On iOS, the keyboard's Options button opens OPN (PC-9801-26) / OPNA (PC-9801-86) and 16 / 256 color choices. Applying the selection restarts the game, so the sheet explains that behavior. Preferences persist across app launches; NAS data and the save overlay retain their existing roles.

Physical-device check (2026-10-25): on S9Plus (iPhone 16 Pro Max), the Options sheet applied OPN + 16 colors and then OPNA + 256 colors. Rance IV reached an in-game dialogue with extended graphics active, 28 simultaneous framebuffer colors and nonzero OPNA audio output. This verifies startup and early play, not the entire game.
