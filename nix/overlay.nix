final: _prev: {
  bazel_prebuilt = final.callPackage ./packages/bazel {
    jdk = final.jdk25_headless;
  };
}
