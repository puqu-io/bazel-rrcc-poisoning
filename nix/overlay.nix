final: _prev: {
  bazel_prebuilt = final.callPackage ./packages/bazel {
    jdk = final.jdk25_headless;
  };
  bazel_build_env = final.callPackage ./packages/bazel-build-env { };
}
