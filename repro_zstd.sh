#!/usr/bin/env bash
# Repro 1: cache poisoning when zstd-jni cannot load on one machine.
# bazel-remote runs with its default settings.
#
# Machines (separate output user roots, one shared bazel-remote):
#   healthy   - zstd works. Fetches @x locally and uploads the good entry.
#   poisoner  - zstd is broken. Gets a hit for @x, fails to prefetch defs.bzl
#               (compressed), fetches @x locally, and uploads a broken entry.
#   consumer  - zstd works, clean state. Gets a hit for the broken entry.
#
# How zstd is broken on the poisoner:
#   default:              -DZstdNativePath=<a file that is not a library>
#   NOEXEC_DIR=/some/dir: -DZstdTempFolder=/some/dir (a noexec mount, as on a
#                         machine with /tmp mounted noexec)
# Controls:
#   BREAK_ZSTD=0          the poisoner has working zstd and gets a cache hit.
#   POISONER_FLAGS="--experimental_worker_for_repo_fetching=off"
source "$(dirname "$0")/lib.sh"
check_tools
start_cache

COMPRESSION=(--remote_cache_compression --experimental_remote_cache_compression_threshold=2500)

BREAK=""
if [[ "${BREAK_ZSTD:-1}" == 1 ]]; then
  if [[ -n "${NOEXEC_DIR:-}" ]]; then
    BREAK="--host_jvm_args=-DZstdTempFolder=$NOEXEC_DIR"
  else
    echo "this is not a shared library" > "$WORK/not-a-library.so"
    BREAK="--host_jvm_args=-DZstdNativePath=$WORK/not-a-library.so"
  fi
fi

run_machine healthy "" "${COMPRESSION[@]}"
record_good_entry
# shellcheck disable=SC2086
run_machine poisoner "$BREAK" "${COMPRESSION[@]}" ${POISONER_FLAGS:-}
run_machine consumer "" "${COMPRESSION[@]}"
report
