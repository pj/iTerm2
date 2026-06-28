{
  description = "MemeTerminal — iTerm2 with SBIX color font support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      packages.${system}.default = pkgs.stdenvNoCC.mkDerivation {
        pname = "memeterminal";
        version = "0.0.1";

        src = pkgs.fetchurl {
          url = "https://github.com/pj/iTerm2/releases/download/v0.0.1/MemeTerminal.zip";
          sha256 = "1l4hrrfs4p8jmqs0j2scs2nxk4x550fx2azcrvyssqq2zjf31mh3";
        };

        nativeBuildInputs = [ pkgs.unzip ];

        sourceRoot = ".";
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;

        installPhase = ''
          mkdir -p "$out/Applications"
          cp -R MemeTerminal.app "$out/Applications/MemeTerminal.app"

          mkdir -p "$out/bin"
          printf '#!/bin/sh\nopen -na "%s/Applications/MemeTerminal.app" --args "$@"\n' "$out" \
            > "$out/bin/memeterminal"
          chmod +x "$out/bin/memeterminal"
        '';

        meta = {
          description = "iTerm2 with SBIX color font rendering for custom fonts";
          platforms = [ "aarch64-darwin" ];
        };
      };
    };
}
