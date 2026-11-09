{ pkgs ? import <nixpkgs> { } }:

let
  inherit (pkgs) lib;

  bazelrc = pkgs.writeText "bazel-build-env.bazelrc" ''
    common --incompatible_strict_action_env
  '';

  bazel = pkgs.writeShellScriptBin "bazel" ''
    exec ${pkgs.bazelisk}/bin/bazelisk \
      --nosystem_rc --nohome_rc --bazelrc=${bazelrc} "$@"
  '';

  cleanShell = pkgs.writeShellScript "bazel-build-env-shell" ''
    exec env -i \
      HOME="$HOME" \
      USER="$USER" \
      LOGNAME="''${LOGNAME:-$USER}" \
      TERM="''${TERM:-dumb}" \
      LANG=C.UTF-8 \
      PATH=/usr/bin:/usr/sbin \
      bash --login "$@"
  '';

  fhs = pkgs.buildFHSEnv {
    name = "bazel-build-env-fhs";

    targetPkgs = p: [
      bazel
      p.bazel-remote

      p.jdk21_headless

      p.gcc
      p.binutils
      p.stdenv.cc.cc.lib # libstdc++ for bazel-dev and downloaded tools
      p.zlib

      p.python3
      p.zip
      p.unzip
      p.git
      p.gnupatch
      p.curl
      p.which
      p.file
      p.coreutils
      p.gnugrep
      p.gnused
      p.gawk
      p.findutils
      p.diffutils
      p.gnutar
      p.gzip
      p.bzip2
      p.xz
      p.procps
      p.hostname
    ];

    profile = ''
      export PATH=/usr/bin:/usr/sbin
      export CC=/usr/bin/gcc
      export JAVA_HOME=${pkgs.jdk21_headless.home}
      export BAZELISK_HOME="$HOME/.cache/bazelisk"
    '';

    privateTmp = true;
    unshareIpc = true;
    unsharePid = true;
    unshareUts = true;
    dieWithParent = true;

    extraBwrapArgs = [
      "--bind" "\"$BAZEL_BUILD_ENV_HOME\"" "\"$HOME\""
      "--bind" "\"$PWD\"" "\"$PWD\""
    ];

    runScript = cleanShell;
  };
in
pkgs.writeShellScriptBin "bazel-build-env" ''
  export BAZEL_BUILD_ENV_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}/bazel-build-env/home"
  mkdir -p "$BAZEL_BUILD_ENV_HOME"
  exec ${fhs}/bin/bazel-build-env-fhs "$@"
''
