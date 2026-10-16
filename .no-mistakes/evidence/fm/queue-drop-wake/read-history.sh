#!/usr/bin/env bash
set -eu
export GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1 GH_TELEMETRY=false
unset GH_DEBUG
GH_TOKEN="$(gh auth token --user gsp-agent)" gh-axi api POST /graphql --input /Users/dalecarman/.no-mistakes/evidence/01M52M4YB15FC8H82PA7T22SFS/history-request.json --full --jq tojson > /Users/dalecarman/.no-mistakes/evidence/01M52M4YB15FC8H82PA7T22SFS/github-history.json
