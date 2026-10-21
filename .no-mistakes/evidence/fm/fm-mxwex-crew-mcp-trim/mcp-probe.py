import json,sys,os
from pathlib import Path
log=Path(sys.argv[1])
with log.open('a') as f: f.write('started pid='+str(os.getpid())+'\n')
for line in sys.stdin:
    req=json.loads(line)
    with log.open('a') as f: f.write(req.get('method','unknown')+'\n')
    if 'id' not in req: continue
    method=req.get('method')
    if method=='initialize':
        result={'protocolVersion':'2024-11-05','capabilities':{'tools':{}},'serverInfo':{'name':'lab-probe','version':'1.0'}}
    elif method=='tools/list':
        result={'tools':[{'name':'probe','description':'Local lab probe','inputSchema':{'type':'object','properties':{}}}]}
    elif method=='ping': result={}
    else: result={}
    print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result}),flush=True)
