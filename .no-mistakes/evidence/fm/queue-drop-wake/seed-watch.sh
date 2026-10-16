#!/usr/bin/env bash
set -eu
code=$1
home=$2
id=$3
url=$4
template=${5:-$code/bin/fm-pr-poll.sh}
. "$code/bin/fm-pr-lib.sh"
fm_pr_url_parse "$url"
fm_pr_poll_prepare "$home/state" "$id" "$FM_PR_PROVIDER" "$FM_PR_URL" \
  "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$template"
fm_pr_poll_publish_prepared
