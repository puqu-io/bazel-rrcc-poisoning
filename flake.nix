{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      system = "x86_64-linux";
      inherit (nixpkgs) lib;

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      };
    in
    {
      overlays = {
        default = lib.composeManyExtensions [
          (import ./nix/overlay.nix)
        ];
      };

      packages.${system} = {
        bazel = pkgs.bazel_prebuilt;
        default = pkgs.bazel_prebuilt;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.bazel_prebuilt
          pkgs.jdk25_headless
          pkgs.bazel-remote
          pkgs.git
          pkgs.nixfmt
          pkgs.bc
          pkgs.coreutils
          pkgs.gnugrep
        ];
      };
    };
}
