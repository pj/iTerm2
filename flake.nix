{
  description = "MemeTerminal — iTerm2 with SBIX color font support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };

      xcodeWrapper = pkgs.xcodeenv.composeXcodeWrapper {
        xcodeBaseDir = "/Applications/Xcode.app";
      };
    in
    {
      packages.${system}.default = pkgs.stdenvNoCC.mkDerivation {
        pname = "memeterminal";
        version = "0.0.1";

        # fetchGit with submodules to include submodule content in the store
        src = builtins.fetchGit {
          url = "file:///Users/pauljohnson/Programming/iTerm2";
          submodules = true;
        };

        # Impure: needs host Xcode, network (rustup/SPM).
        # Requires /var/empty/Library to be writable by nixbld group —
        # see nix-darwin activation script in dotfiles/nix.
        __noChroot = true;

        nativeBuildInputs = with pkgs; [
          xcodeWrapper
          cmake
          pkg-config
          automake
          autoconf
          libtool
          perl
          python3
          cacert
          curl
          gnumake
          gnused
          coreutils
        ];

        hardeningDisable = [ "all" ];
        dontConfigure = true;
        dontFixup = true;

        # Source tree must be writable (Makefile builds inside submodules/)
        postUnpack = ''
          chmod -R u+w $sourceRoot
        '';

        buildPhase = ''
          export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
          export SDKROOT=$(/usr/bin/xcrun --show-sdk-path)

          # xcodebuild uses NSHomeDirectory() (password-database lookup, not
          # $HOME env) which returns /var/empty for nixbld — read-only.
          # We must change the actual user record so NSHomeDirectory() returns
          # a writable path. We use dscl to temporarily redirect it.
          export FAKE_HOME="$TMPDIR/fakehome"
          mkdir -p "$FAKE_HOME/Library/Developer/Xcode"
          mkdir -p "$FAKE_HOME/Library/Developer/CoreSimulator/Devices"
          mkdir -p "$FAKE_HOME/Library/Caches"
          mkdir -p "$FAKE_HOME/Library/org.swift.swiftpm"
          export HOME="$FAKE_HOME"

          export DERIVED_DATA="$TMPDIR/DerivedData"
          mkdir -p "$DERIVED_DATA"

          # Override NSHomeDirectory() so xcodebuild/SPM see a writable home.
          # NSHomeDirectory() reads the password database, not $HOME, and
          # returns /var/empty for nixbld users. This dylib intercepts it.
          cat > "$TMPDIR/homedir_override.c" <<'HOMEDIREOF'
#include <Foundation/Foundation.h>
NSString *NSHomeDirectory(void) {
    char *h = getenv("HOME");
    if (h) return [NSString stringWithUTF8String:h];
    return @"/tmp";
}
HOMEDIREOF
          /usr/bin/clang -dynamiclib -framework Foundation \
            -isysroot "$SDKROOT" -x objective-c \
            -o "$TMPDIR/homedir_override.dylib" \
            "$TMPDIR/homedir_override.c"
          export DYLD_INSERT_LIBRARIES="$TMPDIR/homedir_override.dylib"

          # Install rustup + cbindgen
          export RUSTUP_HOME="$TMPDIR/rustup"
          export CARGO_HOME="$TMPDIR/cargo"
          if [ ! -f "$CARGO_HOME/bin/rustup" ]; then
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
          fi
          export PATH="$CARGO_HOME/bin:${xcodeWrapper}/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"

          # xcodebuild wrapper: redirect all build artifacts to writable dirs.
          # -derivedDataPath only works with -scheme, not -target, so we
          # must use OBJROOT/SHARED_PRECOMPS_DIR for -target builds and
          # -derivedDataPath for -scheme builds.
          mkdir -p "$TMPDIR/xcode-wrapper"
          cat > "$TMPDIR/xcode-wrapper/xcodebuild" <<'EOF'
#!/bin/bash
has_scheme=false
for arg in "$@"; do
  if [ "$arg" = "-scheme" ]; then
    has_scheme=true
    break
  fi
done
if $has_scheme; then
  exec /usr/bin/xcodebuild -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages" -packageCachePath "$DERIVED_DATA/PackageCache" "$@"
else
  exec /usr/bin/xcodebuild OBJROOT="$DERIVED_DATA/Build/Intermediates.noindex" SHARED_PRECOMPS_DIR="$DERIVED_DATA/Build/Intermediates.noindex/PrecompiledHeaders" "$@"
fi
EOF
          chmod +x "$TMPDIR/xcode-wrapper/xcodebuild"
          export PATH="$TMPDIR/xcode-wrapper:$PATH"

          rustup default stable
          rustup target add x86_64-apple-darwin
          command -v cbindgen || cargo install cbindgen

          # The Makefile hardcodes PATH, overriding ours. Patch it to
          # prepend our xcode wrapper directory so our xcodebuild wrapper
          # takes priority.
          awk -v wrap="$TMPDIR/xcode-wrapper" '{
            if (/^PATH := /) print "PATH := " wrap ":$(PATH)"
            else print
          }' Makefile > Makefile.tmp && mv Makefile.tmp Makefile

          # Set up plist — rename to MemeTerminal
          cp plists/dev-iTerm2.plist plists/iTerm2.plist
          /usr/bin/plutil -replace CFBundleName -string "MemeTerminal" plists/iTerm2.plist
          /usr/bin/plutil -replace CFBundleIdentifier -string "com.googlecode.iterm2.meme" plists/iTerm2.plist

          # The sfsymbolenum target needs SF Symbols.app which may not be
          # installed. The generated files already exist in ThirdParty/, so
          # patch the Makefile to skip regeneration.
          awk '{
            if (/^sfsymbolenum:/) { print "sfsymbolenum:"; skip=1; next }
            if (skip && /^\t/) next
            skip=0; print
          }' Makefile > Makefile.tmp && mv Makefile.tmp Makefile

          # Build native deps then the app
          export BUILD_DIR="$TMPDIR/build"
          make deps BUILD_DIR="$BUILD_DIR" CMAKE=$(which cmake) PKG_CONFIG=$(which pkg-config)
          make Development BUILD_DIR="$BUILD_DIR"
        '';

        installPhase = ''
          mkdir -p "$out/Applications"
          cp -r "$TMPDIR/build/Development/iTerm2.app" "$out/Applications/MemeTerminal.app"

          /usr/bin/plutil -replace CFBundleName -string "MemeTerminal" \
            "$out/Applications/MemeTerminal.app/Contents/Info.plist" 2>/dev/null || true
          /usr/bin/plutil -replace CFBundleIdentifier -string "com.googlecode.iterm2.meme" \
            "$out/Applications/MemeTerminal.app/Contents/Info.plist" 2>/dev/null || true

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
