# SuperDepth startup path fix

The iOS executable picker supplied `aa3558f/DEPTH.EXE`. The shell's command tokenizer treats `/` as the start of an option, so this was resolved as `\aa3558f` and failed with `Bad command or file name` before the game executable loaded.

At shell startup, normalize `/` to DOS `\` in the executable token only. Arguments retain slash switches. The existing startup-directory logic then finds both the executable and sibling game data. The interpreter's ordinary command/switch syntax is unchanged. No BIOS or ROM was added.

Validation on 2026-11-05:

- Before the change, the synthetic nested-start regression failed with `[shell] 見つかりません: \aa3558f`.
- After the change, all 12 combinations of EXE/COM/BAT, host/DOS separators, and save-overlay enabled/disabled passed. Each opens sibling data relative to the guest current directory and checks that `/Q` reaches the PSP command tail unchanged.
- Native CTest: 8/8 passed with ymfm enabled.
- Debug iOS simulator build: succeeded, verification-only bundle ID `jp.pc98player.ios.startpath`, build 9. This does not replace the installed production bundle.
- User-provided `DEPTH100.LZH` (Super Depth 1.00): extracted only into a temporary test directory. Started with `Start=aa3558f/DEPTH.EXE`. Title and in-game screen observed in the shared-core harness. The actual iPhone 17 iOS 27.0 simulator app advanced 1,800 guest frames with Return input, guestQuit=0, 16-color mode, framebuffer 640x400, 14 visible colors, generated PCM peak 2457. In-game screen visually verified.
- This is startup and early gameplay verification, not a full-game completion or physical-device test. Audio samples were checked numerically; listening quality was not assessed.

Temporary workaround for the current App Store build: select the folder that directly contains `DEPTH.EXE`, rather than its parent. Keep all sibling game data in that folder.

Game archives, game binaries, and copyrighted game screenshots are not included in this commit. The initially supplied `finalty.lzh` is the separate sequel Super Depth 2 Finalty; no compatibility claim for that title is made here.

No App Store/TestFlight upload or release has been made for this fix.
