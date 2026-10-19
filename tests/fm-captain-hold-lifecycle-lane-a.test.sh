#!/usr/bin/env bash
# Lane a of the captain hold lifecycle behavior tests. The cases live in
# tests/fm-captain-hold-lifecycle.test.sh; this script runs the half that file's
# captain_hold_lane_a lists, so the two halves pack onto different
# portable parallel shards.
FM_CAPTAIN_HOLD_LANE=a exec bash "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-lifecycle.test.sh"
