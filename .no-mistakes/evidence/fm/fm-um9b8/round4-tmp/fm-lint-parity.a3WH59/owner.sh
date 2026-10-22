#!/usr/bin/env bash
# shellcheck source=/Users/dalecarman/.no-mistakes/evidence/01M5HEFVZ2ZGARFBBBDTE72WAN/round4-tmp/fm-lint-parity.a3WH59/owner-dep.sh
. "/Users/dalecarman/.no-mistakes/evidence/01M5HEFVZ2ZGARFBBBDTE72WAN/round4-tmp/fm-lint-parity.a3WH59/owner-dep.sh"
owner_bad() {
  printf '%s\n' "$owner_dependency_value"
  cd "$1"
}
