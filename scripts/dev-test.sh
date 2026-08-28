#!/bin/sh
#  Fast developer tests over GPRbuild's checksum-based incremental objects.
#  A focused run is feedback; scripts/test.sh with no selector remains the
#  complete local gate.

set -eu

LANDIN_BUILD_INCREMENTAL=yes
export LANDIN_BUILD_INCREMENTAL

exec "$(dirname -- "$0")/test.sh" "$@"
