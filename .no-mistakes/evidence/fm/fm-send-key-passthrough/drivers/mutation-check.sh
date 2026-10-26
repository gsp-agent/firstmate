#!/usr/bin/env bash
# Prove the new --key tests bite: run each one alone in a throwaway copy of the
# repo, first unmodified (must pass), then with that backend's key path broken
# (must fail). The worktree under validation is never touched.
# Usage: mutation-check.sh <scratch-dir>   (expects <scratch-dir>/mut from git archive HEAD)
set -u
S=$1
BASE="$S/mut"

only() { # <test-file> <test-fn> -> trimmed runner that calls just <test-fn>
  local src=$1 fn=$2 out
  out="${src%.test.sh}.only-$fn.test.sh"
  sed -E '/^test_[A-Za-z0-9_]+$/d' "$src" > "$out"
  printf '%s\n' "$fn" >> "$out"
  printf '%s' "$out"
}

run_case() { # <label> <copy> <test-file> <test-fn>
  local label=$1 copy=$2 file=$3 fn=$4 runner out rc
  runner=$(only "$copy/tests/$file" "$fn")
  out=$(bash "$runner" 2>&1); rc=$?
  printf '%s: %s exit=%s\n' "$label" "$fn" "$rc"
  printf '%s\n' "$out" | grep -E '^(ok|not ok|FAIL|PASS)|did not|should' | head -n 4 | sed 's/^/    /'
  return "$rc"
}

fresh() { # <name> -> path of a new copy
  local d
  d=$(mktemp -d "$S/copy-$1.XXXXXX") && (cd "$BASE" && tar -cf - .) | (cd "$d" && tar -xf -)
  # fm-backend.test.sh resolves its old-vs-new baseline from a local main, so
  # each copy is its own one-commit repo on main, made before any mutation.
  git -C "$d" init -q -b main && git -C "$d" add -A \
    && git -C "$d" -c user.name=mutation-check -c user.email=mutation-check@invalid commit -q -m base
  printf '%s' "$d"
}

failures=0

# --- tmux ---
c=$(fresh tmux-ok)
run_case "tmux unmodified (expect pass)" "$c" fm-backend.test.sh test_send_tmux_contract || failures=$((failures + 1))
c=$(fresh tmux-mut)
# Regress tmux to the old documented-only set: refuse any key but Escape, Enter, C-c.
python3 - "$c/bin/backends/tmux.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '  tmux send-keys -t "$1" "$2"\n}'
assert old in s
s = s.replace(old, '  case "$2" in Escape|Enter|C-c) ;; *) return 1 ;; esac\n  tmux send-keys -t "$1" "$2"\n}', 1)
open(p, "w").write(s)
PY
if run_case "tmux mutated: only Escape/Enter/C-c pass (expect FAIL)" "$c" fm-backend.test.sh test_send_tmux_contract; then
  echo "    MUTANT SURVIVED"; failures=$((failures + 1))
else
  echo "    mutant caught"
fi

# --- herdr ---
c=$(fresh herdr-ok)
run_case "herdr unmodified (expect pass)" "$c" fm-backend-herdr.test.sh test_send_key_passes_unlisted_key_through || failures=$((failures + 1))
c=$(fresh herdr-mut)
# Regress Herdr to lowercasing unlisted keys, which turns Shift+x into x.
python3 - "$c/bin/backends/herdr.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "    C-u|c-u|ctrl+u|Ctrl+U) printf 'ctrl+u' ;;\n    *) printf '%s' \"$1\" ;;"
assert old in s
s = s.replace(old, "    C-u|c-u|ctrl+u|Ctrl+U) printf 'ctrl+u' ;;\n    *) printf '%s' \"$1\" | tr 'A-Z' 'a-z' ;;", 1)
open(p, "w").write(s)
PY
if run_case "herdr mutated: unlisted keys lowercased (expect FAIL)" "$c" fm-backend-herdr.test.sh test_send_key_passes_unlisted_key_through; then
  echo "    MUTANT SURVIVED"; failures=$((failures + 1))
else
  echo "    mutant caught"
fi

# --- orca ---
c=$(fresh orca-ok)
run_case "orca unmodified (expect pass)" "$c" fm-backend-orca.test.sh test_send_key_refuses_unknown_key || failures=$((failures + 1))
c=$(fresh orca-mut)
# Regress Orca to silently typing X instead of refusing it.
python3 - "$c/bin/backends/orca.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "    Enter|enter)\n"
assert old in s
s = s.replace(old, "    X)\n      fm_backend_orca_run_json orca terminal send --terminal \"$terminal\" --text X --json\n      ;;\n" + old, 1)
open(p, "w").write(s)
PY
if run_case "orca mutated: X accepted (expect FAIL)" "$c" fm-backend-orca.test.sh test_send_key_refuses_unknown_key; then
  echo "    MUTANT SURVIVED"; failures=$((failures + 1))
else
  echo "    mutant caught"
fi

echo
echo "mutation-check problems: $failures"
[ "$failures" -eq 0 ]
