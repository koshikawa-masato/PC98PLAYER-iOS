# RetroDOS Player 0.2.1 (build 10)

## App Store release notes (Japanese)

サブフォルダ内のゲームを選んだとき、「Bad command or file name」と表示されて起動できない不具合を修正しました。

## Review note addition

This update fixes startup of user-selected executables in subfolders. The iOS document picker uses forward-slash relative paths, which previously collided with DOS switch parsing. The startup executable path is now normalized to DOS separators while preserving command-line arguments. No third-party game files, BIOS, or ROM are included. The built-in original DOS demo remains available through 場所 (Locations) > オリジナルDOSデモ (Original DOS demo). No sign-in is required.

## Validation

- CTest 8/8 with ymfm, including 12 nested EXE/COM/BAT startup cases.
- SuperDepth 1.00 verified through title and early gameplay in the iOS simulator; 1,800 frames, 16-color output, generated PCM. Not a complete-game or physical-device test.
- Source and build are independent of the experimental AI content-filter branch.

## Rollback

If review or testing exposes a release-blocking regression, withdraw 0.2.1 before release and retain the current 0.2.0 store version. Preserve existing app bundle ID and save-data paths. No save migration is part of this patch.
