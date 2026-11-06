"""Capture actual simulator displays in both orientations; never rotate a PNG."""
import json, os, pathlib, subprocess, time

def run(*args):
    return subprocess.check_output(args,text=True).strip()

def main():
    devices=json.loads(run('xcrun','simctl','list','devices','available','-j'))['devices']
    available=[d for runtime,items in devices.items() if 'iOS' in runtime for d in items]
    bundle=os.environ.get('IOS_BUNDLE_ID','jp.pc98player.ios')
    app=pathlib.Path(os.environ.get('IOS_BUILD_ROOT','build'))/'ios-iphonesimulator/Debug-iphonesimulator/PC98PLAYERiOS.app'
    out=pathlib.Path('out/app-store-screens');out.mkdir(parents=True,exist_ok=True)
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
            # Each launch writes fresh layout evidence for the requested orientation.
            run('xcrun','simctl','terminate',udid,bundle) if orientation=='landscape' else None
            report.unlink(missing_ok=True);error.unlink(missing_ok=True)
            run('xcrun','simctl','launch','--terminate-running-process',udid,bundle,'--demo','--layout-report','--store-'+orientation,'-PC98ManualDuo','NO','-PC98BossMode','NO','-PC98AdultFilter','NO','-PC98HarmFilter','NO')
            for attempt in range(60):
                if error.exists():raise RuntimeError(error.read_text())
                try:
                    layout=json.loads(report.read_text());w,h=layout['viewBounds'][2:]
                    if (w>h)==(orientation=='landscape') and w>0 and h>0 and attempt>=3:break
                except (FileNotFoundError,json.JSONDecodeError):pass
                time.sleep(1)
            else:raise RuntimeError(f'Orientation not reached: {family} {orientation}')
            output=out/f'{family.lower()}-{orientation}.png'
            run('xcrun','simctl','io',udid,'screenshot',str(output))
            manifest.append({'file':output.name,'device':device['name'],'orientation':orientation,'layout':layout})
        run('xcrun','simctl','status_bar',udid,'clear')
        run('xcrun','simctl','shutdown',udid)
    (out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
    print('Captured four real simulator screenshots; check App Store size requirements before uploading.')

if __name__=='__main__':main()
