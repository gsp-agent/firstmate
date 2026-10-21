from pathlib import Path
import os, subprocess, json, re
root=Path.cwd()
repo=root/'.drift-validation/history'
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5GAAXKM1WQPVVMRZQBTBDQ3')
env=os.environ.copy()
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Firstmate Tests',GIT_AUTHOR_EMAIL='tests@example.invalid',GIT_COMMITTER_NAME='Firstmate Tests',GIT_COMMITTER_EMAIL='tests@example.invalid',TMPDIR=str(root/'.drift-validation/tmp'))
def git(*args,input=None):
    return subprocess.run(['git','-C',str(repo),*args],env=env,input=input,text=True,capture_output=True,check=True).stdout.strip()
base=git('rev-parse','97a45e03')
upstream=git('rev-parse','3847411b')
target='9c2d987b9081e00898efafe2bba82e2eb4edc42e'
git('update-ref','refs/heads/captured-upstream',upstream)
tree=git('rev-parse',target+'^{tree}')
squash=git('commit-tree',tree,'-p',base,input='fix: restore drift guard ancestry independence (#53)\n')
results=[]
for name,script,fork,proof,expected in [
    ('historical-sha-keyed-failure',root/'.drift-validation/sha-keyed.sh',base,None,2),
    ('captured-upstream-lean',root/'bin/fm-drift-nightly.sh',base,root/'drift-proof.txt',0),
    ('repair-squashed-as-pr-53',root/'bin/fm-drift-nightly.sh',squash,None,0),
]:
    cmd=['bash',str(script),'check','--no-fetch','--repo',str(repo),'--upstream','captured-upstream','--fork',fork]
    if proof: cmd+=['--proof',str(proof)]
    result=subprocess.run(cmd,env=env,text=True,capture_output=True)
    counts={k:sum(line.startswith(k+': ') for line in result.stdout.splitlines()) for k in ['path-ok','path-drift','keep','pending','unproven','unmatched','error']}
    lines=result.stdout.splitlines()
    report={'scenario':name,'fork':fork,'upstream':upstream,'exit':result.returncode,'counts':counts,'behind':next((x for x in lines if x.startswith('behind: ')),None),'ahead':next((x for x in lines if x.startswith('ahead: ')),None)}
    (evidence/(name+'.log')).write_text('$ '+' '.join(cmd)+'\n'+result.stdout+result.stderr+'\nObserved exit: '+str(result.returncode)+'\n'+json.dumps(report,indent=2)+'\n')
    print(json.dumps(report),flush=True)
    assert result.returncode==expected,(name,result.stderr)
    if expected==0:
        assert counts['path-drift']==0 and counts['pending']==77,report
        for pr in [8,11,12,16,17,18,22,36,38,43,47,50,49,54,44,45,58,59,60,51,64,67,69,66,76]:
            fp=git('log','--first-parent','--format=%H %s',upstream+'..'+fork).splitlines()
            matching=[]
            for line in fp:
                sha,subject=line.split(' ',1)
                match=re.search(r'^(?:Merge pull request #|Merge PR #?)([0-9]+)|\(#([0-9]+)\)$',subject)
                if match and int(match.group(1) or match.group(2))==pr: matching.append(sha)
            assert matching,('missing numbered PR',pr)
            for sha in matching:
                assert any(line.startswith('pending: '+sha+' .agent-config-dtjsb ') for line in lines),(pr,sha)
        assert any(line.startswith('keep: ') and '(#25)' in line for line in lines),'PR 25 must stay keep'
    if name=='repair-squashed-as-pr-53':
        assert counts['unmatched']==0 and counts['unproven']==0 and counts['keep']==27,report
        assert any(line.startswith('keep: '+squash+' ') for line in lines),'repair squash must keep itself'
    results.append(report)
(evidence/'history-results.json').write_text(json.dumps(results,indent=2)+'\n')
