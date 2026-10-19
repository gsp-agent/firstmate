#!/usr/bin/env bash
set -eu
case ${NM_KIND:?} in
  file) rm -- "${NM_TARGET:?}" ;;
  dir) rmdir -- "${NM_TARGET:?}" ;;
  *) exit 2 ;;
esac
