#!/usr/bin/env python3
"""Validate a clean release build and create standalone Mac archives + checksums."""
import hashlib,json,os,plistlib,subprocess,tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
def run(*args):
    return subprocess.check_output(args,cwd=ROOT,text=True,timeout=30).strip()
def main():
    os.chdir(ROOT)
    app=ROOT/'dist/Desktop Deck.app';contents=app/'Contents'
    info=plistlib.loads((contents/'Info.plist').read_bytes());version=info['CFBundleShortVersionString']
    if run('git','status','--porcelain'):raise SystemExit('Commit source changes before packaging a release')
    commit=run('git','rev-parse','HEAD')
    receipt=json.loads((contents/'Resources/dependencies.json').read_text())
    if receipt.get('application',{}).get('commit')!=commit or receipt['application'].get('dirty'):
        raise SystemExit('Rebuild release from the current clean commit before packaging')
    if receipt['application']['version']!=version:raise SystemExit('Application version does not match its build receipt')
    if receipt.get('native',{}).get('opensslLegacyProvider')!='built-in':
        raise SystemExit('Release needs the built-in OpenSSL legacy provider; rebuild using scripts/build.sh')
    print('[1/4] Validating signature, architecture, dependencies and private build paths',flush=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,timeout=30)
    for binary in (contents/'MacOS').iterdir():
        if run('lipo','-archs',str(binary))!='arm64':raise SystemExit('Unexpected release architecture')
        dependencies=run('otool','-L',str(binary)).splitlines()[1:]
        if any(not line.strip().startswith(('/System/Library/','/usr/lib/')) for line in dependencies):
            raise SystemExit('Release has a non-system dynamic library dependency')
    for path in app.rglob('*'):
        if path.is_symlink():raise SystemExit('Unexpected symlink in the app bundle')
        if not path.is_file():continue
        if path.name in {'workspace.json','control.sock'} or path.suffix in {'.log','.pem','.key','.p12','.pfx'}:
            raise SystemExit('Personal or diagnostic artifact in the app bundle')
        data=path.read_bytes()
        if b'/opt/homebrew/' in data or b'/usr/local/opt/openssl' in data:
            raise SystemExit('Homebrew runtime path remains in '+str(path.relative_to(app)))
        if str(Path.home()).encode() in data or str(ROOT).encode() in data:
            raise SystemExit('Local build path remains in '+str(path.relative_to(app)))
    output=ROOT/'dist/release';output.mkdir(exist_ok=True)
    prefix=f'Desktop-Deck-{version}-macOS-arm64'
    zip_path=output/(prefix+'.zip');dmg_path=output/(prefix+'.dmg')
    if zip_path.exists() or dmg_path.exists():raise SystemExit('Release archives already exist; use a fresh version/output directory')
    print('[2/4] Creating standalone ZIP',flush=True)
    subprocess.run(['ditto','--norsrc','--noextattr','--noqtn','-c','-k','--keepParent',str(app),str(zip_path)],check=True,timeout=60)
    print('[3/4] Creating drag-to-install disk image',flush=True)
    with tempfile.TemporaryDirectory(prefix='desktop-deck-release-') as temporary:
        stage=Path(temporary)
        subprocess.run(['ditto','--norsrc','--noextattr','--noqtn',str(app),str(stage/app.name)],check=True,timeout=60)
        (stage/'Applications').symlink_to('/Applications',target_is_directory=True)
        (stage/'Read Me.txt').write_text(f'''Desktop Deck {version}

Requires Apple Silicon (M1 or later) and macOS {info['LSMinimumSystemVersion']} or later.
Drag Desktop Deck.app into Applications, eject this disk and open the installed app.
No Xcode, Homebrew or build step is required.

This build is ad-hoc signed and is not notarized by Apple.
If macOS blocks the first launch, inspect the app/source and follow Apple's
Privacy & Security > Open Anyway flow for this app only:
https://support.apple.com/en-us/102445

Profiles start empty. Use your own SSH configuration or VNC connection details.
VNC passwords are stored in Keychain. Personal data is not bundled.

Source: https://github.com/pintar-team/desktop-deck/tree/{commit}
License: GPL-3.0-or-later; dependency notices are inside the app bundle.
''')
        subprocess.run(['hdiutil','create','-volname','Desktop Deck','-srcfolder',str(stage),'-format','UDZO','-o',str(dmg_path)],check=True,timeout=120)
    print('[4/4] Writing SHA-256 checksums and source manifest',flush=True)
    hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [zip_path,dmg_path]}
    manifest={'version':version,'commit':commit,'architecture':'arm64','minimumMacOS':info['LSMinimumSystemVersion'],'signing':'ad-hoc','notarized':False,'sha256':hashes,'dependencies':receipt}
    manifest_path=output/'release-manifest.json';manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
    hashes[manifest_path.name]=hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    (output/'SHA256SUMS.txt').write_text(''.join(f'{digest}  {name}\n' for name,digest in hashes.items()))
    print('Created '+str(output.relative_to(ROOT)),flush=True)
if __name__=='__main__':main()
