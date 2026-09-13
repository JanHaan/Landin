#!/bin/sh
#  Record exactly which toolchain produced a result.  Every build and test
#  run prints this first, so a captured log names its own compiler.

. "$(dirname -- "$0")/env.sh"

landin_require gnatls
landin_require gprbuild

echo "host:        $(uname -s) $(uname -m)"
echo "build mode:  $LANDIN_BUILD_MODE"
echo "build tag:   $LANDIN_BUILD_TAG"
echo "gnatls:      $(gnatls --version | sed -n '1p')"
echo "gprbuild:    $(gprbuild --version | sed -n '1p')"
echo "gcc:         $(gcc --version | sed -n '1p')"
