from pathlib import Path

base=Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH')
out=base/'round2'
for name in ['process-tree-live.py','status-counterfactual.py','sample-orphans.py','review-live.py','teardown-live.py','teardown-postfetch-live.py']:
    source=(base/name).read_text()
    source=source.replace("'.nm-live-yeldv'", "'.nm-live-yeldv-r2'")
    source=source.replace('".nm-live-yeldv"', '".nm-live-yeldv-r2"')
    source=source.replace(str(base)+"'", str(out)+"'")
    source=source.replace(str(base)+'"', str(out)+'"')
    source=source.replace('isolated-env.json', 'env.json')
    source=source.replace('f1ab00000001', 'f2ab00000001')
    source=source.replace('+pipeline fix not pushed to origin', '+private pipeline commit absent from origin')
    (out/name).write_text(source)
