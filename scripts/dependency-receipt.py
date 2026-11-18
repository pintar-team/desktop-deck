#!/usr/bin/env python3
"""Print dependency identities; contains no personal endpoint configuration."""
import json, subprocess, os, plistlib
from pathlib import Path
def command(args):return subprocess.check_output(args,text=True).strip()
result={'source':{},'swiftPackages':json.loads(Path('Package.resolved').read_text())['pins']}
result['application']={'version':plistlib.loads(Path('Resources/Info.plist').read_bytes())['CFBundleShortVersionString'],'commit':command(['git','rev-parse','HEAD']),'dirty':bool(command(['git','status','--porcelain'])),'sourceURL':'https://github.com/pintar-team/desktop-deck'}
for path in ['Vendor/LibVNCServer','Vendor/TurboVNC']:
    result['source'][path]=command(['git','-C',path,'rev-parse','HEAD'])
openssl=Path(os.environ['OPENSSL_PREFIX'])
result['native']={
    'jpeg-turbo':Path(os.environ['JPEG_PREFIX']).resolve().name,
    'openssl':openssl.name,
    'opensslSourceSHA256':(openssl/'source.sha256').read_text().strip(),
    'opensslLegacyProvider':'built-in',
}
print(json.dumps(result,indent=2))
