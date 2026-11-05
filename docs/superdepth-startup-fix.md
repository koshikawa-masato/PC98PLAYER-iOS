# SuperDepth startup path fix

The iOS executable picker supplied `aa3558f/DEPTH.EXE`. The shell's command tokenizer treats `/` as the start of an option, so this was resolved as `\aa3558f` and failed with `Bad command or file name` before the game executable loaded.

At the Apple frontend boundary, `apple/StartupPath.h` converts host separators in the executable token to DOS backslashes. Both macOS and iOS call it immediately before `Player::init`, covering INI values, selected programs and macOS startup overrides. Inline slash switches and the separate `cfg.args` field are preserved. The DOS shell in `core/dos.cpp` is restored byte-for-byte to the pre-fix upstream version. No Windows frontend, BIOS or ROM changes are involved.

Initial validation on 2026-11-05 (0.2.1 build 10, before moving normalization to the Apple boundary):

- Before the change, the synthetic nested-start regression failed with `[shell] 見つかりません: \aa3558f`.
- After the change, all 12 combinations of EXE/COM/BAT, host/DOS separators, and save-overlay enabled/disabled passed. Each opens sibling data relative to the guest current directory and checks that `/Q` reaches the PSP command tail unchanged.
- Native CTest: 8/8 passed with ymfm enabled.
- Debug iOS simulator build: succeeded, verification-only bundle ID `jp.pc98player.ios.startpath`, build 9. This does not replace the installed production bundle.
- User-provided `DEPTH100.LZH` (Super Depth 1.00): extracted only into a temporary test directory. Started with `Start=aa3558f/DEPTH.EXE`. Title and in-game screen observed in the shared-core harness. The actual iPhone 17 iOS 27.0 simulator app advanced 1,800 guest frames with Return input, guestQuit=0, 16-color mode, framebuffer 640x400, 14 visible colors, generated PCM peak 2457. In-game screen visually verified.
- This is startup and early gameplay verification, not a full-game completion or physical-device test. Audio samples were checked numerically; listening quality was not assessed.

Temporary workaround for App Store 0.2.0: select the folder that directly contains `DEPTH.EXE`, rather than its parent. Keep all sibling game data in that folder.

Game archives, game binaries, and copyrighted game screenshots are not included in this commit. The initially supplied `finalty.lzh` is the separate sequel Super Depth 2 Finalty; no compatibility claim for that title is made here.

Version 0.2.1 build 10, containing the initial core-side fix, was submitted to App Review on 2026-11-05. Moving normalization to the Apple boundary is a source refactor for a subsequent build; it does not replace or withdraw that submission.

## Apple boundary refactor

The regression test now passes each startup selection through the same Apple helper used by the app, then runs the unmodified core. Tests also cover empty boot-mode Start, inline slash switches, argument paths, tab-delimited text, and CP932 path bytes. The helper is identical in the Mac and iOS repositories.

Validation after refactoring (2026-11-05): Mac Universal build includes arm64 and x86_64; Mac CTest 5/5, iOS repository native CTest 8/8. The Mac app started `aa3558f/DEPTH.EXE` and displayed the SuperDepth title after 650 frames. The iPhone 17 simulator app built with Xcode 27.2 advanced 2,100 guest frames into gameplay (guestQuit=0, 15 visible colors, generated PCM peak 2457). This is early-game verification, not a full-game or physical-device test. No store submission was changed.
