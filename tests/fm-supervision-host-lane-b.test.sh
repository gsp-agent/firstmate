#!/usr/bin/env bash
# Lane b of the supervision host behavior tests. The cases live in
# tests/fm-supervision-host.test.sh; this script runs the half that file's
# supervision_host_lane_b lists, so the two halves pack onto different
# portable serial shards.
FM_SUPERVISION_HOST_LANE=b exec bash "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host.test.sh"
