#!/usr/bin/env python3
"""Print dependency identities; contains no personal endpoint configuration."""
import json, subprocess, os
from pathlib import Path
def command(args):return subprocess.check_output(args,text=True).strip()
result={'source':{},'swiftPackages':json.loads(Path('Package.resolved').read_text())['pins']}
for path in ['Vendor/LibVNCServer','Vendor/TurboVNC']:
    result['source'][path]=command(['git','-C',path,'rev-parse','HEAD'])
result['native']={name:Path(os.environ.get(variable,default)).resolve().name for name,variable,default in [('jpeg-turbo','JPEG_PREFIX','/opt/homebrew/opt/jpeg-turbo'),('openssl','OPENSSL_PREFIX','/opt/homebrew/opt/openssl@3')]}
print(json.dumps(result,indent=2))
