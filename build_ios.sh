#!/bin/sh
set -eu
cd "$(dirname "$0")"
sdk=${IOS_SDK:-iphonesimulator}
configuration=${IOS_CONFIGURATION:-Debug}
case "$sdk" in iphonesimulator|iphoneos) ;; *) echo 'IOS_SDK must be iphonesimulator or iphoneos' >&2; exit 2 ;; esac
case "$configuration" in Debug|Release) ;; *) echo 'IOS_CONFIGURATION must be Debug or Release' >&2; exit 2 ;; esac
signing=OFF
if [ -n "${IOS_DEVELOPMENT_TEAM:-}" ] && [ "$sdk" = iphoneos ]; then signing=ON; fi
./tools/fetch_ymfm.sh
cmake -S . -B "build/ios-$sdk" -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DPC98PLAYER_IOS_SIGNING="$signing" \
  -DPC98PLAYER_IOS_BUNDLE_ID="${IOS_BUNDLE_ID:-jp.pc98player.ios}" \
  -DPC98PLAYER_IOS_DEVELOPMENT_TEAM="${IOS_DEVELOPMENT_TEAM:-}" \
  -DBUILD_TESTING=OFF
cmake --build "build/ios-$sdk" --config "$configuration" --parallel 4
