#!/usr/bin/env python3
"""Exercise the real CLI and stdio adapter without changing native windows."""
import json, pathlib, subprocess
root=pathlib.Path(__file__).resolve().parent.parent
import os
cli=pathlib.Path(os.environ['KOLOMCTL']) if os.environ.get('KOLOMCTL') else root/'build/Kolom.app/Contents/MacOS/kolomctl'
# The checks below send create-grid and close-terminals requests that must be
# refused. With local agent commands switched on they would really run.
session=pathlib.Path.home()/'Library/Application Support/Kolom/agent/session.json'
if session.exists():
    raise SystemExit('Turn off local agent commands in Kolom first: these checks must not reach a live session.')
def run(*args):
    return subprocess.run([str(cli),*args],capture_output=True,text=True,check=False)
help_result=run('help','layout','--json')
assert help_result.returncode==0
assert json.loads(help_result.stdout)['readOnly'] is True
plan=json.loads(run('plan-grid','--columns','6','--rows','5','--display','2').stdout)
assert plan['windowCount']==30 and plan['executable'] is False
assert plan['supportedByCurrentEngine'] is True
assert run('plan-grid','--columns','-1','--rows','5','--display','2').returncode==2
assert run('plan-grid','--columns','6','--rows','5','--display','2','--oops').returncode==2
messages=[
 {'jsonrpc':'2.0','id':0,'method':'tools/list'},
 {'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'test','version':'1'}}},
 {'jsonrpc':'2.0','method':'notifications/initialized'},
 {'jsonrpc':'2.0','id':2,'method':'tools/list'},
 {'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'kolom_plan_grid','arguments':{'columns':6,'rows':5,'display':2}}},
 {'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'kolom_plan_grid','arguments':{'columns':True,'rows':5,'display':2}}},
 {'jsonrpc':'2.0','id':5,'method':'tools/call','params':{'name':'kolom_help','arguments':{'topic':'layout','execute':'anything'}}},
 {'jsonrpc':'2.0','id':6,'method':'ping'},
]
p=subprocess.run([str(cli),'mcp'],input='\n'.join(map(json.dumps,messages))+'\n',text=True,capture_output=True,check=True)
replies={r['id']:r for r in map(json.loads,p.stdout.splitlines())}
assert len(replies)==7 and 'error' in replies[0]
assert replies[1]['result']['protocolVersion']=='2025-11-25'
assert {t['name'] for t in replies[2]['result']['tools']}=={'kolom_help','kolom_state','kolom_plan_grid','kolom_operation'}
assert all(t['annotations']['readOnlyHint'] for t in replies[2]['result']['tools'])
result=json.loads(replies[3]['result']['content'][0]['text'])
assert result['windowCount']==30 and result['executable'] is False
assert replies[4]['result']['isError'] and replies[5]['result']['isError']
assert replies[6]['result']=={}
denied=json.loads(run('create-grid','--columns','6','--rows','3','--display','3').stdout)
assert denied['ok'] is False
assert run('undo','not-a-uuid').returncode==2
assert run('close-terminals').returncode==2
assert run('close-terminals','--force').returncode==2
assert json.loads(run('close-terminals','--confirm').stdout)['ok'] is False
close_reject=[messages[1],messages[2],{'jsonrpc':'2.0','id':7,'method':'tools/call','params':{'name':'kolom_close_terminals','arguments':{'confirm':False}}}]
result=subprocess.run([str(cli),'mcp'],input='\n'.join(map(json.dumps,close_reject))+'\n',text=True,capture_output=True,check=True)
assert json.loads(result.stdout.splitlines()[-1])['result']['isError'] is True
print('PASS: CLI discovery/preview validation, JSON-RPC initialization, shared MCP schemas, read-only annotations, boolean and unknown-field rejection')
