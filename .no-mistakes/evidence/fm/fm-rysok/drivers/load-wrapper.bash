shopt -s extdebug
_validation_skip_cases() {
  case "$BASH_COMMAND" in test_*) return 1 ;; esac
  return 0
}
trap _validation_skip_cases DEBUG
. "${FM_VALIDATION_SUITE:-$PWD/tests/fm-pi-branch-extension.test.sh}"
trap - DEBUG
shopt -u extdebug
export FM_VALIDATION_OWNER=$$
export FM_HOME="$TMP_ROOT/reap-home"
mkdir -p "$FM_HOME/state" "$FM_HOME/config"
node --input-type=module <<'JS'
import {spawn} from 'node:child_process';
import {mkdirSync,writeFileSync} from 'node:fs';
for (const name of ['.wake-queue.lock','.branch-outcomes.lock']) {
  mkdirSync(`${process.env.FM_HOME}/state/${name}`);
  writeFileSync(`${process.env.FM_HOME}/state/${name}/pid`,process.env.FM_VALIDATION_OWNER+'\n');
}
const a=spawn('bash',[`${process.cwd()}/bin/fm-wake-grant.sh`,'release','0'],{stdio:'ignore'});
const b=spawn('bash',[`${process.cwd()}/bin/fm-branch-outcome.sh`,'mark-read','--through','0'],{stdio:'ignore'});
writeFileSync(process.env.FM_VALIDATION_READY,JSON.stringify({node:process.pid,grant:a.pid,outcome:b.pid,home:process.env.FM_HOME}));
if (process.env.FM_VALIDATION_MODE==='linger') setInterval(()=>{},1000);
else setTimeout(()=>{if(process.env.FM_VALIDATION_MODE==='failure') throw new Error('deliberate driver assertion failure'); process.exit(0)},800);
JS
exit $?
