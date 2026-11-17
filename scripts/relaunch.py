#!/usr/bin/env python3
"""Restart only this repository's app or its installed copy; never remote sessions."""
import os, signal, subprocess, time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
approved=[str(root/'dist/Desktop Deck.app/Contents/MacOS/DesktopDeck'),str(Path.home()/'Applications/Desktop Deck.app/Contents/MacOS/DesktopDeck')]
rows=subprocess.check_output(['/bin/ps','-axo','pid=,command='],text=True).splitlines()
owned=[]
for row in rows:
    parts=row.strip().split(None,1)
    if len(parts)==2 and any(parts[1]==path or parts[1].startswith(path+' ') for path in approved):owned.append(int(parts[0]))
if len(owned)>1:raise SystemExit('More than one app instance; finish isolated tests before restarting')
for pid in owned:
    os.kill(pid,signal.SIGTERM)
    end=time.monotonic()+15
    while time.monotonic()<end:
        try:os.kill(pid,0)
        except ProcessLookupError:break
        time.sleep(.1)
    else:raise SystemExit('App did not stop; refusing forced termination')
installed=Path.home()/'Applications/Desktop Deck.app'
subprocess.run(['/usr/bin/open',str(installed if installed.exists() else root/'dist/Desktop Deck.app')],check=True)
print('Restarted Desktop Deck; remote desktops were not stopped')
