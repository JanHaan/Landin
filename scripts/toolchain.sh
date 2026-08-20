#!/bin/sh
#  Record exactly which toolchain produced a result.  Every build and test
#  run prints this first, so a captured log names its own compiler.

. "$(dirname -- "$0")/env.sh"

landin_require gnatls
landin_require gprbuild

echo "host:        $(uname -s) $(uname -m)"
echo "build mode:  $LANDIN_BUILD_MODE"
echo "build tag:   $LANDIN_BUILD_TAG"
echo "gnatls:      $(gnatls --version | head -n 1)"
echo "gprbuild:    $(gprbuild --version | head -n 1)"
echo "gcc:         $(gcc --version | head -n 1)"
