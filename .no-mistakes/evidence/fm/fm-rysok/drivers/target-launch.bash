shopt -s extdebug
_validation_select() {
  case "$BASH_COMMAND" in test_*) [ "$BASH_COMMAND" = "$FM_VALIDATION_CASE" ] || return 1 ;; esac
  return 0
}
trap _validation_select DEBUG
. "${FM_VALIDATION_SUITE:-$PWD/tests/fm-pi-branch-extension.test.sh}"
