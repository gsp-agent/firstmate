#!/usr/bin/env python3
import os,sys,json,subprocess,time
args=sys.argv[1:]; real=os.environ['LIVE_REAL_GH']
allowed=(args[:2]==['pr','view']) or (args[:1]==['api'] and not any(x in args for x in ['POST','PUT','PATCH','DELETE']) and not any('mutation' in x for x in args))
if not allowed:
 print('live validation refuses remote mutation',file=sys.stderr); sys.exit(95)
auth=subprocess.run([real,'auth','token','--user','gsp-agent'],capture_output=True,text=True)
if auth.returncode: print('gsp-agent login unavailable',file=sys.stderr); sys.exit(96)
env=os.environ.copy(); env['GH_TOKEN']=auth.stdout.strip()
if os.environ.get('LIVE_GH_START_TRACE'):
 with open(os.environ['LIVE_GH_START_TRACE'],'a') as f: f.write(json.dumps({'time':time.time(),'args':args})+'\n')
r=subprocess.run([real]+args,env=env,capture_output=True,text=True)
with open(os.environ['LIVE_GH_TRACE'],'a') as f: f.write(json.dumps({'time':time.time(),'args':args,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})+'\n')
if os.environ.get('LIVE_BATCH_NOTIFY') and any('FmPollBatch' in a for a in args):
 with open(os.environ['LIVE_BATCH_NOTIFY'],'w') as f: f.write(str(time.time())+'\n')
sys.stdout.write(r.stdout); sys.stderr.write(r.stderr); sys.exit(r.returncode)
