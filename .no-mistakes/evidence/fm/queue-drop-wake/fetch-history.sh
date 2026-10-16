#!/usr/bin/env bash
set -euo pipefail
EVIDENCE=/Users/dalecarman/.no-mistakes/evidence/01M52ZKA2EPSP789SM0Y7YDE7G
GH_TOKEN=$(gh auth token --user gsp-agent) gh api graphql \
 -f owner=groovejones -f repo=groove-sight-platform -F number=4308 \
 -f 'query=query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){number url state merged isInMergeQueue timelineItems(first:100,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT,ADDED_TO_MERGE_QUEUE_EVENT]){nodes{__typename ... on RemovedFromMergeQueueEvent{id createdAt reason} ... on AddedToMergeQueueEvent{id createdAt}}}}}}' \
 > "$EVIDENCE/github-4308-history.json" 2> "$EVIDENCE/github-history-fetch.err"
