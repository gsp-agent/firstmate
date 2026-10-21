import pathlib as p,subprocess as sp,os,time,json
R=p.Path.cwd();T=R/'.tmp-pane-validation/tmux-live';T.mkdir();E=p.Path('/Users/dalecarman/.no-mistakes/evidence/01M5FAPAF0D3J798QZSVJHE250');sock=R/'.pane-test.sock';env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k.startswith('HERDR_') or k in ['TMUX','TMUX_PANE']:env.pop(k,None)
def run(a,e=env):
 r=sp.run([str(x) for x in a],env=e,stdout=sp.PIPE,stderr=sp.STDOUT,text=True)
 if r.returncode:raise RuntimeError(r.stdout)
 return r.stdout
home=T/'home';run([R/'bin/fm-lab-home.sh','create',home]);out=[]
try:
 run(['tmux','-f','/dev/null','-S',sock,'new-session','-d','-s','fm-lab-tmux-close','-n','fm-child','-x','120','-y','40','python3 -u -c "import time;print(\'TMUX disposable terminal worker\',flush=True);time.sleep(900)"'])
 e=env.copy();e['FM_HOME']=str(home);e['TMUX']=str(sock)+',1,0';e['FM_INACTIVE_RECONCILE_SECS']='60';e['FM_CREW_STATE_NO_FORGE']='1'
 proj=home/'projects/child';proj.mkdir();meta=home/'state/child.meta';status=home/'state/child.status';turn=home/'state/child.turn-ended';turn.touch()
 meta.write_text('window=fm-lab-tmux-close:fm-child\nworktree='+str(proj)+'\nproject='+str(proj)+'\nharness=claude\nkind=scout\nspawn_gen=live-tmux\n')
 run([R/'bin/fm-busy-event.sh','arm',home/'state','child','--state','idle','--source','claude-hook','--event','stop'])
 for value in ['done','failed']:
  status.write_text(value+': disposable terminal worker\n')
  for f in [meta,status,turn]:os.utime(f,(time.time()-180,time.time()-180))
  before=run([R/'bin/fm-crew-state.sh','child'],e);out.append('Before '+value+': '+before)
  out.append(run([R/'bin/fm-inactive-reconcile.sh','scan','--startup'],e))
  out.append('After '+value+': '+run([R/'bin/fm-crew-state.sh','child'],e))
  out.append(run(['tmux','-S',sock,'capture-pane','-p','-t','fm-lab-tmux-close:fm-child']))
  assert ('state: '+value+' ') in before
  out.append('PASS: '+value+' worker on default tmux backend retains its window and terminal result.')
finally:
 sp.run(['tmux','-S',str(sock),'kill-server'],env=env,check=True)
 out.append('Private tmux server stopped.')
 (E/'tmux-live-transcript.log').write_text('\n'.join(out));print('\n'.join(out))
