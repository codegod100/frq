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
    # It carries jvui and glimmer-jvui — the toolkit the window is painted
    # with now — and, from no-moq-deps, the dependency split and the
    # JOLT_WITHOUT_MOQ guard on the Android glue. Both were on the
    # `jvui-for-frq` branch while they were being written and are merged into
    # main now, which is why this names a rev on main again.
    #
    # Pinned all the same, and pinned to a rev, because an
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
      url = "git+https://gitlab.com/nandithebull/jolt-native?rev=c7d6ea8b8cda7e4ab2805c20463e0d0f770580c6";
      inputs.nixpkgs.follows = "nixpkgs";
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

  outputs = { self, nixpkgs, jolt-src, jolt-native, jolt-native-android, glimmer, chez-src, jolt-android-src, nixgl, nix-appimage }:
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
          # libjolttui only. Not libjoltmoq, whose job `frq.av.plane` does
          # now, and no longer libvidya either: the window is jvui on SDL,
          # so the only object left out of that Cargo workspace is the
          # terminal backend, and only `just tui` loads it.
          #
          # This makes the closure smaller and the APK smaller. It does NOT
          # make the build shorter, and it is worth being exact about why:
          # jolt-native compiles its external crates ONCE, in a
          # `buildDepsOnly` derivation shared by all three objects, so
          # asking for two of them still builds every dependency the third
          # has — the 440 crates that are jolt-moq's alone. Getting those
          # out of the build is a change in jolt-native, not here: either
          # jolt-moq leaves that workspace, or its deps artifact stops
          # being workspace-wide.
          native =
            let np = jolt-native.packages.${pkgs.stdenv.hostPlatform.system};
            in pkgs.symlinkJoin {
              name = "jolt-native-ui";
              paths = [ np.libjolttui ];
            };

          # libmoq_ffi — MoQ over QUIC behind UniFFI's C ABI, FETCHED rather
          # than built. This is the object `frq.moq.raw` is generated from.
          #
          # Fetched because building it is the thing this whole exercise is
          # about: moq-ffi pulls moq-native, iroh, quinn, rustls and aws-lc-sys
          # behind it, which is 440 crates that nothing else in this tree
          # needs. Upstream already publishes the object for both Linux
          # architectures, so we take those bytes.
          #
          # Pinned to a release and to a hash, and the hashes below are
          # upstream's own published .sha256 files rather than ones observed
          # here — a `nix-prefetch` of whatever the URL serves today would
          # record that it downloaded something, not that it downloaded the
          # right thing.
          #
          # WHAT THIS BUILD IS NOT: moq-ffi's `audio` and `video` features are
          # on by default upstream and are OFF in these artifacts, so there is
          # no publish_audio/publish_video and no moqaudio*/moqvideo* here —
          # 206 functions where the Apple artifact has 230. That is why the
          # bindings are generated from the object (`just gen-moq`) and not
          # from the C header the release ships, which describes the Apple one.
          moqFfi =
            let
              version = "0.3.17";
              target = {
                "x86_64-linux" = "x86_64-unknown-linux-gnu";
                "aarch64-linux" = "aarch64-unknown-linux-gnu";
              }.${pkgs.stdenv.hostPlatform.system};
              hash = {
                "x86_64-linux" = "sha256-dzQXpV4JgdtD+g33WX51FFAQdfCUXkNsx1xPbobPfUI=";
                "aarch64-linux" = "sha256-PdzRwbJFqOZWRgI0HHX2XUH+Ljh4V3jvQ9asfvCuIPA=";
              }.${pkgs.stdenv.hostPlatform.system};
            in
            pkgs.stdenv.mkDerivation {
              pname = "libmoq-ffi";
              inherit version;
              src = pkgs.fetchurl {
                url = "https://github.com/kixelated/moq/releases/download/moq-ffi-v${version}/moq-ffi-${version}-${target}-libmoq_ffi.so";
                inherit hash;
              };
              dontUnpack = true;
              # It carries no RUNPATH and needs libgcc_s, libm and libc — the
              # host's on an ordinary distro, and nothing at all on NixOS
              # unless they are bound here.
              nativeBuildInputs = [ pkgs.autoPatchelfHook ];
              buildInputs = [ pkgs.stdenv.cc.cc.lib ];
              installPhase = ''
                mkdir -p $out/lib
                cp $src $out/lib/libmoq_ffi.so
                chmod +w $out/lib/libmoq_ffi.so
              '';
            };

          # One directory for the loader to look in. jolt resolves every
          # :jolt/native name against JOLT_NATIVE_LIB, and the objects now come
          # from two places — jolt-native's flake, and the moq-ffi release — so
          # they are joined rather than the path being made a list, which the
          # loader does not take.
          # The C codecs, from nixpkgs. libmoq_ffi carries the transport and
          # nothing else — moq-ffi's `audio` and `video` features would have
          # brought Opus and H.264 with them, at the price of compiling a
          # 1062-crate workspace — so the codecs are linked here instead,
          # where they have always lived.
          #
          # Named in :jolt/native, so the loader resolves them the same way it
          # resolves libvidya: by name, out of one directory.
          # A flat C face for openh264, because openh264 has none. Its
          # `ISVCEncoder` is `const ISVCEncoderVtbl*` — every method is a
          # function pointer in a vtable — and jolt.ffi cannot call one: Chez
          # fixes a foreign procedure's types when it compiles it, and the
          # target must be a literal C symbol name. So the vtable is walked in
          # c/frq_h264.c and jolt binds the five plain symbols it exports.
          #
          # One translation unit against a library nixpkgs already has. It is
          # a calling convention adapter, not a second media plane, and the
          # distinction from the moq-ffi build it replaces is the whole point:
          # this compiles one .c file, not a 1062-crate workspace.
          frqH264 = pkgs.stdenv.mkDerivation {
            pname = "frq-h264";
            version = "0.1";
            src = ./c;
            nativeBuildInputs = [ pkgs.pkg-config ];
            buildInputs = [ pkgs.openh264 ];
            buildPhase = ''
              $CC -O2 -fPIC -shared frq_h264.c -o libfrqh264.so \
                $(pkg-config --cflags --libs openh264)
            '';
            installPhase = ''
              mkdir -p $out/lib && cp libfrqh264.so $out/lib/
            '';
          };

          # openh264 is here for frqH264's DT_NEEDED; alsa-lib for capture
          # and playback. V4L2 needs nothing: it is ioctls against libc and
          # the kernel, so there is no library to name.
          # SDL is what the UI is now: jvui declares SDL3, SDL3_ttf and
          # SDL3_image in its own :jolt/native and dlopens them by soname,
          # so they have to be somewhere the loader looks. sdl3-image keeps
          # its library in a separate `lib` output — the default one holds
          # only share/, which is an afternoon nobody needs to repeat.
          sdl = [ pkgs.sdl3 pkgs.sdl3-ttf (pkgs.sdl3-image.lib or pkgs.sdl3-image) ];

          codecs = [ pkgs.libopus pkgs.openh264 frqH264 pkgs.alsa-lib ] ++ sdl;

          # ALSA's PipeWire plugin, which is how `default` resolves to
          # anything on a machine running PipeWire — and every machine frq
          # targets does. Without it alsa-lib fails to dlopen
          # libasound_module_pcm_pipewire.so and the only devices that open
          # are raw hardware ones, which PipeWire is already holding.
          #
          # An environment variable rather than a library in the join:
          # alsa-lib looks plugins up by directory, not by soname.
          alsaPluginDir = "${pkgs.pipewire}/lib/alsa-lib";

          # The faces jvui draws with, from here rather than from whatever
          # the host happens to have installed. jvui hunts a list of the
          # usual system paths and, failing that, draws the missing-glyph
          # box — which is what "the glyphs are broke" has been every time
          # it has come up. An Arch container has NotoColorEmoji and no
          # monochrome Noto Emoji, and NotoColorEmoji is a bitmap face with
          # one 128-pixel strike that jvui rejects on purpose, so the chips
          # in a message row had nothing left to be drawn from.
          #
          # NotoEmoji is the outline companion to NotoColorEmoji: scalable,
          # monochrome, and full coverage of the emoji the chrome uses.
          # Symbols2 behind it for the arrows and technical marks that are
          # not emoji at all.
          uiFont = "${pkgs.noto-fonts}/share/fonts/noto/NotoSans.ttf";
          fallbackFonts = lib.concatStringsSep ":" [
            "${pkgs.noto-fonts-monochrome-emoji}/share/fonts/noto/NotoEmoji.ttf"
            "${pkgs.noto-fonts}/share/fonts/noto/NotoSansSymbols2-Regular.otf"
            "${pkgs.noto-fonts}/share/fonts/noto/NotoSansSymbols.ttf"
          ];

          nativeAll = pkgs.symlinkJoin {
            name = "frq-native";
            paths = [ native moqFfi ] ++ codecs;
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
          # glimmer-jvui and the toolkit it is a backend for. TWO paths and
          # not one: glimmer-jvui's own deps.edn names jvui by :local/root,
          # a relative path that means nothing once nix has copied the
          # subtree, so the -Sdeps below has to name both.
          glimmerJvui = "${jolt-native}/glimmer-backends/glimmer-jvui";
          jvui = "${jolt-native}/jvui";
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
            export ALSA_PLUGIN_DIR="${alsaPluginDir}"
            export JVUI_FONT="${uiFont}"
            export JVUI_FALLBACK_FONTS="${fallbackFonts}"
            cd ${frqSource}

            # On NixOS the store's Mesa is the system's and the window opens.
            # Anywhere else the real driver is the host's, so defer to nixGL —
            # it prepends the host driver, which has to win over ours.
            runner=""
            [ -e /run/current-system ] || runner="${nixGL}/bin/nixGLIntel"

            exec ''${runner} ${joltRuntime}/bin/jolt \
              -Sdeps '{:deps {jolt-lang/glimmer {:local/root "${glimmer}"} nandi/glimmer-jvui {:local/root "${glimmerJvui}"} jvui/jvui {:local/root "${jvui}"}}}' \
              -M:frq "$@"
          '';

          # The same source, the other backend. No GL, no nixGL and no X11 —
          # a terminal is the one surface that needs nothing from the host but
          # a terminal, which is the reason this output exists.
          tuiScript = pkgs.writeShellScript "frq-tui" ''
            export LD_LIBRARY_PATH="${nativeAll}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            export ALSA_PLUGIN_DIR="${alsaPluginDir}"
            cd ${frqSource}

            exec ${joltRuntime}/bin/jolt \
              -Sdeps '{:deps {jolt-lang/glimmer {:local/root "${glimmer}"} nandi/glimmer-jvui {:local/root "${glimmerJvui}"} jvui/jvui {:local/root "${jvui}"} nandi/glimmer-tui {:local/root "${glimmerTui}"}}}' \
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
          inherit native moqFfi frqH264 nativeAll frq;
          inherit (pkgs) pipewire;
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
            # Spelled out rather than shared with the packages block, which
            # is a different `let`. See `alsaPluginDir` there for why.
            ALSA_PLUGIN_DIR = "${pkgs.pipewire}/lib/alsa-lib";
            GLIMMER_SRC = glimmer;
            GLIMMER_JVUI_SRC = "${jolt-native}/glimmer-backends/glimmer-jvui";
            JVUI_SRC = "${jolt-native}/jvui";
            GLIMMER_TUI_SRC = "${jolt-native}/glimmer-backends/glimmer-tui";
            # See `uiFont` in the packages block for why these are named
            # here rather than left to whatever the host has installed.
            # Spelled out again for the same reason ALSA_PLUGIN_DIR is: a
            # different `let`.
            JVUI_FONT = "${pkgs.noto-fonts}/share/fonts/noto/NotoSans.ttf";
            JVUI_FALLBACK_FONTS = lib.concatStringsSep ":" [
              "${pkgs.noto-fonts-monochrome-emoji}/share/fonts/noto/NotoEmoji.ttf"
              "${pkgs.noto-fonts}/share/fonts/noto/NotoSansSymbols2-Regular.otf"
              "${pkgs.noto-fonts}/share/fonts/noto/NotoSansSymbols.ttf"
            ];
            FRQ_LIB_PATH = lib.makeLibraryPath (runtimeLibsFor pkgs);
            NIXGL = "${nixGLFor pkgs}/bin/nixGLIntel";

            # A checkout of jolt-native beside this one, in place of the pin.
            #
            # The pin is a rev on a server, so the loop for a change to the
            # terminal backend was commit, push, re-pin, re-lock — four steps
            # and an upload for a line of Rust. With a working copy beside this
            # one the loop is `cargo build` and `just tui`, and the shell finds
            # that copy itself: ../jolt-native from the checkout this was run
            # in, which is where it is on the machines this is developed on.
            # A worktree under .claude/worktrees counts as the same checkout —
            # the sibling is the main one's, not the worktree's.
            #
            # Found rather than named, but not silently: it says which tree it
            # took on the way in, because `just tui` running something other
            # than the pin is the sort of thing you have to be able to see.
            #
            # It has to be a built one. A checkout with no target/release/
            # libjolttui.so in it would mean the Jolt half of the backend from
            # the working copy and the shared object from the pin — two halves
            # of two different libraries, which fail in ways that look like
            # neither. So an unbuilt sibling is left alone and the pin stands.
            #
            # FRQ_JOLT_NATIVE overrides the search, and is taken even unbuilt
            # (with a word about what to run): naming a tree is asking for it.
            # Empty is how you say the pin, on a machine that has a sibling and
            # wants what everyone else is running.
            #
            # Only the sources and libjolttui move either way. Everything else
            # on the library path — libopus, libmoq_ffi, the ALSA plugins —
            # stays the pin's, since a checkout has no build of those to offer.
            shellHook = ''
              frq_named=1
              if [ -z "''${FRQ_JOLT_NATIVE+named}" ]; then
                frq_named=
                frq_git="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
                frq_near="''${frq_git:+$(dirname "$(dirname "$frq_git")")/jolt-native}"
                if [ -n "$frq_near" ] && [ -e "$frq_near/target/release/libjolttui.so" ]; then
                  FRQ_JOLT_NATIVE="$frq_near"
                else
                  FRQ_JOLT_NATIVE=""
                fi
              fi
              if [ -n "$FRQ_JOLT_NATIVE" ]; then
                if [ -d "$FRQ_JOLT_NATIVE/crates/jolt-tui" ]; then
                  FRQ_JOLT_NATIVE="$(cd "$FRQ_JOLT_NATIVE" && pwd)"
                  export FRQ_JOLT_NATIVE
                  export GLIMMER_TUI_SRC="$FRQ_JOLT_NATIVE/glimmer-backends/glimmer-tui"
                  export GLIMMER_JVUI_SRC="$FRQ_JOLT_NATIVE/glimmer-backends/glimmer-jvui"
                  export JVUI_SRC="$FRQ_JOLT_NATIVE/jvui"
                  # First, so a cargo build wins over the pin's copy of the
                  # same object. The rest of the pin's lib directory is still
                  # behind it.
                  export JOLT_NATIVE_LIB="$FRQ_JOLT_NATIVE/target/release:$JOLT_NATIVE_LIB"
                  echo "frq: jolt-native from $FRQ_JOLT_NATIVE, not the pin (FRQ_JOLT_NATIVE= for the pin)" >&2
                  if [ ! -e "$FRQ_JOLT_NATIVE/target/release/libjolttui.so" ]; then
                    echo "frq: no libjolttui.so there yet — cargo build --release --features terminal -p jolt-tui" >&2
                  fi
                elif [ -n "$frq_named" ]; then
                  echo "frq: FRQ_JOLT_NATIVE=$FRQ_JOLT_NATIVE is not a jolt-native checkout; using the pin" >&2
                fi
              fi
              unset frq_named frq_git frq_near
            '';
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
