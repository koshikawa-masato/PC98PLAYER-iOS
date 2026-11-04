#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
device=${1:?Usage: tools/test_content_filter_simulator.sh DEVICE_UDID}
bundle=${IOS_BUNDLE_ID:-jp.pc98player.ios}
app=${IOS_BUILD_ROOT:-build}/ios-iphonesimulator/Debug-iphonesimulator/PC98PLAYERiOS.app
xcrun simctl install "$device" "$app"
container=$(xcrun simctl get_app_container "$device" "$bundle" data)
# Remove only this diagnostic's disposable outputs.
rm -f "$container/Documents/content-filter-smoke.json"
xcrun simctl launch --terminate-running-process "$device" "$bundle" --demo --content-filter-smoke -PC98BossMode NO -PC98AdultFilter NO -PC98HarmFilter NO
attempt=0
while [ ! -f "$container/Documents/content-filter-smoke.json" ]; do
  attempt=$((attempt+1))
  if [ "$attempt" -ge 180 ]; then echo 'Timed out waiting for Core ML / Metal smoke checks.' >&2;exit 1;fi
  sleep 1
done
output="out/content-filter/$device"
mkdir -p "$output"
cp "$container/Documents/content-filter-smoke.json" "$output/result.json"
cp "$container/Documents/content-filter-preview.png" "$output/preview.png"
python3 - "$output/result.json" <<'PY'
import sys,json
r=json.load(open(sys.argv[1]));print(json.dumps(r,indent=2))
if not r.get('passed'):raise SystemExit(1)
PY
