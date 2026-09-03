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

    # Ahead of v0.1.3, which is what deps.edn and the scripts/*.dotslash pins
    # name — and deliberately: the pins are the last release, and this is what
    # `just run` builds, so a change to jolt-native can be run before there is
    # a release to fetch. The two meet again at `just bump`.
    #
    # Pinned all the same, and pinned to a rev: this input carries both halves of
    # glimmer-vidya — libvidya, and the Jolt side that binds it — so an
    # unpinned `main` is a build whose native half is free to sit at a
    # different commit from the tree that talks to it. It did, and what the
    # drift cost was silence: the Jolt half sent a reaction pill's hover card
    # to a libvidya with no handler for one, and the pill said nothing.
    # It also carries the terminal backend — crates/jolt-tui, the same tree ABI
    # over a grid of cells, and jolt/glimmer-tui beside glimmer-vidya. That was
    # a second input at a second rev while it lived on a branch, which is the
    # drift this comment warns about wearing a different hat: one input, and
    # the window and the terminal are the same library either way.
    jolt-native = {
      url = "git+https://gitlab.com/nandithebull/jolt-native?rev=258bbc5161b93d580a4c84363acabe63b0624e88";
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

  outputs = { self, nixpkgs, jolt-src, jolt-native, glimmer, chez-src, jolt-android-src, nixgl, nix-appimage }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Mesa, despite the name: it covers Intel and AMD alike. The NVIDIA
      # wrappers are the ones that need --impure (they read the host kernel
      # module's version), which is why this only ever reaches for Intel.
      #
      # Built from nixGL's default.nix rather than taken from its flake
      # outputs, for the one argument the flake hardcodes on: `enable32bits`,
      # which on x86_64 puts a second, i686 copy of mesa, its LLVM, and
      # intel-media-driver into the wrapper. frq is 64-bit on both halves —
      # the Rust cdylibs and the Chez runtime — so nothing here ever opens the
      # 32-bit driver, and carrying it is most of the dev shell's closure.
      nixGLFor = pkgs: (import nixgl {
        inherit pkgs;
        enable32bits = false;
      }).nixGLIntel;

      # egui reaches for these with dlopen rather than linking them, so being
      # in the cdylib's buildInputs is not enough — whatever starts frq has to
      # put them on the loader path itself. Without libx11 here, vidya reports
      # "X11 unavailable", falls back to Wayland, and winit refuses to build a
      # second event loop after the failed first one.
      #
      # Out here rather than beside the package that first needed them: the
      # dev shell starts frq too, on this tree's source rather than the store's
      # copy of it, and a second copy of this list is a second chance for the
      # two ways of running to disagree about what the window needs.
      runtimeLibsFor = pkgs: with pkgs; [
        libGL
        libxkbcommon
        wayland
        libx11
        libxcursor
        libxi
        libxrandr
        vulkan-loader
      ];
    in
    {
      packages = forEachSystem (pkgs:
        let
          inherit (pkgs) lib;

          nixGL = nixGLFor pkgs;

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
            # OpenSSL through the JOLT_OPENSSL_LIBDIR seam. gitMinimal rather
            # than git: all jolt.deps asks for is clone/fetch/rev-parse, and
            # the full package carries Perl and Python for the subcommands
            # written in them — a quarter of a gigabyte for git-send-email.
            #
            # TZDIR so a zone *name* resolves wherever this runs: frq.clock
            # hands one to tzset, and glibc then looks for the tzfile under
            # /usr/share/zoneinfo unless told otherwise — which a NixOS host
            # does not have. The store's own tzdata is there on both kinds of
            # machine. --set-default, so a TZDIR the user set still wins.
            postFixup = ''
              wrapProgram "$out/bin/jolt" \
                --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.gitMinimal pkgs.unzip ]}" \
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
          glimmerTui = "${jolt-native}/jolt/glimmer-tui";

          runtimeLibs = runtimeLibsFor pkgs;

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
            export LD_LIBRARY_PATH="${native}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
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
          # The NDK here is r29, which is the one the pinned libvidya was
          # built with.
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
          inherit tui;
          jolt = joltRuntime;
          default = frq;

          # The interpreter scripts/ is written in, named here so that
          # scripts/bb can build it. Nothing else in this flake uses it: it is
          # an output because a shell script cannot ask for `nixpkgs#babashka`
          # at the version this tree pins, and `.#bb` is exactly that.
          bb = pkgs.babashka;

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

      # Where `just run` runs, and — because entering it realises what it
      # names — what builds the half of frq that is not this working tree.
      #
      # The two halves, and the split is the whole point of the shell. The frq
      # source is the files on disk, uncommitted edits and all. Everything
      # under it — jolt, glimmer, glimmer-vidya, both native objects — is the
      # flake's, at the revs flake.lock names, so a run says what it ran
      # against and both halves of glimmer-vidya move together. That is the
      # drift the `jolt-native` input's comment is about, and a pin frq can
      # answer for is worth more here than the convenience of a checkout.
      #
      # `native` is the cargo build of that input rather than jolt-native's own
      # buck2 graph, which is a compromise and not a free one: buck2 is what
      # its CI runs and what makes its releases, and its cpal has the pipewire
      # feature this one does not, so device *names* in a call come out as ALSA
      # PCMs. What it buys is a derivation — one thing nixbuild.net can be
      # handed. The buck2 build fetches its rustc, zig and every third-party
      # crate as it goes and writes buck-out into the tree it builds; a sandbox
      # with no network and a read-only store is the one place it cannot run,
      # so on a remote builder it is not a slower option but no option at all.
      #
      # Nothing here says "nixbuild", though: it is a plain derivation, and
      # where it gets built is the machine's business. scripts/run.bb asks for
      # the shell with --max-jobs 0, which is what sends it to the `builders`
      # entry rather than compiling egui on a laptop.
      devShells = forEachSystem (pkgs:
        let
          inherit (pkgs) lib;
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) jolt native;
        in
        {
          default = pkgs.mkShellNoCC {
            name = "frq";

            # jolt, because the runtime frq is run by should be the flake's
            # too. nixGL for the same reason the launcher reaches for it — see
            # frqScript. babashka because scripts/bb prefers one on PATH, and
            # inside here that should be this one rather than a second copy
            # built through `.#bb`. just so the recipe runner comes from here
            # too rather than the host — `nix develop` and then `just run` is
            # the whole of what a machine with nix needs.
            packages = [ jolt pkgs.babashka pkgs.just (nixGLFor pkgs) ];

            # Read by scripts/run.bb rather than baked into a wrapper: the frq
            # source `just run` runs is the working tree, so the launcher has
            # to be a script in that tree and the shell has to hand it its
            # answers. Naming these is also what makes the shell build them.
            JOLT_NATIVE_LIB = "${native}/lib";
            GLIMMER_SRC = glimmer;
            GLIMMER_VIDYA_SRC = "${jolt-native}/jolt/glimmer-vidya";
            GLIMMER_TUI_SRC = "${jolt-native}/jolt/glimmer-tui";
            FRQ_LIB_PATH = lib.makeLibraryPath (runtimeLibsFor pkgs);
            NIXGL = "${nixGLFor pkgs}/bin/nixGLIntel";
          };
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
