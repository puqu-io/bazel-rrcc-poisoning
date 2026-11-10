#!/usr/bin/env bash
# Builds Bazel 8.8.2 from source with the patches in patches/ applied.
#
# Steps:
#   1. Clone the bazelbuild/bazel tag 8.8.2 into build/bazel-src (or reuse it).
#   2. Apply patches/*.patch in order.
#   3. Build //src:bazel-dev with the bootstrap Bazel ($BAZEL, the prebuilt
#      8.8.2 from the flake by default).
#   4. Copy the result to build/bazel-8.8.2-rrcc and print its version.
#
# Run it inside the FHS build environment:
#   nix run .#bazel-build-env -- ./build_bazel.sh
#
# Set BAZEL_SRC to reuse an existing checkout,
# PATCHES=0 to build an unpatched binary for comparison.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BAZEL_VERSION=8.8.2
BAZEL="${BAZEL:-bazel}"
BAZEL_SRC="${BAZEL_SRC:-$HERE/build/bazel-src}"
TMPDIR="${TMPDIR:-$HERE/build/tmp}"
OUT="${OUT:-$HERE/build/bazel-${BAZEL_VERSION}-rrcc}"
PATCHES="${PATCHES:-1}"
EMBED_LABEL="${BAZEL_VERSION}-rrcc"

command -v "$BAZEL" >/dev/null || { echo "Set BAZEL=/path/to/bazel-${BAZEL_VERSION} (bootstrap Bazel)"; exit 1; }
command -v git >/dev/null || { echo "git is required"; exit 1; }
command -v gcc >/dev/null || { echo "a C++ toolchain is required (gcc)"; exit 1; }

if [[ ! -d "$TMPDIR" ]]; then
  mkdir -p "$TMPDIR"
fi

if [[ ! -d "$BAZEL_SRC/.git" ]]; then
  echo "=== cloning bazel ${BAZEL_VERSION} into $BAZEL_SRC"
  git clone --depth 1 --branch "$BAZEL_VERSION" https://github.com/bazelbuild/bazel.git "$BAZEL_SRC"
fi

cd "$BAZEL_SRC"
echo "=== resetting the checkout to the tag"
git checkout -q -- .
git clean -qfd -e bazel-\* 2>/dev/null || true

if [[ "$PATCHES" == 1 ]]; then
  for p in "$HERE"/patches/*.patch; do
    echo "=== applying $(basename "$p")"
    git apply --check "$p"
    git apply "$p"
  done
else
  echo "=== PATCHES=0: building the unpatched ${BAZEL_VERSION}"
  EMBED_LABEL="${BAZEL_VERSION}-unpatched"
fi

echo "=== building //src:bazel-dev with $("$BAZEL" --version 2>/dev/null || echo "$BAZEL")"
# .bazelversion in the checkout says 8.8.0; the bootstrap is 8.8.2. Bazel
# itself ignores .bazelversion, only Bazelisk reads it.
"$BAZEL" build //src:bazel-dev --embed_label="$EMBED_LABEL" "$@"

mkdir -p "$(dirname "$OUT")"
cp -f bazel-bin/src/bazel-dev "$OUT"
chmod u+w,a+x "$OUT"
echo
echo "=== built $OUT"
"$OUT" --output_user_root="$(mktemp -d)" version 2>/dev/null | grep -E "Build label|Build time" || true
echo
echo "Run the repro with the patched Bazel:"
echo "  BAZEL=$OUT ./repro_zstd.sh        # expect NOT REPRODUCED and a WARNING on the poisoner"
echo "Run the regression test:"
echo "  ./run_regression_test.sh"
