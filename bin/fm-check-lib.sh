#!/usr/bin/env bash

FM_CUSTOM_CHECK_HASH=
FM_CUSTOM_CHECK_SNAPSHOT=

fm_custom_check_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# One identity string for a rejected check and its trust record: content hash
# plus the exact file facts the authentication reads themselves check (mode,
# device, inode, link count, symlink-ness), so any change a re-registration or
# a tamper makes - including a same-bytes hardlink or device shift - reads as
# a new rejection. An absent part reads "absent", an unreadable one keeps a
# stable placeholder rather than failing the sweep.
_fm_rejected_check_part() {  # <file>
  local file=$1 hash
  if [ -L "$file" ]; then
    printf 'symlink:%s:%s' "$(fm_pr_file_device "$file" 2>/dev/null || printf x)" \
      "$(fm_pr_file_inode "$file" 2>/dev/null || printf x)"
    return 0
  fi
  [ -f "$file" ] || { printf 'absent'; return 0; }
  hash=$(fm_custom_check_sha256 "$file" 2>/dev/null || printf unreadable)
  printf '%s:%s:%s:%s:%s' "$hash" \
    "$(fm_pr_file_mode "$file" 2>/dev/null || printf x)" \
    "$(fm_pr_file_device "$file" 2>/dev/null || printf x)" \
    "$(fm_pr_file_inode "$file" 2>/dev/null || printf x)" \
    "$(fm_pr_file_link_count "$file" 2>/dev/null || printf x)"
}

fm_rejected_check_fingerprint() {  # <state> <id>
  printf '%s|%s|%s|%s' "$(_fm_rejected_check_part "$1/$2.check.sh")" \
    "$(_fm_rejected_check_part "$1/$2.check-trust")" \
    "$(_fm_rejected_check_part "$1/$2.pr-poll-registration")" \
    "$(_fm_rejected_check_part "$1/$2.meta")"
}

# The once-only announcement record for a rejected check: state holds one
# marker per check id, containing the fingerprint that was announced. A
# rejected check wakes main once, naming its owning task id (the filename
# stem fm-check-register.sh itself takes); while the fingerprint is
# unchanged it stays silent, and a changed fingerprint announces again.
fm_rejected_check_announced() {  # <state> <id> <fingerprint>
  local marker="$1/.rejected-check-$2"
  [ -f "$marker" ] && [ ! -L "$marker" ] \
    && [ "$(cat "$marker" 2>/dev/null || true)" = "$3" ]
}

fm_rejected_check_mark() {  # <state> <id> <fingerprint>
  local marker="$1/.rejected-check-$2" tmp
  tmp=$(umask 077; mktemp "$1/.rejected-check.XXXXXX") || return 1
  if ! printf '%s' "$3" > "$tmp" || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_rejected_check_clear() {  # <state> <id>
  rm -f -- "$1/.rejected-check-$2"
}

# The lock a check's writer holds across publishing the check and its trust
# record, and the watcher holds for its one retry of a failed authentication,
# so that retry sees the old pair or the new one. It is not the task's
# control lock.
fm_custom_check_publish_lock() {  # <state> <id>
  printf '%s/.check-publish-%s.lock' "$1" "$2"
}

fm_custom_check_trust_read() {
  local state=$1 id=$2 trust state_device version hash
  FM_CUSTOM_CHECK_HASH=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  fm_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-custom-check-v1 ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  FM_CUSTOM_CHECK_HASH=$hash
}

fm_custom_check_registered() {
  local state=$1 id=$2 check hash state_device
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  hash=$(fm_custom_check_sha256 "$check") || return 1
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ]
}

fm_custom_check_snapshot_prepare() {
  local state=$1 id=$2 check hash state_device
  fm_custom_check_snapshot_cleanup
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  FM_CUSTOM_CHECK_SNAPSHOT=$(mktemp "$state/.fm-custom-check.XXXXXX") || return 1
  cp "$check" "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  chmod 0600 "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  [ -f "$FM_CUSTOM_CHECK_SNAPSHOT" ] && [ ! -L "$FM_CUSTOM_CHECK_SNAPSHOT" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_mode "$FM_CUSTOM_CHECK_SNAPSHOT")" = 600 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_device "$FM_CUSTOM_CHECK_SNAPSHOT")" = "$state_device" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_link_count "$FM_CUSTOM_CHECK_SNAPSHOT")" = 1 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  hash=$(fm_custom_check_sha256 "$FM_CUSTOM_CHECK_SNAPSHOT") \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ] || { fm_custom_check_snapshot_cleanup; return 1; }
}

fm_custom_check_snapshot_cleanup() {
  [ -z "$FM_CUSTOM_CHECK_SNAPSHOT" ] || rm -f -- "$FM_CUSTOM_CHECK_SNAPSHOT"
  FM_CUSTOM_CHECK_SNAPSHOT=
}
