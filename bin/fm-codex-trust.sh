#!/usr/bin/env bash
# Pre-register Codex's folder trust for the repository root a codex ship/scout
# spawn is about to launch into, so the worker reaches its brief instead of
# parking on Codex's "Trust this folder?" prompt.
#
# Usage: fm-codex-trust.sh <worktree> <project>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
# Prints one line naming the root it trusted; refuses loudly on anything else.
#
# WHY THIS EXISTS. codex-cli 0.163.0 gates a repository it has no saved trust
# decision for behind a full-screen "Folder access" prompt, and
# --dangerously-bypass-approvals-and-sandbox does not skip it. Codex keys the
# decision by the REPOSITORY ROOT, not the launch directory: the parent of the
# canonical `git rev-parse --git-common-dir`, so every linked worktree of a
# project resolves to that project's primary checkout ("Trusting will apply to
# the repository root" on the prompt itself). Answering it appends
#   [projects."<root>"]
#   trust_level = "trusted"
# to ${CODEX_HOME:-$HOME/.codex}/config.toml, and Codex honours an entry
# written there ahead of launch (docs/verification/codex.md).
#
# AN EXPLICIT DECLINE IS NOT OVERRIDDEN. trust_level = "untrusted" is what
# Codex writes when a person declines, and it parks the worker on a second
# prompt ("Open restricted").
#
# THE SCOPE TEST IS THE SAFETY PROPERTY and mirrors bin/fm-agy-trust.sh:
# <worktree> must be a LINKED git worktree of <project> whose top level is
# exactly the resolved argument, and the root Codex will resolve for it must be
# a standard primary checkout (its own .git directory IS the shared common dir)
# that is not the home directory. Anything else is refused with a non-zero exit,
# never a warning and never a silent skip.
#
# THE STORE. Codex reads $CODEX_HOME when it is set (it must then be an existing
# directory) and $HOME/.codex otherwise. bin/fm-spawn.sh forwards a set
# CODEX_HOME onto the codex launch, so only an absolute value names the same
# store on both sides.
#
# THE WRITE NEVER REWRITES THE FILE. The new table is appended after the
# original bytes, so every other setting, comment, and entry keeps its exact
# text and order. The candidate must parse to the original plus this one
# entry, which stops an append from creating a duplicate table Codex would
# refuse to start on. The rename is fingerprint-checked because Codex can
# rewrite the store meanwhile.
#
# bin/fm-spawn.sh keeps a post-launch gate as the backstop: a codex launch whose
# screen shows the folder-access prompt anyway fails the spawn instead of
# counting as started.
set -u
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

[ "$#" -eq 2 ] || { echo "usage: fm-codex-trust.sh <worktree> <project>" >&2; exit 2; }
WT_ARG=$1
PROJ_ARG=$2

