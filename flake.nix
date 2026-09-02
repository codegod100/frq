{
  # frq is Jolt source, so "building" it is three things, not one:
  #
  #   jolt        the runtime that reads it        (github:jolt-lang/jolt)
  #   jolt-native libvidya and libjoltmoq, in Rust (gitlab:nandithebull/jolt-native)
  #   frq         this tree, with its deps resolved to store paths
  #
  # Jolt resolves deps.edn by running git at startup, which a build sandbox has
  # no network for — so every dep is fetched by Nix instead and handed back as
  # a :local/root through -Sdeps.
  #
  #   nix build .#frq && ./result/bin/frq
  #
  # On a machine that is not NixOS the GL driver is the host's and the loader
  # will not find it, so the window never opens ("GL display: argument does not
  # name a valid config"). The launcher handles that itself: off NixOS it hands
  # the process to nixGL, which puts the host's driver ahead of the store's.
  # Nothing extra to type, and a distrobox/container Arch is the same case as
  # a bare one.
  description = "frq — a freeq client in jolt";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Jolt's own flake declares `self.submodules`, which this Nix rejects when
    # the flake is fetched through the github scheme — so take the source and
    # build it here. `vendor/` is a submodule and the build needs it.
    jolt-src = {
      url = "git+https://github.com/jolt-lang/jolt?submodules=1";
      flake = false;
    };

    # v0.1.3, which is the rev deps.edn and the scripts/*.dotslash pins both
    # name. Pinned, and pinned to that: this input carries both halves of
    # glimmer-vidya — libvidya, and the Jolt side that binds it — so an
    # unpinned `main` is a build whose native half is free to sit at a
    # different commit from the tree that talks to it. It did, and what the
    # drift cost was silence: the Jolt half sent a reaction pill's hover card
    # to a libvidya with no handler for one, and the pill said nothing.
    jolt-native = {
      url = "git+https://gitlab.com/nandithebull/jolt-native?rev=fd0e21a6c5d745ff9d134f92f909665454a7a1c9";
      flake = false;
    };

    # The terminal backend, which v0.1.3 has not got: crates/jolt-tui (the tree
    # ABI over a grid of cells) and jolt/glimmer-tui (the jolt side that binds
    # it). Its own input rather than a bump of the one above, deliberately —
    # the window half stays pinned to the release the rest of the tree names,
    # and only `tui` evaluates this. When the backend ships in a release the
    # two become one pin again.
    jolt-native-tui = {
      url = "git+https://gitlab.com/nandithebull/jolt-native?rev=3cfee15a9d938584f526f606f853771eaad7f56c";
      flake = false;
    };

    # Chez itself, because the APK needs a cross target nixpkgs does not
    # build: frq's Scheme is compiled to an arm64 boot image, and that wants
    # Chez's own `tarm64le` workarea — boot files, xpatch and libkernel.a.
    # The version is the one the hand-built tree under ~/.cache used, and the
    # submodules are not optional (zuo builds it, lz4 and zlib link into it).
    # The fork jolt's own Android pin names, built here rather than fetched as
    # a release binary: upstream reads the socket address out of `struct
    # addrinfo` at glibc's offset, which on Bionic is `ai_canonname`, so an APK
    # built with upstream cannot open a TLS connection at all. Only the boot
    # image uses it; the desktop package still builds jolt-src.
    jolt-android-src = {
      url = "git+https://gitlab.com/nandithebull/jolt?rev=2b80d68d1f7a31ba92b208b3957e5fb555617ada&submodules=1";
      flake = false;
    };

    chez-src = {
      url = "git+https://github.com/cisco/ChezScheme?ref=refs/tags/v10.4.1&submodules=1";
      flake = false;
    };

    # The sha deps.edn pins, on the fork with the reconciler fixes.
    glimmer = {
      url = "git+https://gitlab.com/nandithebull/glimmer?rev=399df371c790d690fb6e4560c3d4d7f838502857";
      flake = false;
    };

    # Only ever used off NixOS, to put the host GL driver on the loader path.
    nixgl = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Wraps a closure into a single self-extracting file. Only the `appimage`
    # output evaluates it.
    nix-appimage = {
      url = "github:ralismark/nix-appimage";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, jolt-src, jolt-native, jolt-native-tui, glimmer, chez-src, jolt-android-src, nixgl, nix-appimage }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forEachSystem (pkgs:
        let
          inherit (pkgs) lib;

          # Mesa, despite the name: it covers Intel and AMD alike. The NVIDIA
          # wrappers are the ones that need --impure (they read the host kernel
          # module's version), which is why this only ever reaches for Intel.
          nixGL = nixgl.packages.${pkgs.stdenv.hostPlatform.system}.nixGLIntel;

          # libvidya (the retained-tree ABI glimmer-vidya binds, on egui) and
          # libjoltmoq (the AV media plane). One workspace, two cdylibs.
          native = pkgs.rustPlatform.buildRustPackage {
            pname = "jolt-native";
            version = "0.1.0";
            src = jolt-native;

            cargoLock = {
              lockFile = "${jolt-native}/Cargo.lock";
              allowBuiltinFetchGit = true;
            };

            nativeBuildInputs = with pkgs; [
              pkg-config
              cmake
              rustPlatform.bindgenHook
            ];

            buildInputs = with pkgs; [
              alsa-lib
              pipewire
              openssl
              libxkbcommon
              wayland
              libGL
            ];

            # Upstream's .cargo/config.toml drives the whole build through
            # DotSlash: a pinned rustc, sccache, and zig as the C/C++ compiler
            # and linker, each fetched from the network on first use. None of
            # that survives a build sandbox, and none of it is needed when the
            # toolchain comes from the store — so drop it and let stdenv's cc
            # link (openh264 is C++, which stdenv covers too).
            postPatch = ''
              rm -f .cargo/config.toml
            '';

            # bindgen reads linux/videodev2.h directly; upstream points it at
            # zig's bundled headers, which under Nix is just the kernel headers.
            V4L2R_VIDEODEV2_H_PATH = "${pkgs.linuxHeaders}/include";

            doCheck = false;

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/lib"
              install -m644 target/*/release/*.so "$out/lib/"
              runHook postInstall
            '';
          };

          # libjolttui alone, out of the tui input's workspace. One crate
          # rather than the whole of it: the terminal backend's dependencies
          # are crossterm and a width table, where libvidya's and libjoltmoq's
          # are egui, openh264 and v4l — none of which a terminal needs, and
          # all of which this would otherwise build a second time at a second
          # rev.
          nativeTui = pkgs.rustPlatform.buildRustPackage {
            pname = "jolt-tui";
            version = "0.1.0";
            src = jolt-native-tui;

            cargoLock = {
              lockFile = "${jolt-native-tui}/Cargo.lock";
              allowBuiltinFetchGit = true;
            };

            nativeBuildInputs = with pkgs; [ pkg-config cmake rustPlatform.bindgenHook ];
            buildInputs = with pkgs; [ alsa-lib pipewire openssl libxkbcommon wayland libGL ];

            cargoBuildFlags = [ "-p" "jolt-tui" ];

            # As above: upstream's .cargo/config.toml drives the build through
            # DotSlash, which a sandbox has no network for.
            postPatch = ''
              rm -f .cargo/config.toml
            '';

            V4L2R_VIDEODEV2_H_PATH = "${pkgs.linuxHeaders}/include";
            doCheck = false;

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/lib"
              install -m644 target/*/release/libjolttui.so "$out/lib/"
              runHook postInstall
            '';
          };

          # Jolt itself: Clojure on Chez, built the way its own flake builds it.
          # A function, because there are two of them — upstream for the
          # desktop, and the Bionic-addrinfo fork for the boot image the APK
          # carries. Nothing else about the build differs.
          joltFrom = src: pkgs.stdenv.mkDerivation {
            pname = "jolt";
            version = "dev";
            inherit src;

            strictDeps = true;
            nativeBuildInputs = with pkgs; [ chez makeWrapper pkg-config xxd ];
            buildInputs = with pkgs; [ lz4 zlib ncurses openssl libuuid ];

            JOLT_VERSION = "dev";
            dontConfigure = true;

            buildPhase = ''
              runHook preBuild
              scheme --script host/chez/build-jolt.ss release target/release/jolt
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin"
              install -m755 target/release/jolt "$out/bin/jolt"
              runHook postInstall
            '';

            # jolt.deps shells out to git and unzip, and jolt.mvn-http dlopens
            # OpenSSL through the JOLT_OPENSSL_LIBDIR seam.
            #
            # TZDIR so a zone *name* resolves wherever this runs: frq.clock
            # hands one to tzset, and glibc then looks for the tzfile under
            # /usr/share/zoneinfo unless told otherwise — which a NixOS host
            # does not have. The store's own tzdata is there on both kinds of
            # machine. --set-default, so a TZDIR the user set still wins.
            postFixup = ''
              wrapProgram "$out/bin/jolt" \
                --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.git pkgs.unzip ]}" \
                --set-default JOLT_OPENSSL_LIBDIR "${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}" \
                --set-default TZDIR "${pkgs.tzdata}/share/zoneinfo" \
                --set-default SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            '';
          };

          joltRuntime = joltFrom jolt-src;
          joltAndroid = joltFrom jolt-android-src;

          # glimmer-vidya lives inside the jolt-native checkout, and its own
          # deps.edn asks for glimmer by git — the top-level override below
          # answers for both.
          glimmerVidya = "${jolt-native}/jolt/glimmer-vidya";
          glimmerTui = "${jolt-native-tui}/jolt/glimmer-tui";

          # egui reaches for these with dlopen rather than linking them, so
          # being in the cdylib's buildInputs is not enough — the launcher has
          # to put them on the loader path itself. Without libX11 here, vidya
          # reports "X11 unavailable", falls back to Wayland, and winit refuses
          # to build a second event loop after the failed first one.
          runtimeLibs = with pkgs; [
            libGL
            libxkbcommon
            wayland
            xorg.libX11
            xorg.libXcursor
            xorg.libXi
            xorg.libXrandr
            vulkan-loader
          ];

          # The project as jolt sees it: source, deps.edn, nothing else.
          frqSource = pkgs.runCommand "frq-source" { } ''
            mkdir -p "$out"
            cp -r ${self}/src ${self}/deps.edn "$out/"
          '';

          # Jolt resolves deps.edn from the working directory, so the launcher
          # runs from the store copy. Its .jolt/cpcache write lands on a
          # read-only directory and jolt treats that as a quiet cache miss, so
          # the only cost is re-resolving the (already local) graph per start.
          frqScript = pkgs.writeShellScript "frq" ''
            export LD_LIBRARY_PATH="${native}/lib:${lib.makeLibraryPath runtimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            cd ${frqSource}

            # On NixOS the store's Mesa is the system's and the window opens.
            # Anywhere else the real driver is the host's, so defer to nixGL —
            # it prepends the host driver, which has to win over ours.
            runner=""
            [ -e /run/current-system ] || runner="${nixGL}/bin/nixGLIntel"

            exec ''${runner} ${joltRuntime}/bin/jolt \
              -Sdeps '{:deps {jolt-lang/glimmer {:local/root "${glimmer}"} nandi/glimmer-vidya {:local/root "${glimmerVidya}"}}}' \
              -M:frq "$@"
          '';

          # The same source, the other backend. No GL, no nixGL and no X11 —
          # a terminal is the one surface that needs nothing from the host but
          # a terminal, which is the reason this output exists.
          tuiScript = pkgs.writeShellScript "frq-tui" ''
            export LD_LIBRARY_PATH="${nativeTui}/lib:${native}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            cd ${frqSource}

            exec ${joltRuntime}/bin/jolt \
              -Sdeps '{:deps {jolt-lang/glimmer {:local/root "${glimmer}"} nandi/glimmer-vidya {:local/root "${glimmerVidya}"} nandi/glimmer-tui {:local/root "${glimmerTui}"}}}' \
              -m frq.tui "$@"
          '';

          tui = pkgs.runCommand "frq-tui-0.1.0"
            {
              meta = {
                description = "frq's screens in a terminal";
                mainProgram = "frq-tui";
                platforms = systems;
              };
            }
            ''
              mkdir -p "$out/bin"
              ln -s ${tuiScript} "$out/bin/frq-tui"
            '';

          frq = pkgs.runCommand "frq-0.1.0"
            {
              meta = {
                description = "A freeq client in jolt";
                mainProgram = "frq";
                platforms = systems;
              };
            }
            ''
              mkdir -p "$out/bin"
              ln -s ${frqScript} "$out/bin/frq"
            '';
          # --- Android ------------------------------------------------------
          # The SDK and the NDK are Google's, which means unfree and a licence
          # to accept — so this is its own import of nixpkgs rather than the
          # `legacyPackages` everything above uses. Confined to the Android
          # outputs: `nix build` of frq itself never evaluates it.
          #
          # The NDK here is r29, which is the version scripts/android-ndk.dotslash
          # pins and the one the pinned libvidya was built with.
          androidPkgs = import nixpkgs {
            inherit (pkgs.stdenv.hostPlatform) system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };

          androidComposition = androidPkgs.androidenv.composeAndroidPackages {
            buildToolsVersions = [ "36.0.0" ];
            platformVersions = [ "36" ];
            includeNDK = true;
          };

          android = import ./nix/android.nix {
            inherit pkgs self chez-src jolt-native glimmer joltAndroid;
            inherit (pkgs) lib;
            androidSdk = androidComposition.androidsdk;
            ndk = androidComposition.ndk-bundle;
          };
        in
        {
          inherit native frq;
          inherit nativeTui tui;
          jolt = joltRuntime;
          default = frq;

          # frq and everything it loads, squashed into one runnable file for
          # hosts without Nix. The whole closure rides along — Mesa included,
          # which is not waste: off NixOS the launcher goes through nixGL, and
          # nixGL needs a store Mesa to put the host's driver in front of.
          appimage =
            nix-appimage.bundlers.${pkgs.stdenv.hostPlatform.system}.default frq;
        }
        # An APK is built by a linux-x86_64 NDK and a linux-x86_64 jolt, and
        # Google ships no other; on aarch64 the Android outputs are simply
        # absent rather than present and broken.
        // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          inherit (android) apk chezAndroid joltBoot libjoltapp;
          apk-unsigned = android.apk-unsigned;
        });

      apps = forEachSystem (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.frq}/bin/frq";
        };
        tui = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.tui}/bin/frq-tui";
        };
      });
    };
}
