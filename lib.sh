# Shared helpers for repro_zstd.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAZEL="${BAZEL:-bazel}"
BAZEL_REMOTE="${BAZEL_REMOTE:-bazel-remote}"
GRPC_PORT="${GRPC_PORT:-9092}"
HTTP_PORT="${HTTP_PORT:-9093}"
HTTP_BASE="http://127.0.0.1:$HTTP_PORT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rrcc-repro.XXXXXX")"
CACHE_DIR="$WORK/bazel-remote-data"
CACHE_LOG="$WORK/bazel-remote.log"
INSPECT=(python3 -I "$HERE/tools/inspect_cache.py")
BR_PID=""

log() { printf '\n=== %s ===\n' "$*"; echo "=== $* ===" >> "$CACHE_LOG"; }

check_tools() {
  local v
  v="$("$BAZEL" --version 2>/dev/null | tail -1 || true)"
  echo "Bazel: ${v:-not found}   bazel-remote: $(command -v "$BAZEL_REMOTE" || echo "not found")"
  echo "Work dir: $WORK"
  command -v "$BAZEL_REMOTE" >/dev/null || { echo "Set BAZEL_REMOTE=/path/to/bazel-remote"; exit 1; }
  [[ "$v" == "bazel 8.8.2" ]] || echo "WARNING: these repros were verified with bazel 8.8.2"
}

# start_cache [extra bazel-remote flags...]
# Starts bazel-remote from the host on a new cache directory in $WORK.
start_cache() {
  "$BAZEL_REMOTE" --dir "$CACHE_DIR" --max_size 1 \
    --grpc_address "127.0.0.1:$GRPC_PORT" --http_address "127.0.0.1:$HTTP_PORT" \
    "$@" >> "$CACHE_LOG" 2>&1 &
  BR_PID=$!
  trap 'stop_cache' EXIT
  for _ in $(seq 100); do
    curl -sf "$HTTP_BASE/status" >/dev/null 2>&1 && return
    kill -0 "$BR_PID" 2>/dev/null || break
    sleep 0.1
  done
  echo "bazel-remote did not start:"; tail -20 "$CACHE_LOG"; exit 1
}

stop_cache() {
  if [[ -n "$BR_PID" ]]; then
    kill "$BR_PID" 2>/dev/null || true
    wait "$BR_PID" 2>/dev/null || true
    BR_PID=""
  fi
}

# run_machine NAME "STARTUP FLAGS" [COMMAND FLAGS...]
# Each machine has its own output user root, so it has no local state in common
# with the other machines. Only the remote cache is shared.
run_machine() {
  local name="$1" startup="$2"; shift 2
  log "$name"
  local root="$WORK/machine_$name"
  # shellcheck disable=SC2086
  (cd "$HERE/ws" && "$BAZEL" --output_user_root="$root" \
      --experimental_remote_repo_contents_cache $startup \
      query @x//:all --remote_cache="grpc://127.0.0.1:$GRPC_PORT" "$@" \
      > "$WORK/$name.out" 2>&1) || true
  #grep -E '^@x//|ERROR' "$WORK/$name.out" || true
  # shellcheck disable=SC2086
  (cd "$HERE/ws" && "$BAZEL" --output_user_root="$root" \
      --experimental_remote_repo_contents_cache $startup shutdown >/dev/null 2>&1) || true
  echo ""
  cat "$WORK/$name.out"
  echo ""
}

# Call after the healthy machine. Sets X_KEY (final AC key of @x), GOOD_TREE
# (its Tree) and BZL_DIGEST (digest of defs.bzl in that Tree).
record_good_entry() {
  local found
  if ! found="$("${INSPECT[@]}" final-key "$HTTP_BASE" "$CACHE_LOG")"; then
    echo "ERROR: the healthy machine did not upload the entry of @x."
    echo "       See $WORK/healthy.out and $CACHE_LOG"
    exit 1
  fi
  read -r X_KEY GOOD_TREE <<< "$found"
  BZL_DIGEST="$("${INSPECT[@]}" file "$HTTP_BASE" "$GOOD_TREE" defs.bzl)"
  echo "good entry of @x: AC key ${X_KEY:0:12}, Tree ${GOOD_TREE:0:12}, defs.bzl ${BZL_DIGEST:0:12}"
}

# Prints the evidence and the verdict.
report() {
  local now
  now="$("${INSPECT[@]}" ac-tree "$HTTP_BASE" "$X_KEY" || true)"
  echo
  echo "--- bazel-remote log: AC requests for @x, reads of its good Tree, reads of defs.bzl"
  grep -E "^=== |GRPC AC (GET|GET NODEPSCHECK|PUT) $X_KEY|READ.*($GOOD_TREE|$BZL_DIGEST)" "$CACHE_LOG" \
    | sed -E 's/^[0-9/]+ //; s/([0-9a-f]{12})[0-9a-f]{52}/\1/g' || true
  echo
  echo "--- Tree of the good entry (${GOOD_TREE:0:12}):"
  "${INSPECT[@]}" tree "$HTTP_BASE" "$GOOD_TREE" || true
  echo "--- Tree that AC key ${X_KEY:0:12} points to now (${now:0:12}):"
  [[ "$now" == NOT_FOUND ]] && echo "    (AC entry not found)" || "${INSPECT[@]}" tree "$HTTP_BASE" "$now" || true
  echo
  if [[ "$now" != "$GOOD_TREE" && "$now" != NOT_FOUND ]] \
     && grep -q 'BUILD file not found' "$WORK/consumer.out"; then
    echo "RESULT: REPRODUCED. The poisoning machine replaced the good entry, and the"
    echo "        clean consumer machine fails with 'BUILD file not found'."
  else
    echo "RESULT: NOT REPRODUCED. See $WORK for the logs."
  fi
}
