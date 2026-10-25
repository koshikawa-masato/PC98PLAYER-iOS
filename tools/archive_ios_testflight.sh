#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export IOS_SDK=iphoneos IOS_CONFIGURATION=Release
: "${IOS_DEVELOPMENT_TEAM:=8JN36X5T3B}"
export IOS_DEVELOPMENT_TEAM
./build_ios.sh
archive="$PWD/out/TestFlight/PC98PLAYER-${IOS_VERSION:-0.2.0}-${IOS_BUILD_NUMBER:-3}.xcarchive"
xcodebuild -project build/ios-iphoneos/PC98PLAYER.xcodeproj -scheme PC98PLAYERiOS \
  -configuration Release -destination 'generic/platform=iOS' -archivePath "$archive" archive
# CMake puts dSYMs in its configured product directory. Verify before collecting them.
python3 - "$archive" <<'PYTHON'
from pathlib import Path
import shutil, subprocess, sys
archive=Path(sys.argv[1])
app=archive/'Products/Applications/PC98PLAYERiOS.app/PC98PLAYERiOS'
symbols=Path('build/ios-iphoneos/Release-iphoneos/PC98PLAYERiOS.app.dSYM')
def uuid(path):
    return subprocess.check_output(['dwarfdump','--uuid',str(path)],text=True).split()[1]
if uuid(app)!=uuid(symbols):
    raise SystemExit('Archive and dSYM UUIDs differ')
shutil.copytree(symbols,archive/'dSYMs'/symbols.name,dirs_exist_ok=True)
PYTHON
xcodebuild -exportArchive -archivePath "$archive" -exportPath out/TestFlight/export \
  -exportOptionsPlist ios/ExportOptions-TestFlight.plist
printf '\nIPA: %s/out/TestFlight/export/PC98PLAYER.ipa\n' "$PWD"
