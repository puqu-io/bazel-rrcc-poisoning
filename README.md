# bazel-rrcc-poisoning

Reproduction and fix for a cache poisoning defect in Bazel 8.8.2 with `--experimental_remote_repo_contents_cache`.

A client that cannot download the prefetched `.bzl` files of a cached repo uploads an incomplete repo under the same action key as the complete one. Every other client then fails with:

```
ERROR: no such package '@@+_repo_rules2+x//': BUILD file not found in directory '' of external repository @@+_repo_rules2+x.
```

Root cause: `RepositoryDelegatorFunction.compute()` runs the cache lookup on every Skyframe restart. The lookup deletes `external/<repo>` before it prefetches the cached files. When the repo rule runs on a worker thread, a restart in the middle of the fetch runs the lookup again under the running rule. If the prefetch fails, the worker continues in the deleted directory, and Bazel uploads the remaining files. The trigger we hit is a `zstd-jni` native library that cannot load. A corrupted CAS blob, a blob missing from a server that does not check AC entries, or a network error take the same path. Bazel 9.3.2 and later are not affected.

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

The rule in `ws/repos.bzl` writes six files. The first label from `@tpl//__config__` causes a Skyframe restart after the third write, so `BUILD.bazel`, `defs.bzl` and `metadata.json` are lost. The bazel-remote log shows three reads of the good Tree (first lookup plus two restarts). It shows no read of the `.bzl` files, because zstd fails before the RPC.

Controls:

| Command | Result |
|---|---|
| `BREAK_ZSTD=0 ./repro_zstd.sh` | NOT REPRODUCED. Working zstd, cache hit. |
| `POISONER_FLAGS=--experimental_worker_for_repo_fetching=off ./repro_zstd.sh` | NOT REPRODUCED. Without the worker, each restart reruns the rule from the start. |
| `NOEXEC_DIR=/mnt/noexec ./repro_zstd.sh` | REPRODUCED. zstd temp folder on a `noexec` mount, the production cause. |

Outside the flake, set `BAZEL` and `BAZEL_REMOTE`. The script needs `python3` and `curl` and ports 9092 and 9093.

## Fix

`patches/`, against the Bazel 8.8.2 sources:

| Patch | Change |
|---|---|
| `0001-repo-fetch-skip-remote-lookup-once-worker-started.patch` | No cache lookup while a worker thread fetches the repo (`RepositoryFunction.isFetchInProgressOrDone`, `WorkerSkyKeyComputeState.hasStartedWorker`). Closes the defect. |
| `0002-rrcc-report-failed-injection-instead-of-silent-miss.patch` | A failed prefetch produces `WARNING: Remote repo contents cache lookup failed for @@...: ... (download error: ...)` with the root cause, then a local fetch. |
| `0003-rrcc-regression-test-lookup-during-worker-fetch.patch` | `testLookupNotRepeatedWhileWorkerFetchIsRunning` in `src/test/py/bazel/bzlmod/remote_repo_contents_cache_test.py`. |

Build Bazel with the patches, then run the repro and the test with it:

```sh
nix run .#bazel-build-env -- ./build_bazel.sh
nix run .#bazel-build-env -- -c 'TMPDIR=$PWD/build/tmp BAZEL=$PWD/build/bazel-8.8.2-rrcc ./repro_zstd.sh'   # expect NOT REPRODUCED and the warning
nix run .#bazel-build-env -- -c 'BAZEL=$PWD/build/bazel-8.8.2-rrcc ./run_regression_test.sh'
```

The build environment has a private `/tmp`, so `TMPDIR` keeps the repro's work directory (logs, cache data) after the run. `build_bazel.sh` clones tag 8.8.2 into `build/bazel-src`, applies the patches, builds `//src:bazel-dev`, and copies the result to `build/bazel-8.8.2-rrcc`. `PATCHES=0` builds the unpatched version. `run_regression_test.sh` runs the new test in `build/bazel-src`. The test uses a corrupted `.bzl` blob instead of broken zstd, because Bazel's test remote worker does not support compression. Both take the same path in Bazel.
