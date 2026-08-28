#!/bin/sh
#  Fast checksum-safe developer compilation.  The ordinary build remains the
#  clean-on-change gate; use it before making a claim about the tree.

set -eu

LANDIN_BUILD_INCREMENTAL=yes
export LANDIN_BUILD_INCREMENTAL

exec "$(dirname -- "$0")/build.sh" "$@"
