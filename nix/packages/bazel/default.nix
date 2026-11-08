{
  stdenv,
  fetchurl,
  buildFHSEnv,
  zlib,
  jdk,
}:

let
  version = "8.8.2";

  bazel_nojdk = stdenv.mkDerivation rec {
    pname = "bazel_nojdk";
    inherit version;

    src = fetchurl {
      url = "https://github.com/bazelbuild/bazel/releases/download/${version}/bazel_nojdk-${version}-linux-x86_64";
      hash = "sha256-KdxFTCzLK6L+gG6wECFcWBQF1cJzziJqDBzSn7lI1rs=";
    };

    dontUnpack = true;
    dontPatch = true;
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      install -Dm755 $src $out/bin/bazel

      runHook postInstall
    '';
  };
in
buildFHSEnv {
  pname = "bazel";
  inherit version;
  targetPkgs = _: [
    zlib
    jdk
    bazel_nojdk
  ];
  runScript = "bazel";
}
