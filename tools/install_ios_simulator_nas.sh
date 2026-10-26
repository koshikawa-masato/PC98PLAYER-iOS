#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
device=${1:?Usage: tools/install_ios_simulator_nas.sh DEVICE_UDID MOUNTED_NAS_GAMES_ROOT}
nas_root=${2:?Set the Mac-mounted NAS folder containing per-game PC98PLAYER.INI files}
case "$nas_root" in /*) ;; *) echo 'NAS path must be absolute' >&2; exit 2 ;; esac
[ -d "$nas_root" ] || { echo 'Mount the NAS share on the Mac first' >&2; exit 2; }
export IOS_SDK=iphonesimulator
: "${IOS_CONFIGURATION:=Release}"
export IOS_CONFIGURATION
./build_ios.sh
app="${IOS_BUILD_ROOT:-build}/ios-iphonesimulator/$IOS_CONFIGURATION-iphonesimulator/PC98PLAYERiOS.app"
xcrun simctl install "$device" "$app"
xcrun simctl launch --terminate-running-process "$device" "${IOS_BUNDLE_ID:-jp.pc98player.ios}" --simulator-nas-root "$nas_root"
