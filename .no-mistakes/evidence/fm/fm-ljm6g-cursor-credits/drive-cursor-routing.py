import json, os, pathlib, subprocess, time
root=pathlib.Path.cwd()
work=root/'.nm-cursor-validation'
evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M53WX9PNT9DXYF8YG54FS32N')
for d in ('state','config','usage','pstack/.cursor-plugin'):
    (work/d).mkdir(parents=True,exist_ok=True)
env=os.environ.copy()
for k in ('FM_ROOT_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE'):
    env.pop(k,None)
env.update(FM_HOME=str(work),FM_STATE_OVERRIDE=str(work/'state'),FM_CONFIG_OVERRIDE=str(work/'config'),FM_CURSOR_USAGE_DIR=str(work/'usage'),FM_PSTACK_DIR=str(work/'pstack'))
usage=work/'usage/live-spending.txt'
plugin=work/'pstack/.cursor-plugin/plugin.json'
config=work/'config/crew-dispatch.json'
def setup(pct=100,prepaid='0',used='400',limit='400',version='0.15.21',cfg=None):
    usage.write_text(f'cursor_models_pct={pct}\nprepaid_balance={prepaid}\nmonthly_additional_usage_used={used}\nmonthly_additional_usage_limit={limit}\n')
    plugin.write_text(json.dumps({'version':version}))
    config.write_text(json.dumps(cfg or {}))
def invoke(tool='bin/fm-cursor-guard.sh'):
    p=subprocess.run(['bash',tool,'fallback','credit-probe'],env=env,text=True,capture_output=True,timeout=10)
    assert p.returncode==0,(p.returncode,p.stderr)
    return p.stdout.strip()
rows=[]
def check(name,want,**kwargs):
    setup(**kwargs)
    got=invoke()
    expected=got==want
    rows.append({'scenario':name,'spending_file':usage.read_text(),'pstack':json.loads(plugin.read_text()),'config':json.loads(config.read_text()),'command':'bash bin/fm-cursor-guard.sh fallback credit-probe','stdout':got,'expected':want,'pass':expected})
    print(f'{name}: {got} [matches expected: {expected}]',flush=True)
    assert expected,(name,got,want)
no_room='codex Cursor Models at 100% (limit 85%) and no prepaid/on-demand credit room in live-spending.txt'
offpin="grok pstack plugin version is '0.15.22', not the pinned 0.15.21"
check('100 percent, prepaid only','cursor',prepaid='445.63')
check('100 percent, fractional prepaid only','cursor',prepaid='0.01')
check('100 percent, on-demand only','cursor',used='10')
check('100 percent, final cent on-demand','cursor',used='399.99')
check('100 percent, both credit sources','cursor',prepaid='445.63',used='138.38')
check('100 percent, exhausted credits',no_room)
check('100 percent, overrun and negative prepaid',no_room,prepaid='-1',used='401')
check('100 percent, zero additional limit',no_room,limit='0',used='0')
check('100 percent, missing credit fields',no_room,prepaid='',used='',limit='')
check('Prepaid credit does not bypass pstack pin',offpin,prepaid='445.63',version='0.15.22')
check('On-demand credit does not bypass pstack pin',offpin,used='10',version='0.15.22')
check('No credit room takes precedence over off-pin pstack',no_room,version='0.15.22')
check('Custom pstack pin remains authoritative','cursor',prepaid='445.63',version='0.15.22',cfg={'pstack_version':'0.15.22'})
check('Configured included-usage threshold with credits','cursor',pct=50,prepaid='0.01',cfg={'cursor_fallback':{'models_pct':50}})
check('Below threshold needs no credits','cursor',pct=84)
setup(prepaid='445.63')
marker=work/'state/credit-probe.cursor-limit'
marker.write_text('prior Cursor usage limit\n')
got=invoke()
rows.append({'scenario':'Recorded Cursor limit takes precedence over credit room','stdout':got,'pass':got=='codex prior Cursor usage limit'})
assert rows[-1]['pass']
marker.write_text('')
setup(prepaid='445.63')
os.utime(usage,(946684800,946684800))
got=invoke()
rows.append({'scenario':'Stale reading with prepaid credits is refused','stdout':got,'pass':got.startswith('codex newest Cursor spending file is ')})
assert rows[-1]['pass']
setup(prepaid='445.63')
# Execute historical product versions against identical serialized inputs.
for revision,version,want in [('67669705','0.15.21','codex Cursor Models at 100% (limit 85%)'),('ab7251f8','0.15.22','cursor')]:
    historical=work/f'guard-{revision}.sh'
    historical.write_bytes(subprocess.check_output(['git','show',f'{revision}:bin/fm-cursor-guard.sh']))
    setup(prepaid='445.63',version=version)
    got=invoke(str(historical))
    rows.append({'scenario':f'Historical counterfactual {revision}, pstack {version}','stdout':got,'expected':want,'pass':got==want})
    assert rows[-1]['pass']
    print(f'Historical {revision}, pstack {version}: {got}',flush=True)
(evidence/'cursor-routing-results.json').write_text(json.dumps(rows,indent=2)+'\n')
print(f'Validated {len(rows)} observed CLI cases; current checks and historical counterfactuals matched expectations.')
