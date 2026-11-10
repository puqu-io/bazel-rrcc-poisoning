# bazel-rrcc-poisoning

Reproduction and fix for a cache poisoning defect in Bazel 8.8.2 with `--experimental_remote_repo_contents_cache`.

A client that cannot download the `.bzl` files of a cached repo replaces the cache entry of that repo with an incomplete one. Every other client then fails with:

```
ERROR: no such package '@@+_repo_rules2+x//': BUILD file not found in directory '' of external repository @@+_repo_rules2+x.
```

On a cache hit, Bazel deletes `external/<repo>` and then downloads the `.bzl` files. If a download fails, Bazel silently treats the hit as a miss and runs the repo rule. The rule runs on a worker thread. When it needs a value that Skyframe has not computed, the worker pauses and the function around it restarts. In 8.8.2 the restarted function does the cache lookup again. The lookup deletes the directory a second time, now with the rule's files in it. The rule then finishes in the emptied directory, and Bazel uploads the remaining files under the key of the complete repo.

We hit this with a `zstd-jni` native library that cannot load. A corrupted or missing blob has the same effect. Bazel 9.3.2 and later are not affected.

The full write-up with diagrams and code links: `docs/rrcc-poisoning-rca.md`.

## Repro

```sh
nix develop
./repro_zstd.sh
```

Runs three Bazel clients with separate output user roots against one `bazel-remote`:

- `healthy`: fetches `@x` and uploads the good entry.
- `poisoner`: zstd cannot load (`--host_jvm_args=-DZstdNativePath=<not a library>`). Replaces the entry.
- `consumer`: clean state. Fails.

Expected end of the report:

```
--- Tree of the good entry (92de23e2d30f):
    BUILD.bazel (6 bytes)
    REPO.bazel (0 bytes)
    __config__/
    __config__/BUILD.bazel (8 bytes)
    __config__/defs.bzl (3250 bytes)
    defs.bzl (3730 bytes)
    metadata.json (2 bytes)
    package.json (2 bytes)
--- Tree that AC key ef382484fd7d points to now (1815ce9c6834):
    REPO.bazel (0 bytes)
    __config__/
    __config__/BUILD.bazel (8 bytes)
    __config__/defs.bzl (3250 bytes)
    package.json (2 bytes)

RESULT: REPRODUCED.
```

The rule in `ws/repos.bzl` writes six files. The first label from `@tpl//__config__` causes a restart after the third write, so `BUILD.bazel`, `defs.bzl` and `metadata.json` are lost. The bazel-remote log shows three reads of the good Tree: the first lookup plus two restarts. It shows no read of the `.bzl` files, because zstd fails before the RPC.

To confirm the cause, change one condition at a time. `BREAK_ZSTD=0 ./repro_zstd.sh` does not reproduce: the downloads succeed, so the lookup is a clean hit. `POISONER_FLAGS=--experimental_worker_for_repo_fetching=off ./repro_zstd.sh` does not reproduce either: without the worker thread, a restart runs the rule again from scratch. That flag is also the interim workaround. `NOEXEC_DIR=/mnt/noexec ./repro_zstd.sh` reproduces with the zstd temp folder on a `noexec` mount, as in production.

Outside the flake, set `BAZEL` and `BAZEL_REMOTE`. The script needs `python3` and `curl` and ports 9092 and 9093.

## Fix

`patches/` holds three patches against the Bazel 8.8.2 sources. Patch 0001 stops the lookup from running again after the rule starts. It closes the defect. Patch 0002 prints a warning with the cause when a download fails after a cache hit. Bazel then fetches locally, as before. Patch 0003 adds the regression test `testLookupNotRepeatedWhileWorkerFetchIsRunning` to `remote_repo_contents_cache_test.py`.

Build Bazel with the patches, then run the repro and the test with it:

```sh
nix run .#bazel-build-env -- ./build_bazel.sh
nix run .#bazel-build-env -- -c 'TMPDIR=$PWD/build/tmp BAZEL=$PWD/build/bazel-8.8.2-rrcc ./repro_zstd.sh'   # expect NOT REPRODUCED and the warning
nix run .#bazel-build-env -- -c 'BAZEL=$PWD/build/bazel-8.8.2-rrcc ./run_regression_test.sh'
```

The build environment has a private `/tmp`, so `TMPDIR` keeps the repro's work directory (logs, cache data) after the run. `build_bazel.sh` clones tag 8.8.2 into `build/bazel-src`, applies the patches, builds `//src:bazel-dev` with Bazelisk as bootstrap, and copies the result to `build/bazel-8.8.2-rrcc`. `PATCHES=0` builds the unpatched version. `run_regression_test.sh` runs the new test in `build/bazel-src`. The test uses a corrupted `.bzl` blob instead of broken zstd, because Bazel's test remote worker does not support compression. Both take the same path in Bazel.

## Files

- `repro_zstd.sh`, `lib.sh`: the repro. `tools/inspect_cache.py`: reads AC entries and Trees from bazel-remote.
- `ws/`: the test workspace.
- `patches/`, `build_bazel.sh`, `run_regression_test.sh`: the fix and its test.
- `flake.nix`, `nix/`: Bazel 8.8.2 and bazel-remote (`nix develop`), and the clean build environment (`nix run .#bazel-build-env`, a login shell in an FHS sandbox with Bazelisk, JDK 21 and gcc).
- `docs/`: the root cause analysis (`rrcc-poisoning-rca.md`) and its diagrams.
