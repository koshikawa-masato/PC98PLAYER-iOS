"""Capture actual simulator displays in both orientations; never rotate a PNG.

iPhone: the app requests its own orientation (--store-portrait / --store-landscape).
iPad: iPadOS 26+ windowing refuses that request, so the simulated device itself is
rotated by the StoreOrientationUITests UI test (build with IOS_UI_TESTS=ON ./build_ios.sh).
"""
import json, os, pathlib, subprocess, time

FLAGS=['--demo','--layout-report','-PC98ManualDuo','NO','-PC98BossMode','NO','-PC98AdultFilter','NO','-PC98HarmFilter','NO']

def run(*args):
    return subprocess.check_output(args,text=True).strip()

def wait_for_layout(report,error,orientation,label,alive=lambda:True,timeout=180):
    """Wait until the app's layout report shows the requested orientation."""
    matched=0
    for _ in range(timeout):
        if error.exists():raise RuntimeError(error.read_text())
        if not alive():raise RuntimeError(f'Orientation helper exited early: {label}')
        try:
            layout=json.loads(report.read_text());w,h=layout['viewBounds'][2:]
            matched=matched+1 if (w>h)==(orientation=='landscape') and w>0 and h>0 else 0
            if matched>=3:return layout
        except (FileNotFoundError,json.JSONDecodeError):matched=0
        time.sleep(1)
    raise RuntimeError(f'Orientation not reached: {label}')

def main():
    devices=json.loads(run('xcrun','simctl','list','devices','available','-j'))['devices']
    available=[d for runtime,items in devices.items() if 'iOS' in runtime for d in items]
    bundle=os.environ.get('IOS_BUNDLE_ID','jp.pc98player.ios')
    build=pathlib.Path(os.environ.get('IOS_BUILD_ROOT','build'))/'ios-iphonesimulator'
    app=build/'Debug-iphonesimulator/PC98PLAYERiOS.app'
    out=pathlib.Path('out/app-store-screens');out.mkdir(parents=True,exist_ok=True)
    logs=pathlib.Path('out/app-store-screens-logs');logs.mkdir(parents=True,exist_ok=True)
    manifest=[]
    for family in ['iPhone','iPad']:
        choices=[d for d in available if d['name'].startswith(family) and 'Duo' not in d['name']]
        if not choices: raise RuntimeError(f'No {family} simulator installed')
        device=choices[0];udid=device['udid']
        if device['state']!='Booted':run('xcrun','simctl','boot',udid)
        run('xcrun','simctl','bootstatus',udid,'-b')
        run('xcrun','simctl','install',udid,str(app))
        run('xcrun','simctl','status_bar',udid,'override','--time','9:41','--batteryState','charged','--batteryLevel','100')
        container=pathlib.Path(run('xcrun','simctl','get_app_container',udid,bundle,'data'))/'Documents'
        report=container/'layout-report.json';error=container/'store-capture-error.txt'
        for orientation in ['portrait','landscape']:
            label=f'{family} {orientation}'
            output=out/f'{family.lower()}-{orientation}.png'
            report.unlink(missing_ok=True);error.unlink(missing_ok=True)
            subprocess.run(['xcrun','simctl','terminate',udid,bundle],capture_output=True)
            if family=='iPhone':
                # Each launch writes fresh layout evidence for the requested orientation.
                run('xcrun','simctl','launch','--terminate-running-process',udid,bundle,*FLAGS,'--store-'+orientation)
                layout=wait_for_layout(report,error,orientation,label)
                run('xcrun','simctl','io',udid,'screenshot',str(output))
            else:
                done=(logs/f'{family.lower()}-{orientation}.done').resolve();done.unlink(missing_ok=True)
                env=dict(os.environ,TEST_RUNNER_STORE_BUNDLE_ID=bundle,TEST_RUNNER_STORE_ORIENTATION=orientation,
                         TEST_RUNNER_STORE_LAUNCH_ARGUMENTS=' '.join(FLAGS),TEST_RUNNER_STORE_DONE_FILE=str(done))
                log=open(logs/f'{family.lower()}-{orientation}.log','w')
                helper=subprocess.Popen(['xcodebuild','test','-project',str(build/'PC98PLAYER.xcodeproj'),
                    '-scheme','PC98PLAYERiOSUITests','-configuration','Debug','-destination',f'id={udid}',
                    '-only-testing:PC98PLAYERiOSUITests/StoreOrientationUITests/testHoldStoreOrientation'],
                    env=env,stdout=log,stderr=subprocess.STDOUT)
                try:
                    layout=wait_for_layout(report,error,orientation,label,alive=lambda:helper.poll() is None,timeout=600)
                    time.sleep(2)  # let the rotation animation settle
                    run('xcrun','simctl','io',udid,'screenshot',str(output))
                finally:
                    done.touch()
                    try:helper.wait(timeout=180)
                    except subprocess.TimeoutExpired:helper.kill();helper.wait()
                    log.close()
                if helper.returncode!=0:
                    print((logs/f'{family.lower()}-{orientation}.log').read_text()[-4000:])
                    raise RuntimeError(f'Orientation UI test failed: {label}')
            manifest.append({'file':output.name,'device':device['name'],'orientation':orientation,'layout':layout})
        run('xcrun','simctl','status_bar',udid,'clear')
        run('xcrun','simctl','shutdown',udid)
    (out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
    print('Captured four real simulator screenshots; check App Store size requirements before uploading.')

if __name__=='__main__':main()
