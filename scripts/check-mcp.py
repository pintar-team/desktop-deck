#!/usr/bin/env python3
"""Bounded protocol smoke test. Does not start model turns or send remote input."""
import json, os, selectors, socket, subprocess, sys, time
from pathlib import Path
binary=Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parents[1]/'dist/Desktop Deck.app/Contents/MacOS/desktop-deck-mcp'
control=Path(os.environ.get('DECK_STATE_DIR',str(Path.home()/'Library/Application Support/DesktopDeck')))/'control.sock'
deadline=time.monotonic()+10
while time.monotonic()<deadline:
    try:
        with socket.socket(socket.AF_UNIX) as probe:
            probe.settimeout(.2);probe.connect(str(control))
        break
    except OSError:time.sleep(.1)
p=subprocess.Popen([str(binary)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
poll=selectors.DefaultSelector();poll.register(p.stdout,selectors.EVENT_READ)
def send(value):
    p.stdin.write(json.dumps(value)+'\n');p.stdin.flush()
def result(wanted):
    end=time.monotonic()+40
    while time.monotonic()<end:
        if not poll.select(max(0,end-time.monotonic())):break
        line=p.stdout.readline()
        if not line:break
        value=json.loads(line)
        if value.get('id')==wanted:return value
    raise RuntimeError(f'MCP response {wanted} timed out')
try:
    send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'desktop-deck-smoke','version':'1'}}})
    init=result(1);assert 'result' in init,init
    send({'jsonrpc':'2.0','method':'notifications/initialized'})
    send({'jsonrpc':'2.0','id':2,'method':'tools/list','params':{}})
    tools=result(2)['result']['tools'];assert len(tools)==16,len(tools)
    send({'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'connections_list','arguments':{}}})
    call=result(3)['result'];assert not call.get('isError'),call
    profiles=json.loads(call['content'][-1]['text'])['profiles']
    print(json.dumps({'initialize':'PASS','tools':len(tools),'profiles':len(profiles),'connected':sum(x['state']=='Connected' for x in profiles)}))
finally:
    p.stdin.close()
    try:p.wait(timeout=3)
    except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=3)