refuse() { echo "error: refusing to pre-register codex trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

[ -n "${HOME:-}" ] || refuse "HOME is not set, so codex's config store cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"
[ "$WT_REAL" != "$HOME_REAL" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has an unresolvable git directory"
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"

PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

CODEX_ROOT=$(dirname -- "$WT_COMMON")
[ "$(real_dir "$CODEX_ROOT/.git")" = "$WT_COMMON" ] \
  || refuse "codex would trust '$CODEX_ROOT', which is not the primary checkout owning '$WT_COMMON'"
[ "$CODEX_ROOT" != / ] || refuse "codex would trust the filesystem root"
[ "$CODEX_ROOT" != "$HOME_REAL" ] || refuse "codex would trust the home directory '$CODEX_ROOT'"

command -v python3 >/dev/null 2>&1 || refuse "python3 is required to edit codex's config safely and was not found on PATH"

if [ -n "${CODEX_HOME:-}" ]; then
  case $CODEX_HOME in
    /*) ;;
    *) refuse "CODEX_HOME '$CODEX_HOME' is a relative path, so the store the worker reads cannot be guaranteed to be the one written here; set it to an absolute path" ;;
  esac
  STORE_DIR_REAL=$(real_dir "$CODEX_HOME") || true
  [ -n "$STORE_DIR_REAL" ] || refuse "CODEX_HOME '$CODEX_HOME' is not an existing directory, and codex itself refuses to start with it"
else
  mkdir -p "$HOME_REAL/.codex" 2>/dev/null || true
  STORE_DIR_REAL=$(real_dir "$HOME_REAL/.codex") || true
  [ -n "$STORE_DIR_REAL" ] || refuse "codex config directory '$HOME_REAL/.codex' does not exist and could not be created"
fi
STORE="$STORE_DIR_REAL/config.toml"
if [ -L "$STORE" ]; then
  STORE_REAL=$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$STORE" 2>/dev/null) || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

if ! python3 -I - "$STORE" "$CODEX_ROOT" <<'PY'
import copy
import hashlib
import os
import sys
import tempfile

try:
    import tomllib
except ImportError:
    print("error: python3 3.11 or newer (tomllib) is required to verify codex's config", file=sys.stderr)
    sys.exit(1)

store, key = sys.argv[1], sys.argv[2]


class Refusal(Exception):
    pass


def read():
    try:
        with open(store, "rb") as handle:
            return handle.read()
    except FileNotFoundError:
        return None


def fingerprint(raw):
    return "absent" if raw is None else hashlib.sha256(raw).hexdigest()


def parse(raw, what):
    try:
        return tomllib.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as err:
        raise Refusal(f"{what} is not valid TOML ({err})")


def entry_for(data):
    projects = data.get("projects")
    if projects is None:
        return None
    if not isinstance(projects, dict):
        raise Refusal(f'{store} has a "projects" value that is not a table')
    entry = projects.get(key)
    if entry is not None and not isinstance(entry, dict):
        raise Refusal(f"{store} has a non-table entry for {key}")
    return entry


def toml_key(text):
    out = []
    for ch in text:
        if ch in '"\\':
            out.append("\\" + ch)
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            out.append("\\u%04X" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def attempt():
    original = read()
    before = fingerprint(original)
    raw = original or b""
    data = parse(raw, store)
    entry = entry_for(data)
    if entry is not None:
        level = entry.get("trust_level")
        if level == "trusted":
            return "recorded"
        if level is None:
            raise Refusal(f"{store} already has an entry for {key} with no trust_level; refusing to edit it in place")
        raise Refusal(f"{store} records trust_level = {level!r} for {key}, an explicit decision this will not override")
    text = raw.decode("utf-8")
    lead = "" if text == "" else ("\n" if text.endswith("\n") else "\n\n")
    candidate = (text + lead + f'[projects.{toml_key(key)}]\ntrust_level = "trusted"\n').encode("utf-8")
    expected = copy.deepcopy(data)
    expected.setdefault("projects", {})[key] = {"trust_level": "trusted"}
    if repr(parse(candidate, "the appended config")) != repr(expected):
        raise Refusal(f"appending the trust entry would change other settings in {store}")
    mode = (os.stat(store).st_mode & 0o7777) if original is not None else 0o600
    fd, tmp = tempfile.mkstemp(prefix=".config.toml.fm-trust.", dir=os.path.dirname(store))
    renamed = False
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(candidate)
            handle.flush()
            os.fchmod(handle.fileno(), mode)
            os.fsync(handle.fileno())
        if fingerprint(read()) != before:
            return "moved"
        os.replace(tmp, store)
        renamed = True
    finally:
        if not renamed:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
    back = entry_for(parse(read() or b"", store))
    return "recorded" if back is not None and back.get("trust_level") == "trusted" else "dropped"


try:
    for i in range(3):
        result = attempt()
        if result == "recorded":
            sys.exit(0)
        if result == "moved" and i >= 1:
            print(f"error: {store} was modified while trust was being recorded; refusing to overwrite it", file=sys.stderr)
            sys.exit(1)
except Refusal as err:
    print(f"error: {err}", file=sys.stderr)
    sys.exit(1)
print(f"error: {store} did not retain trust for {key} after 3 attempts", file=sys.stderr)
sys.exit(1)
PY
then
  refuse "could not record trust for '$CODEX_ROOT' in '$STORE'"
fi

echo "trusted: $CODEX_ROOT"
