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
    # `git+https` with `?submodules=1` rather than the github scheme: Jolt's
    # own flake declares `self.submodules`, which this Nix rejects when the
    # flake is fetched as `github:`. Its outputs are not what we take — the
    # runtime is built here, by joltFrom — but it is a flake all the same, so
    # its own inputs are locked with ours rather than left to float, and
    # `vendor/` comes along as the submodule the build needs.
    #
    # The fork rather than jolt-lang/jolt: it is what jolt-android-src already
    # pins for the boot image, and a desktop runtime built from a different
    # tree than the APK's is the same drift the jolt-native comment warns
    # about. Unpinned here — the desktop follows the fork's main, while the
    # APK stays on the rev below.
    jolt-src = {
      url = "git+https://gitlab.com/nandithebull/jolt?submodules=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The source half of jolt-native: the Jolt code under glimmer-backends/ that
    # binds the native objects, and the flake that builds the desktop ones. The
    # Android objects no longer come from here — jolt-native-android below
    # fetches those prebuilt — so this input is what `just run` builds against
    # and what an APK's Clojure side is read from, both at this rev.
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
      url = "git+https://gitlab.com/nandithebull/jolt-native?rev=d970307ccf1fe67e2e971f2837d2282d8ba79a62";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # moq-ffi's source, for the object frq.moq.* binds.
    #
    # Built here rather than taken from the release, and the reason is a
    # feature flag: `audio` and `video` are moq-ffi's defaults and are OFF in
    # the Linux and Android artifacts upstream publishes. Those two carry the
    # codecs — Opus through moq-audio, H.264 through moq-video's vendored
    # openh264 — so the published object can move a frame but cannot make one.
    # A call needs an encoder, so the choice is to build this once or to bind
    # libopus and openh264 separately and reimplement what moq-video already
    # does. Once, here.
    #
    # It is not free: this is the 440-crate build that fetching avoided, which
    # makes a substituter matter more now rather than less. What it is not is
    # a per-build cost — the pin below moves when someone moves it.
    moq-src = {
      url = "github:kixelated/moq/moq-ffi-v0.3.17";
      flake = false;
    };

    # The Android objects, prebuilt by jolt-native's CI rather than compiled
    # here: an APK needs libvidya and libjoltmoq for arm64, and building them
    # locally means an NDK, a Rust cross toolchain and the whole crane graph
    # for two files that upstream already built and published.
    #
    # "latest" is the version its CI overwrites on every default-branch build,
    # so this input finds a new one on `nix flake update` -- but flake.lock
    # still records exactly which bytes an APK was built from, which is the
    # pin that matters. `just bump` decides when to move; this only decides
    # where to look. The archive is rooted at include/ and lib/arm64-v8a/, so
    # nothing here has to unpack it.
    jolt-native-android = {
      url = "https://gitlab.com/api/v4/projects/nandithebull%2Fjolt-native/packages/generic/jolt-native/latest/android-arm64-v8a.tar.gz";
      flake = false;
    };

    # Chez itself, because the APK needs a cross target nixpkgs does not
    # build: frq's Scheme is compiled to an arm64 boot image, and that wants
    # Chez's own `tarm64le` workarea — boot files, xpatch and libkernel.a.
    # The version is the one the hand-built tree under ~/.cache used, and the
    # submodules are not optional (zuo builds it, lz4 and zlib link into it).
    # The same fork jolt-src takes, built here rather than fetched as a
    # release binary: upstream reads the socket address out of `struct
    # addrinfo` at glibc's offset, which on Bionic is `ai_canonname`, so an APK
    # built with upstream cannot open a TLS connection at all. Pinned to a rev
    # where jolt-src is not: the APK is a release artefact, so its runtime
    # moves when `just bump` says so rather than when the fork does.
    jolt-android-src = {
      url = "git+https://gitlab.com/nandithebull/jolt?rev=2b80d68d1f7a31ba92b208b3957e5fb555617ada&submodules=1";
      inputs.nixpkgs.follows = "nixpkgs";
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

  outputs = { self, nixpkgs, jolt-src, jolt-native, jolt-native-android, moq-src, glimmer, chez-src, jolt-android-src, nixgl, nix-appimage }:
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

          # libvidya (the retained-tree ABI glimmer-vidya binds, on egui),
          # libjolttui (the same tree over a grid of cells) and libjoltmoq (the
          # AV media plane) — one workspace, three cdylibs, taken from
          # jolt-native's own flake rather than rebuilt here.
          #
          # This used to be a rustPlatform.buildRustPackage over the same
          # source, which meant restating upstream's build: the seven git deps
          # hashed by hand in `cargoLock.outputHashes` and re-hashed whenever
          # its Cargo.lock moved, the linuxHeaders path v4l2r's bindgen wants,
          # and a postPatch dropping the .cargo/config.toml that pointed the
          # build at DotSlash. Upstream's flake says all of that itself now,
          # and says it once. It also builds cpal with the `pipewire` feature,
          # which the restatement did not — so device names in a call are
          # PipeWire's rather than raw ALSA PCMs.
          native = jolt-native.packages.${pkgs.stdenv.hostPlatform.system}.default;

          # libmoq_ffi — MoQ over QUIC behind UniFFI's C ABI, with the codecs
          # in it. This is the object `frq.moq.raw` is generated from.
          #
          # Default features, which is the entire reason this is a build and
          # not a fetchurl: `audio` and `video` are on by default upstream and
          # off in every Linux and Android artifact the release publishes, and
          # they are what carry Opus and H.264. 230 entry points here against
          # the release object's 206 — see the moq-src input.
          #
          # No cargoHash and no outputHashes: the workspace has no git
          # dependencies, so its own Cargo.lock is the whole of the pin.
          moqFfi = pkgs.rustPlatform.buildRustPackage {
            pname = "libmoq-ffi";
            version = "0.3.17";
            src = moq-src;
            cargoLock.lockFile = "${moq-src}/Cargo.lock";

            # One crate out of a workspace of thirty. Default features are
            # deliberate — see above — so there is no --no-default-features
            # here and there should not be.
            cargoBuildFlags = [ "-p" "moq-ffi" ];

            # The workspace's tests want a network and a relay.
            doCheck = false;

            # bindgenHook is not optional: moq-video reaches VAAPI through
            # libva-sys, whose build script runs bindgen, which needs
            # LIBCLANG_PATH set. Without it the build fails deep inside a
            # build script with "Unable to find libclang".
            nativeBuildInputs = with pkgs; [
              cmake nasm pkg-config perl rustPlatform.bindgenHook
            ];

            # libva and libdrm are here for their HEADERS. VAAPI itself is
            # dlopened at runtime, so the object carries no DT_NEEDED for it
            # and a machine with no VAAPI driver still loads this — openh264
            # is the fallback, and it is vendored and static.
            buildInputs = with pkgs; [ openssl libva libdrm ];

            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib
              find target -name 'libmoq_ffi.so' -print -exec cp {} $out/lib/ \;
              test -f $out/lib/libmoq_ffi.so
              runHook postInstall
            '';
          };

          # One directory for the loader to look in. jolt resolves every
          # :jolt/native name against JOLT_NATIVE_LIB, and the objects now come
          # from two places — jolt-native's flake, and the moq-ffi release — so
          # they are joined rather than the path being made a list, which the
          # loader does not take.
          nativeAll = pkgs.symlinkJoin {
            name = "frq-native";
            paths = [ native moqFfi ];
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
          glimmerVidya = "${jolt-native}/glimmer-backends/glimmer-vidya";
          glimmerTui = "${jolt-native}/glimmer-backends/glimmer-tui";

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
            export LD_LIBRARY_PATH="${nativeAll}/lib:${lib.makeLibraryPath runtimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
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
            export LD_LIBRARY_PATH="${nativeAll}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
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
            inherit pkgs self chez-src jolt-native jolt-native-android glimmer joltAndroid;
            inherit (pkgs) lib;
            androidSdk = androidComposition.androidsdk;
            ndk = androidComposition.ndk-bundle;
          };
        in
        {
          inherit native moqFfi nativeAll frq;
          inherit tui;
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
      # `native` is jolt-native's own flake output. It was a buck2 graph when
      # this comment was first written and a cargo build restated here when it
      # was second: buck2 fetches its rustc, zig and every third-party crate as
      # it goes and writes buck-out into the tree it builds, so a sandbox with
      # no network and a read-only store was the one place it could not run.
      # Upstream builds with nix now, so the thing its CI runs and the thing
      # this shell hands a builder are the same derivation.
      #
      # Nothing here says "nixbuild", though: it is a plain derivation, and
      # where it gets built is the machine's business. The `run` recipe asks for
      # the shell with --max-jobs 0, which is what sends it to the `builders`
      # entry rather than compiling egui on a laptop.
      devShells = forEachSystem (pkgs:
        let
          inherit (pkgs) lib;
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) jolt native nativeAll;
        in
        {
          default = pkgs.mkShellNoCC {
            name = "frq";

            # jolt, because the runtime frq is run by should be the flake's
            # too. nixGL for the same reason the launcher reaches for it — see
            # frqScript. just so the recipe runner comes from here too rather
            # than the host — `nix develop` and then `just run` is the whole of
            # what a machine with nix needs.
            packages = [ jolt pkgs.just (nixGLFor pkgs) ];

            # Read by the recipes rather than baked into a wrapper: the frq
            # source `just run` runs is the working tree, so the launcher has
            # to live in that tree and the shell has to hand it its answers.
            # Naming these is also what makes the shell build them.
            JOLT_NATIVE_LIB = "${nativeAll}/lib";
            GLIMMER_SRC = glimmer;
            GLIMMER_VIDYA_SRC = "${jolt-native}/glimmer-backends/glimmer-vidya";
            GLIMMER_TUI_SRC = "${jolt-native}/glimmer-backends/glimmer-tui";
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
