#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${RUNNER_TEMP:?GitHub macOS runner required}"
: "${IOS_VERSION:?}" "${IOS_BUILD_NUMBER:?}"
for name in APPLE_DISTRIBUTION_P12_BASE64 APPLE_P12_PASSWORD APPSTORE_PROFILE_BASE64 ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY; do
  if [[ -z "${!name:-}" ]]; then echo "::error::Missing repository secret: $name"; exit 1; fi
done
signing_dir=$(mktemp -d "$RUNNER_TEMP/retrodos-signing.XXXXXX")
keychain="$signing_dir/signing.keychain-db"
keychain_password=$(openssl rand -hex 24)
profile_path=''
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  if [[ -n "$profile_path" ]]; then rm -f "$profile_path"; fi
  rm -rf "$signing_dir"
}
trap cleanup EXIT
export SIGNING_DIR="$signing_dir"
python3 - <<'PY'
import os,base64,pathlib
p=pathlib.Path(os.environ['SIGNING_DIR'])
(p/'distribution.p12').write_bytes(base64.b64decode(os.environ['APPLE_DISTRIBUTION_P12_BASE64'],validate=True))
(p/'app.mobileprovision').write_bytes(base64.b64decode(os.environ['APPSTORE_PROFILE_BASE64'],validate=True))
(p/'private_keys').mkdir()
(p/'private_keys'/('AuthKey_'+os.environ['ASC_KEY_ID']+'.p8')).write_text(os.environ['ASC_PRIVATE_KEY'])
PY
security cms -D -i "$signing_dir/app.mobileprovision" > "$signing_dir/profile.plist"
python3 - <<'PY'
import os,plistlib,pathlib,datetime,re
p=pathlib.Path(os.environ['SIGNING_DIR']);profile=plistlib.loads((p/'profile.plist').read_bytes())
team='8JN36X5T3B';bundle='jp.pc98player.ios'
assert profile['TeamIdentifier']==[team], 'Wrong Apple team'
assert profile['Entitlements']['application-identifier']==team+'.'+bundle, 'Wrong bundle identifier'
assert profile['ExpirationDate']>datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Expired profile'
assert not profile['Entitlements'].get('get-task-allow'), 'Distribution profile required'
assert not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'), 'App Store distribution profile required'
assert re.fullmatch(r'[A-Fa-f0-9-]+',profile['UUID']), 'Invalid profile UUID'
(p/'uuid').write_text(profile['UUID'])
plistlib.dump({'method':'app-store-connect','destination':'export','teamID':team,'signingStyle':'manual','signingCertificate':'Apple Distribution','provisioningProfiles':{bundle:profile['UUID']},'manageAppVersionAndBuildNumber':False,'uploadSymbols':True},(p/'ExportOptions.plist').open('wb'))
PY
profile_uuid=$(cat "$signing_dir/uuid")
profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profile_dir"
profile_path="$profile_dir/$profile_uuid.mobileprovision"
if [[ -e "$profile_path" ]]; then echo '::error::Refusing to replace an existing provisioning profile'; profile_path=''; exit 1; fi
cp "$signing_dir/app.mobileprovision" "$profile_path"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/distribution.p12" -k "$keychain" -P "$APPLE_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$keychain_password" "$keychain" >/dev/null
./tools/fetch_ymfm.sh
cmake -S . -B build/testflight -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_OSX_ARCHITECTURES=arm64 -DPC98PLAYER_IOS_SIGNING=ON -DPC98PLAYER_IOS_DEVELOPMENT_TEAM=8JN36X5T3B -DPC98PLAYER_IOS_VERSION="$IOS_VERSION" -DPC98PLAYER_IOS_BUILD="$IOS_BUILD_NUMBER" -DBUILD_TESTING=OFF
mkdir -p out/TestFlight
xcodebuild -project build/testflight/PC98PLAYER.xcodeproj -scheme PC98PLAYERiOS -configuration Release -destination 'generic/platform=iOS' -archivePath "$PWD/out/TestFlight/RetroDOS.xcarchive" archive CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Distribution' PROVISIONING_PROFILE_SPECIFIER="$profile_uuid" OTHER_CODE_SIGN_FLAGS="--keychain $keychain"
python3 - <<'CHECK_DSYM'
from pathlib import Path
import shutil,subprocess
archive=Path('out/TestFlight/RetroDOS.xcarchive')
binary=archive/'Products/Applications/PC98PLAYERiOS.app/PC98PLAYERiOS'
symbols=Path('build/testflight/Release-iphoneos/PC98PLAYERiOS.app.dSYM')
def uuid(path):return subprocess.check_output(['dwarfdump','--uuid',str(path)],text=True).split()[1]
assert uuid(binary)==uuid(symbols), 'Archive and dSYM UUID mismatch'
shutil.copytree(symbols,archive/'dSYMs'/symbols.name,dirs_exist_ok=True)
CHECK_DSYM
# Export uses the imported identity from this ephemeral runner's keychain list.
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
xcodebuild -exportArchive -archivePath "$PWD/out/TestFlight/RetroDOS.xcarchive" -exportPath "$PWD/out/TestFlight/export" -exportOptionsPlist "$signing_dir/ExportOptions.plist"
ipa=$(find "$PWD/out/TestFlight/export" -maxdepth 1 -name '*.ipa' -print -quit)
[[ -n "$ipa" ]] || { echo '::error::No IPA exported'; exit 1; }
API_PRIVATE_KEYS_DIR="$signing_dir/private_keys" xcrun altool --upload-app --type ios --file "$ipa" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo 'Uploaded to App Store Connect. Processing and TestFlight group assignment must still be confirmed.'
