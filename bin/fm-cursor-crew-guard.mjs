#!/usr/bin/env node
// fm-cursor-crew-guard.mjs - Cursor preToolUse hook for one Firstmate-launched
// session (ship, scout, or secondmate). bin/fm-spawn.sh writes it into a per-task
// plugin directory and loads that directory with --plugin-dir, so it exists for
// the launched session only and never for the captain's own Cursor sessions.
//
// Usage (Cursor passes the payload on stdin):
//   <preToolUse JSON> | fm-cursor-crew-guard.mjs --worktree <task-worktree>
//
// For a Shell tool call it does two things.
//
//   1. Pins the working directory. Cursor keeps one persistent shell per
//      conversation, and a call that omits its working directory runs wherever
//      the previous call left that shell, not in the workspace. A single
//      earlier call with an explicit working directory in another checkout
//      can therefore redirect the next empty-directory call. The hook rewrites an
//      empty directory to --worktree, so a call that names no directory always
//      runs in the task worktree. A call that names a directory is left alone.
//      cursor-agent 2026.10.16 sends tool_input.cwd ("" for no directory) and
//      applies only updated_input.cwd, so the pin is written there; it is also
//      written to working_directory, the field the payload may name instead.
//
//   2. Refuses git symbolic-ref and git update-ref. Both move HEAD or a ref
//      with none of checkout's checks, so they can bypass a branch-creation
//      refusal. Reads of the same state have plain alternatives
//      (git branch --show-current), which
//      the refusal names. This is the only per-command policy here: git
//      checkout -b and checkout -B can be refused by permission rules Cursor
//      imports from ~/.claude/settings.json or the repository's Claude
//      settings. A deny outranks an allow, so a per-session allow cannot lift
//      it; git switch -c is the branch command the generated brief recommends.
//
// Scope: this pins implicit working-directory drift and refuses HEAD and ref
// plumbing. It is not repository confinement: a command that names another
// checkout explicitly (git -C /primary switch -c ...) is allowed by design.
//
// Output is Cursor's preToolUse decision object on stdout with exit 0, or
// nothing for "no change". Unparseable input produces no decision; a missing
// --worktree skips directory rewriting but leaves ref-plumbing refusals active.
// A tokenizer error uses a conservative git/ref-subcommand pattern instead;
// unrecognized commands remain unchanged. A broken hook must never refuse every
// shell call. The shell tokenizer is the shared owner,
// bin/fm-arm-command-policy.mjs; nothing here evaluates the command.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";

const REFUSED_SUBCOMMANDS = new Set(["symbolic-ref", "update-ref"]);
const SHELLS = new Set(["sh", "bash", "zsh"]);
// Words that may precede the real command word in a compound command.
const KEYWORDS = new Set(["if", "then", "else", "elif", "do", "while", "until", "time", "!", "{"]);
// Global git options whose value is the next word.
const GIT_OPTIONS_WITH_VALUE = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"]);

const REFUSAL =
  "[crew-git-plumbing] git symbolic-ref and git update-ref move HEAD or a ref without git's checks, so a crew session may not run them. " +
  "A refused command is a stop: append `blocked [at=<epoch>]: <what you needed>` to your status file and wait; do not get the same effect another way. " +
  "To read the current branch use `git branch --show-current`; to start a branch use `git switch -c <name>`.";

function gitSubcommand(words, from) {
  for (let i = from; i < words.length; i += 1) {
    const value = words[i].value;
    if (!value.startsWith("-")) return value;
    if (GIT_OPTIONS_WITH_VALUE.has(value)) i += 1;
  }
  return "";
}

// shellWord re-quotes one already-unquoted word so a re-joined command lexes the same way.
function shellWord(value) {
  return /^[A-Za-z0-9_\/.:=@%+,-]+$/.test(value) ? value : `'${value.replace(/'/g, "'\\''")}'`;
}

function refuses(command, depth = 0) {
  if (depth > 6 || !command) return false;
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return /(?:^|[\s;&|(])git\b[^;&|\n]*\b(?:symbolic-ref|update-ref)\b/.test(command);

  // Subshells, brace groups, and command substitutions hide their command
  // words from commandPosition, so recurse into each one.
  for (const token of lexed.tokens) {
    if (token.type === "group" && refuses(token.content, depth + 1)) return true;
    if (token.type !== "word") continue;
    for (const sub of token.subs ?? []) {
      if (refuses(sub.content, depth + 1)) return true;
    }
  }

  for (const node of splitProgram(lexed.tokens).nodes) {
    const position = commandPosition(node);
    const { words } = position;
    // A wrapper's embedded command (env -S '...') is a command of its own.
    for (const payload of position.wrapperPayloads ?? []) {
      if (refuses(payload, depth + 1)) return true;
    }
    let index = position.index;
    if (words[index] && KEYWORDS.has(words[index].value)) {
      // A leading keyword (then, do, ...) hides the real command word from
      // commandPosition's wrapper analysis, so analyze what follows the
      // keywords as its own command, wrappers included.
      while (words[index] && KEYWORDS.has(words[index].value)) index += 1;
      if (words[index] && refuses(words.slice(index).map((w) => shellWord(w.value)).join(" "), depth + 1)) return true;
      continue;
    }
    const word = words[index];
    if (!word) continue;
    const name = basename(word.value);
    if (name === "git") {
      if (REFUSED_SUBCOMMANDS.has(gitSubcommand(words, index + 1))) return true;
    } else if (name === "git-symbolic-ref" || name === "git-update-ref") {
      return true;
    } else if (SHELLS.has(name)) {
      for (let i = index + 1; i < words.length; i += 1) {
        if (!/^-[A-Za-z]*c[A-Za-z]*$/.test(words[i].value)) continue;
        if (words[i + 1] && refuses(words[i + 1].value, depth + 1)) return true;
        break;
      }
    } else if (name === "eval") {
      if (refuses(words.slice(index + 1).map((w) => w.value).join(" "), depth + 1)) return true;
    }
  }
  return false;
}

function decide(input, worktree) {
  if (!input || input.tool_name !== "Shell") return null;
  const toolInput = input.tool_input ?? {};
  const command = typeof toolInput.command === "string" ? toolInput.command : "";
  if (refuses(command)) {
    return { permission: "deny", user_message: REFUSAL, agent_message: REFUSAL };
  }
  if (worktree && !toolInput.cwd && !toolInput.working_directory) {
    return { permission: "allow", updated_input: { ...toolInput, cwd: worktree, working_directory: worktree } };
  }
  return null;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

function worktreeFromArguments(argv) {
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--worktree") return argv[i + 1] ?? "";
    if (argv[i].startsWith("--worktree=")) return argv[i].slice("--worktree=".length);
  }
  return "";
}

if (invokedDirectly()) {
  try {
    const input = JSON.parse(await readStdin());
    const result = decide(input, worktreeFromArguments(process.argv.slice(2)));
    if (result) process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch {
    // Fail open: unparseable input never refuses a shell call.
  }
}

export { decide, refuses };
