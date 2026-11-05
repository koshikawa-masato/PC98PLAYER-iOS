#!/usr/bin/env python3
"""Build a reproducible, original DOS practice ZIP. No game/ROM/BIOS required."""
# SPDX-License-Identifier: MIT
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parent
CODE = bytes.fromhex('BA1301 B409 CD21 B408 CD21 B402 88C2 CD21 EBF4')
assert len(CODE) == 0x13
FILES = {
    'PC98PLAYER.INI': b'[PC98PLAYER]\r\nTitle=Tutorial Demo\r\nStart=START.COM\r\nMIDI=0\r\nRhythmROM=0\r\n',
    'START.COM': CODE + b'RetroDOS Player - Transfer Demo\r\n\r\nTransfer completed!\r\nTap letter keys below.\r\n$',
    'README.txt': b'Original transfer-practice demo for RetroDOS Player. MIT license.\r\nOpen the folder containing PC98PLAYER.INI and START.COM.\r\nThis is not a game, BIOS or ROM.\r\n',
}
with ZipFile(ROOT / 'RetroDOS-Tutorial-Demo.zip', 'w') as archive:
    for name, data in sorted(FILES.items()):
        entry = ZipInfo('RetroDOS-Demo/' + name, date_time=(2026, 11, 5, 0, 0, 0))
        entry.compress_type = ZIP_DEFLATED
        entry.external_attr = 0o100644 << 16
        archive.writestr(entry, data)
print(ROOT / 'RetroDOS-Tutorial-Demo.zip')
