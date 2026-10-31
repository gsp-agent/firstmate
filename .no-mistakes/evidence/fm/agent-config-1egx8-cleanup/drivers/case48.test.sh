#!/usr/bin/env bash
# Disposable: the suite's real case 48 alone, the case the report names, then the suite's
# own exit cleanup. Goes through the runner by way of drivers/whole-suite.sh.
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$SELF_DIR/fm-supervision-host.test.sh"
test_a_park_stopped_mid_take_over_leaves_the_take_over_to_the_next_park
