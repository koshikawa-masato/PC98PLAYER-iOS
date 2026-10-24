#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
device=${1:?Usage: IOS_DEVELOPMENT_TEAM=TEAM_ID tools/install_ios_device.sh DEVICE_UDID}
: "${IOS_DEVELOPMENT_TEAM:?Set IOS_DEVELOPMENT_TEAM to your Apple development team ID}"
export IOS_SDK=iphoneos
./build_ios.sh
configuration=${IOS_CONFIGURATION:-Debug}
app="build/ios-iphoneos/$configuration-iphoneos/PC98PLAYERiOS.app"
xcrun devicectl device install app --device "$device" "$app" --timeout 30
xcrun devicectl device process launch --device "$device" "${IOS_BUNDLE_ID:-jp.pc98player.ios}" --timeout 30
