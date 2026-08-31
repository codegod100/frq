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
  # name a valid config"). Launch through nixGL there:
  #
  #   nix run --impure "git+https://github.com/nix-community/nixGL#nixGLIntel" -- ./result/bin/frq
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

    jolt-native = {
      url = "git+https://gitlab.com/nandithebull/jolt-native";
      flake = false;
    };

    # The sha deps.edn pins, on the fork with the reconciler fixes.
    glimmer = {
      url = "git+https://gitlab.com/nandithebull/glimmer?rev=399df371c790d690fb6e4560c3d4d7f838502857";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, jolt-src, jolt-native, glimmer }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forEachSystem (pkgs:
        let
          inherit (pkgs) lib;

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

          # Jolt itself: Clojure on Chez, built the way its own flake builds it.
          joltRuntime = pkgs.stdenv.mkDerivation {
            pname = "jolt";
            version = "dev";
            src = jolt-src;

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
            postFixup = ''
              wrapProgram "$out/bin/jolt" \
                --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.git pkgs.unzip ]}" \
                --set-default JOLT_OPENSSL_LIBDIR "${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}" \
                --set-default SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            '';
          };

          # glimmer-vidya lives inside the jolt-native checkout, and its own
          # deps.edn asks for glimmer by git — the top-level override below
          # answers for both.
          glimmerVidya = "${jolt-native}/jolt/glimmer-vidya";

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
            exec ${joltRuntime}/bin/jolt \
              -Sdeps '{:deps {jolt-lang/glimmer {:local/root "${glimmer}"} nandi/glimmer-vidya {:local/root "${glimmerVidya}"}}}' \
              -M:frq "$@"
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
        in
        {
          inherit native frq;
          jolt = joltRuntime;
          default = frq;
        });

      apps = forEachSystem (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.frq}/bin/frq";
        };
      });
    };
}
