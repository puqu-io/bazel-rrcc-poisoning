#!/usr/bin/env bash
# Runs the regression test from patches/0003-*.patch in the patched Bazel
# source tree that build_bazel.sh prepared.
#
# The test lives in Bazel's own integration test suite:
#   //src/test/py/bazel:remote_repo_contents_cache_test
#   RemoteRepoContentsCacheTest.testLookupNotRepeatedWhileWorkerFetchIsRunning
# It builds Bazel and the test remote worker from the checkout, so the first
# run takes as long as build_bazel.sh. Run it inside the FHS build environment:
#   nix run .#bazel-build-env -- ./run_regression_test.sh
#
# To see the test fail, build the tree without the fix but with the test:
#   PATCHES=0 ./build_bazel.sh && (cd build/bazel-src && git apply ../../patches/0003-*.patch) && ./run_regression_test.sh
set -euo pipefail
 
HERE="$(cd "$(dirname "$0")" && pwd)"
BAZEL="${BAZEL:-bazel}"
BAZEL_SRC="${BAZEL_SRC:-$HERE/build/bazel-src}"
TEST=//src/test/py/bazel:remote_repo_contents_cache_test
FILTER=RemoteRepoContentsCacheTest.testLookupNotRepeatedWhileWorkerFetchIsRunning
 
[[ -d "$BAZEL_SRC" ]] || { echo "No source tree at $BAZEL_SRC. Run ./build_bazel.sh first."; exit 1; }
cd "$BAZEL_SRC"
grep -q testLookupNotRepeatedWhileWorkerFetchIsRunning \
  src/test/py/bazel/bzlmod/remote_repo_contents_cache_test.py \
  || { echo "The regression test is not applied in $BAZEL_SRC (patches/0003-*.patch)."; exit 1; }
 
exec "$BAZEL" test "$TEST" \
  --test_filter="$FILTER" \
  --test_sharding_strategy=disabled \
  --test_output=all \
  --test_timeout=1800 \
  "$@"
 

