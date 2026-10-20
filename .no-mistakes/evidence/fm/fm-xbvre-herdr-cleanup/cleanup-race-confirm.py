import importlib.util, json, shutil
from pathlib import Path
E=Path('/Users/dalecarman/.no-mistakes/evidence/01M5BJC9DERBCXTG4TD2TYVSB4')
spec=importlib.util.spec_from_file_location('cleanup_lab',E/'cleanup-live-lib.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
lab=m.Lab('race-confirmation')
results=[]
try:
    lab.provision(); lab.anchor_create()
    baseline=lab.work/'baseline'
    shutil.copytree(m.ROOT/'bin',baseline/'bin')
    source=baseline/'bin/fm-herdr-session-cleanup.sh'
    source.write_text(m.run(['git','show','d3bc4c32^:bin/fm-herdr-session-cleanup.sh']).stdout)
    control=lab.create('parent-control')
    lab.cleanup('parent-control',source=source)
    assert not lab.present(control) and not lab.retained(control)
    m.log('parent control: unambiguous idle pane closes with original cleanup and current backend; no missing-library errors')
    for tag,implementation in [('current',None),('parent',source)]:
        f=lab.create('race-'+tag)
        lab.mutation.write_text(json.dumps([{'path':str(lab.journal_path('fm-'+f['id'])),'content':lab.content(f,id='fm-'+f['id'])}]))
        before=lab.snapshot(tag+'-before')
        lab.cleanup(tag+'-race',source=implementation)
        after=lab.snapshot(tag+'-after')
        item={'implementation':tag,'pane':f['pane'],'candidate_retained':lab.present(f),'original_journal_retained':lab.retained(f),'late_duplicate_journal_retained':lab.journal_path('fm-'+f['id']).exists(),'focus_preserved':before['focused_pane_id']==after['focused_pane_id']}
        assert lab.mutation.with_suffix('.applied').exists()
        results.append(item); m.log('race confirmation: '+json.dumps(item))
    assert results[0]['candidate_retained'] is False
    assert results[0]['original_journal_retained'] is False
    assert results[1]['candidate_retained'] is True
    assert results[1]['original_journal_retained'] is True
    for kind in ['journal-change','metadata-appears']:
        f=lab.create(kind)
        path=lab.journal_path(kind) if kind=='journal-change' else lab.home/'state'/(kind+'.meta')
        content=lab.content(f,token='ZmVkY2JhOTg3NjU0MzIxMA') if kind=='journal-change' else 'now-owned\n'
        lab.mutation.write_text(json.dumps([{'path':str(path),'content':content}]))
        lab.snapshot(kind+'-before'); lab.cleanup(kind); lab.snapshot(kind+'-after')
        assert lab.present(f) and lab.retained(f)
        output=(E/(lab.label+'-'+kind+'-output.log')).read_text()
        assert 'immediate revalidation changed or was unreadable' in output
        item={'guard':kind,'candidate_retained':True,'journal_retained':True,'immediate_revalidation_refused':True}
        results.append(item); m.log('immediate revalidation: '+json.dumps(item))
finally:
    lab.teardown()
(E/'cleanup-race-confirmation.json').write_text(json.dumps(results,indent=2)+'\n')
print('CONFIRMED: batch cleanup loses the late duplicate-journal guard; parent preserves it.',flush=True)
