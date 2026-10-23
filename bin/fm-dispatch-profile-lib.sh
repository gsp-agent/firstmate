#!/usr/bin/env bash
# fm-dispatch-profile-lib.sh - read config/crew-dispatch.json pairs and apply
# the relaunch pair decision. Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# docs/configuration.md "Crew dispatch profiles" owns the acceptance rules.
# This file reads the file and applies that relaunch decision. It does not
# match natural-language rules.

# fm_dispatch_profile_read <config-dir> <harness>
# Print one model<TAB>effort line per distinct pair the file names for the
# harness across default, label_routes, and rules[].use. No output when the
# file is absent or never names the harness. Status 1, with the reason on
# stderr, when the file is present but cannot be read. An omitted model or
# effort axis reads as default.
fm_dispatch_profile_read() {
  local config=$1 harness=$2 file pairs
  file=$config/crew-dispatch.json
  if [ ! -e "$file" ]; then
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/crew-dispatch.json is active - could not read its dispatch profiles for harness $harness; fix the file rather than spawning around it" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: config/crew-dispatch.json is active - jq is required to read its dispatch profiles for harness $harness" >&2
    return 1
  fi
  # Leave jq's own diagnostic on stderr. A parse failure is a read failure,
  # and the operator message below says where to fix it.
  if ! pairs=$(jq -r --arg h "$harness" '
    def profiles($v):
      if ($v | type) == "array" then $v
      elif ($v | type) == "object" then [$v]
      else [] end;
    ([((.rules // [])[]? | profiles(.use? // null)[]?),
       (profiles(.default // null)[]?),
       ((.label_routes // {})[]? | profiles(.)[]?)]
     | map(select(type == "object" and .harness == $h))
     | map([(.model // "default"), (.effort // "default")] | @tsv)
     | unique | .[])' "$file"); then
    echo "error: config/crew-dispatch.json is active - could not read its dispatch profiles for harness $harness; fix the file rather than spawning around it" >&2
    return 1
  fi
  # An empty listing is "this harness is unnamed", not a blank pair line.
  [ -z "$pairs" ] || printf '%s\n' "$pairs"
}

# fm_dispatch_profile_pairs_pretty <pairs>
# Join "model effort" pairs with commas for the operator messages.
fm_dispatch_profile_pairs_pretty() {
  local pairs=$1 model effort out=
  while IFS="$(printf '\t')" read -r model effort; do
    [ -n "$model" ] || continue
    out="${out:+$out, }$model $effort"
  done <<EOF
$pairs
EOF
  printf '%s\n' "$out"
}

# fm_dispatch_relaunch_decide <id> <harness> <model> <effort> <pairs>
# pairs is non-empty. Print the resolved model and effort, one per line.
# A match returns the input pair. Exactly one non-matching pair adopts that
# pair and prints the adoption notice on stderr. Any other mismatch refuses.
fm_dispatch_relaunch_decide() {
  local id=$1 harness=$2 model=$3 effort=$4 pairs=$5
  local fallback_model=${6:-} fallback_effort=${7:-}
  local pretty pair one_model one_effort count matched=0
  [ -n "$model" ] || model=default
  [ -n "$effort" ] || effort=default
  pretty=$(fm_dispatch_profile_pairs_pretty "$pairs")
  while IFS="$(printf '\t')" read -r one_model one_effort; do
    if [ "$one_model" = "$model" ] && [ "$one_effort" = "$effort" ]; then
      matched=1
      break
    fi
  done <<EOF
$pairs
EOF
  if [ "$matched" = 1 ] \
      || { [ "$model" = "$fallback_model" ] && [ "$effort" = "$fallback_effort" ]; }; then
    printf '%s\n' "$model"
    printf '%s\n' "$effort"
    return 0
  fi
  count=$(printf '%s\n' "$pairs" | grep -c .) || count=0
  if [ "$count" -eq 1 ]; then
    pair=$(printf '%s\n' "$pairs" | head -n 1)
    one_model=$(printf '%s' "$pair" | cut -f1)
    one_effort=$(printf '%s' "$pair" | cut -f2)
    echo "dispatch profile: relaunch of $id adopts the dispatch file pair for $harness ($pretty) over the recorded $model $effort" >&2
    printf '%s\n' "$one_model"
    printf '%s\n' "$one_effort"
    return 0
  fi
  echo "error: config/crew-dispatch.json is active - relaunch of $id on $harness $model $effort matches no dispatch profile for $harness, and the file names more than one pair for that harness ($pretty); resolve one pair at intake rather than guessing" >&2
  return 1
}

# fm_dispatch_relaunch_pair <config-dir> <id> <harness> <model> <effort>
# Print the model and effort a relaunch should launch, one per line. An absent
# file, or a harness the file never names, returns the input pair. Status 1
# when the file cannot be read or the relaunch must be refused.
fm_dispatch_relaunch_pair() {
  local config=$1 id=$2 harness=$3 model=$4 effort=$5 pairs
  [ -n "$model" ] || model=default
  [ -n "$effort" ] || effort=default
  pairs=$(fm_dispatch_profile_read "$config" "$harness") || return 1
  if [ -z "$pairs" ]; then
    printf '%s\n' "$model"
    printf '%s\n' "$effort"
    return 0
  fi
  fm_dispatch_relaunch_decide "$id" "$harness" "$model" "$effort" "$pairs" "${6:-}" "${7:-}"
}
