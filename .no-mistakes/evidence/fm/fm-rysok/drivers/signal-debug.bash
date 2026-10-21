unset BASH_ENV
shopt -s extdebug
_validation_debug() {
  case "$BASH_COMMAND" in
    test_*) [ "$BASH_COMMAND" = test_secondary_session_stays_inert ] || return 1 ;;
  esac
  if [ -n "${foreign_pid:-}" ] && [ -z "${_validation_paused:-}" ]; then
    _validation_paused=1
    printf '%s %s\n' "$$" "$foreign_pid" > "$FM_VALIDATION_READY"
    kill -STOP "$$"
  fi
  return 0
}
trap _validation_debug DEBUG
