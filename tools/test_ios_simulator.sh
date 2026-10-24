#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
bundle=${IOS_BUNDLE_ID:-jp.pc98player.ios}
device=${1:?Usage: tools/test_ios_simulator.sh DEVICE_UDID}
app=build/ios-iphonesimulator/Debug-iphonesimulator/PC98PLAYERiOS.app
if [ ! -d "$app" ]; then
  printf 'Build the Debug simulator app with ./build_ios.sh first.\n' >&2
  exit 1
fi
xcrun simctl install "$device" "$app"
container=$(xcrun simctl get_app_container "$device" "$bundle" data)
xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || true
# These are generated test artifacts belonging to this app, not game data.
rm -f "$container/Documents/smoke-result.json" "$container/Documents/duo-smoke.png"
xcrun simctl launch "$device" "$bundle" --smoke-test
attempt=0
while [ ! -f "$container/Documents/smoke-result.json" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    printf 'Timed out waiting for iOS smoke test.\n' >&2
    exit 1
  fi
  sleep 1
done
mkdir -p out/ios-smoke
cp "$container/Documents/smoke-result.json" out/ios-smoke/result.json
cp "$container/Documents/duo-smoke.png" out/ios-smoke/duo.png
python3 - <<'PY'
import json
from pathlib import Path
result = json.loads(Path('out/ios-smoke/result.json').read_text())
print(json.dumps(result, indent=2))
if not result.get('passed'):
    raise SystemExit(1)
PY
