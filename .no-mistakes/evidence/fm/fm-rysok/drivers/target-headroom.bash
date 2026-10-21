shopt -s extdebug
_validation_select() {
  case "$BASH_COMMAND" in
    test_*)
      [ "$BASH_COMMAND" = test_branch_cache_key_is_per_home_stable ] || return 1
      DRIVER_PRELUDE=${DRIVER_PRELUDE/'i < 250;'/'i < 2500;'}
      ;;
  esac
  return 0
}
trap _validation_select DEBUG
. "$PWD/tests/fm-pi-branch-extension.test.sh"
