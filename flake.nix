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
    # The fork rather than jolt-lang/jolt, and unpinned: the desktop follows
    # the fork's main. It used to be paired with a second, pinned input for
    # the APK's boot image; there is no jolt APK now, so there is one runtime
    # and one rev.
    jolt-src = {
      url = "git+https://gitlab.com/nandithebull/jolt?submodules=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The source half of jolt-native: the Jolt code under glimmer-backends/ that
    # binds the native objects, and the flake that builds them. This input is
    # what `just cosmic run` builds against.
    #
    # It carries both backends that are left — glimmer-cosmic over
    # libjoltcosmic for the window, glimmer-tui over libjolttui for the
    # terminal — and no longer jvui or vidya, which were experiments.
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
      url = "git+https://gitlab.com/nandithebull/jolt-native?rev=8e8cd5192dc161b423c0ee5dd41a7a058b24b409";
      inputs.nixpkgs.follows = "nixpkgs";
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

  outputs = { self, nixpkgs, jolt-src, jolt-native, glimmer, nixgl, nix-appimage }:
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

      # The Android SDK wants two things `nixpkgs.legacyPackages` cannot give:
      # `allowUnfree`, because the SDK's own licence is not free, and
      # `android_sdk.accept_license`, which is how you say so in a file rather
      # than at a prompt a build has no terminal for. Neither can be set on a
      # legacyPackages attribute after the fact, so this is a second import of
      # the same locked nixpkgs rather than a second nixpkgs.
      #
      # This used to live in `just apk` as a `nix build --impure --expr` with
      # `builtins.getFlake "github:NixOS/nixpkgs/nixos-unstable"` inside it —
      # which fetched whatever nixos-unstable was that morning, not what
      # flake.lock pins, so the SDK under the APK and the nixpkgs under
      # everything else were free to drift apart. Here they are the same rev.
      androidPkgsFor = system: import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };

      # Only the floor Gradle stands on. It installs build-tools and a platform
      # into ANDROID_HOME itself as it goes — see `just apk` for why that means
      # a writable copy — so composing more of them here buys nothing.
      #
      # includeNDK = false deliberately: the app is Dart and path_provider is
      # platform channels, so there is no native code to need one, and asking
      # for it is a few hundred megabytes and a Gradle fetch of that exact NDK.
      androidSdkFor = system:
        let android = androidPkgsFor system; in
        (android.androidenv.composeAndroidPackages {
          cmdLineToolsVersion = "13.0";
          buildToolsVersions = [ "34.0.0" ];
          platformVersions = [ "35" "34" ];
          includeNDK = false;
        }).androidsdk;

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
              # Both backends there are. libjoltcosmic is the window —
              # libcosmic behind the same retained-tree ABI — and libjolttui
              # is the terminal. Neither is libvidya and neither is jvui:
              # those were experiments and are gone from this tree entirely.
              paths = [ np.libjolttui np.libjoltcosmic ];
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
          # No SDL any more: it was jvui's, declared in jvui's own
          # :jolt/native and dlopened by soname. libcosmic paints through wgpu
          # and takes what it needs from `runtimeLibs` instead.
          codecs = [ pkgs.libopus pkgs.openh264 frqH264 pkgs.alsa-lib ];

          # ALSA's PipeWire plugin, which is how `default` resolves to
          # anything on a machine running PipeWire — and every machine frq
          # targets does. Without it alsa-lib fails to dlopen
          # libasound_module_pcm_pipewire.so and the only devices that open
          # are raw hardware ones, which PipeWire is already holding.
          #
          # An environment variable rather than a library in the join:
          # alsa-lib looks plugins up by directory, not by soname.
          alsaPluginDir = "${pkgs.pipewire}/lib/alsa-lib";

          nativeAll = pkgs.symlinkJoin {
            name = "frq-native";
            paths = [ native moqFfi ] ++ codecs;
          };

          # Jolt itself: Clojure on Chez, built the way its own flake builds it.
          #
          # Still a function taking its source, though there is only one of
          # them now: the second was the Bionic-addrinfo fork the APK's boot
          # image carried, and there is no jolt APK any more — the phone is
          # ClojureDart and Flutter, and jolt does not run there at all.
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

          # The backends' Clojure halves, which live inside the jolt-native
          # checkout beside the objects they bind. Their own deps.edn asks for
          # glimmer by git — the top-level override below answers for both.
          glimmerCosmic = "${jolt-native}/glimmer-backends/glimmer-cosmic";
          glimmerTui = "${jolt-native}/glimmer-backends/glimmer-tui";

          runtimeLibs = runtimeLibsFor pkgs;

          # The project as jolt sees it: source, deps.edn, nothing else.
          frqSource = pkgs.runCommand "frq-source" { } ''
            mkdir -p "$out"
            cp -r ${self}/common ${self}/src ${self}/deps.edn "$out/"
          '';

          # Jolt resolves deps.edn from the working directory, so the launcher
          # runs from the store copy. Its .jolt/cpcache write lands on a
          # read-only directory and jolt treats that as a quiet cache miss, so
          # the only cost is re-resolving the (already local) graph per start.
          frqScript = pkgs.writeShellScript "frq" ''
            export LD_LIBRARY_PATH="${nativeAll}/lib:${lib.makeLibraryPath runtimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            export ALSA_PLUGIN_DIR="${alsaPluginDir}"
            cd ${frqSource}

            # On NixOS the store's Mesa is the system's and the window opens.
            # Anywhere else the real driver is the host's, so defer to nixGL —
            # it prepends the host driver, which has to win over ours.
            runner=""
            [ -e /run/current-system ] || runner="${nixGL}/bin/nixGLIntel"

            exec ''${runner} ${joltRuntime}/bin/jolt \
              -Sdeps '{:deps {jolt-lang/glimmer {:local/root "${glimmer}"} nandi/glimmer-cosmic {:local/root "${glimmerCosmic}"}}}' \
              -m frq.cosmic "$@"
          '';

          # The same source, the other backend. No GL, no nixGL and no X11 —
          # a terminal is the one surface that needs nothing from the host but
          # a terminal, which is the reason this output exists.
          tuiScript = pkgs.writeShellScript "frq-tui" ''
            export LD_LIBRARY_PATH="${nativeAll}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            export ALSA_PLUGIN_DIR="${alsaPluginDir}"
            cd ${frqSource}

            exec ${joltRuntime}/bin/jolt \
              -Sdeps '{:deps {jolt-lang/glimmer {:local/root "${glimmer}"} nandi/glimmer-tui {:local/root "${glimmerTui}"}}}' \
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
        in
        {
          inherit native moqFfi frqH264 nativeAll frq;
          inherit (pkgs) pipewire;
          inherit tui;
          jolt = joltRuntime;
          default = frq;

          # The Android SDK `just apk` copies into flutter/.home. A package
          # rather than something the recipe evaluates inline, so that
          # `nix build .#android-sdk` is how you pre-warm it and `nix flake
          # show` admits it exists.
          android-sdk = androidSdkFor pkgs.stdenv.hostPlatform.system;

          # frq and everything it loads, squashed into one runnable file for
          # hosts without Nix. The whole closure rides along — Mesa included,
          # which is not waste: off NixOS the launcher goes through nixGL, and
          # nixGL needs a store Mesa to put the host's driver in front of.
          appimage =
            nix-appimage.bundlers.${pkgs.stdenv.hostPlatform.system}.default frq;

          # Everything `clojure -M:cljd compile` would otherwise reach the
          # network for, fetched once and hashed.
          #
          # The compile needs three caches, and the reason this is one
          # derivation rather than three is that only one of them is obvious.
          # Maven and gitlibs are the ordinary tools.deps pair. The third is
          # ClojureDart's own: `ensure-cljd-analyzer!` writes a *second*, whole
          # pub project to `.clojuredart/cache/<cljd sha>/cljd_helper`, runs
          # `pub add analyzer` in it, and then runs `bin/analyzer.dart` out of
          # it for the duration of the compile — so a sandbox needs that
          # project already resolved, not just the app's dependencies.
          #
          # Fixed-output, so it is allowed the network the rest of the build is
          # not. What that costs is a hash to maintain, and the thing worth
          # being exact about is *when*: this derivation never sees frq's
          # source. It compiles a three-line throwaway project against the same
          # `flutter/deps.edn` and the same `flutter/pubspec.yaml`, so the hash
          # moves when a dependency moves and not when a screen changes. A
          # stub, rather than `-P` and a hand-built analyzer dir, because
          # running the real compiler once is the only way to be sure the
          # caches are the ones it actually wants.
          #
          # PUB_CACHE lands in $out on purpose. The package_config.json inside
          # cljd_helper carries absolute paths to whatever resolved it, so
          # resolving into a build directory would bake in paths that stop
          # existing the moment this derivation finishes. Pointed at $out they
          # are store paths, and still true.
          cljd-deps =
            let
              flutterPkg = pkgs.flutter;
            in
            pkgs.stdenvNoCC.mkDerivation {
              name = "frq-cljd-deps";
              dontUnpack = true;

              nativeBuildInputs = [
                pkgs.clojure
                pkgs.jdk17
                flutterPkg
                pkgs.git
                pkgs.cacert
              ];

              buildCommand = ''
                export HOME="$NIX_BUILD_TOP/home"
                # Resolved in the build directory and copied to $out at the
                # end, never written there directly. A fixed-output derivation
                # may not reference a store path and its own output is a store
                # path, so pub writing its cache's absolute location into its
                # own metadata is enough to fail the check.
                cache="$NIX_BUILD_TOP/cache"
                export PUB_CACHE="$cache/pub-cache"
                export GITLIBS="$cache/gitlibs"
                export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                mkdir -p "$HOME" "$PUB_CACHE" "$GITLIBS" "$cache/m2"

                # The stub: our dependency files, nothing of our source.
                # ../common is a :local/root dependency now, so it has to exist
                # *and* carry a deps.edn for tools.deps to resolve — an empty
                # directory with that one file in it is enough.
                proj="$NIX_BUILD_TOP/stub"
                mkdir -p "$proj/src/stub" "$NIX_BUILD_TOP/common"
                cp ${./common/deps.edn} "$NIX_BUILD_TOP/common/deps.edn"
                cp ${./flutter/deps.edn} "$proj/deps.edn"
                cp ${./flutter/pubspec.yaml} "$proj/pubspec.yaml"
                chmod u+w "$proj/deps.edn" "$proj/pubspec.yaml"
                cat > "$proj/src/stub/main.cljd" <<'EOF'
                (ns stub.main)
                (defn main [] nil)
                EOF

                cd "$proj"
                # `:main` has to name the stub, or the compiler goes looking for
                # frq.main in a tree that is not here.
                sed -i 's/:main frq\.main/:main stub.main/' deps.edn

                flutter config --no-analytics &>/dev/null || true
                flutter config --enable-linux-desktop >/dev/null || true

                clojure -Sdeps '{:mvn/local-repo "'"$cache"'/m2"}' -M:cljd compile

                # What the compile left behind, and only that. The analyzer
                # project is keyed by the ClojureDart sha, so the directory
                # under cache/ is copied wholesale rather than named here.
                mkdir -p "$out/clojuredart"
                cp -r .clojuredart/cache "$out/clojuredart/cache"
                cp -r "$cache/m2" "$out/m2"
                cp -r "$cache/gitlibs" "$out/gitlibs"
                cp -r "$PUB_CACHE" "$out/pub-cache"

                # A fixed-output derivation may not reference a store path, and
                # a resolved pub project is nothing but store paths:
                # package_config.json names the Flutter SDK and every package
                # in the cache by absolute path. So the analyzer project ships
                # *unresolved* — its pubspec and its analyzer.dart and nothing
                # else — and `flutter pub get --offline` re-resolves it against
                # this cache at build time, where naming the store is allowed.
                find "$out" \( -name '.dart_tool' -o -name '.flutter-plugins' \
                    -o -name '.flutter-plugins-dependencies' \) -prune -exec rm -rf {} +
                find "$out" -name '.packages' -delete


                # A fixed-output hash is a promise that two runs agree, so
                # everything a tool writes *about* a run rather than about a
                # dependency has to go: pub's log carries timestamps, Maven
                # rewrites its resolution metadata on every resolve, and
                # tools.gitlibs keeps bare clones it only needs in order to
                # make a checkout. None of it is read offline.
                rm -rf "$out/pub-cache/log" "$out/pub-cache/_temp" \
                       "$out/pub-cache/git" "$out/pub-cache/global_packages" \
                       "$out/pub-cache/bin"

                # tools.gitlibs keeps a bare clone per URL under _repos/, and a
                # bare clone is packfiles — which two runs of the same fetch do
                # not have to produce byte for byte. It cannot simply be
                # deleted, because `procure` calls `ensure-git-dir` before it
                # looks at anything else and would clone it again, over a
                # network this has and the build that uses it does not.
                #
                # It does not need the objects, though. `procure` finds the sha
                # with `match-exact` against the checkout already in libs/, so
                # the bare repo only has to exist. Emptied and re-initialised,
                # it is a fixed handful of files from the pinned git and the
                # same on every run.
                find "$out/gitlibs/_repos" -name HEAD | while read -r head; do
                  repo="$(dirname "$head")"
                  rm -rf "$repo"
                  git init --bare -q "$repo"
                  # The sample hooks are shell scripts, so they carry a
                  # `#!/nix/store/.../bash` line — which is exactly the kind of
                  # store reference a fixed-output derivation may not hold. An
                  # empty bare repo nothing ever runs has no use for them.
                  rm -rf "$repo/hooks"
                done
                # pub's version listings, which record when they were fetched.
                # This is the one that actually moved between two runs of this
                # derivation: the package sources under hosted/ were identical
                # and the listings beside them were not. Nothing offline reads
                # them — a resolution that already has every package on disk
                # never asks pub.dev what versions exist.
                find "$out/pub-cache" -name '.cache' -type d -prune -exec rm -rf {} +
                find "$out/m2" \( -name '*.lastUpdated' -o -name '_remote.repositories' \
                    -o -name 'resolver-status.properties' -o -name '*.part' \
                    -o -name 'maven-metadata-*.xml*' \) -delete
                find "$out" \( -name '.DS_Store' -o -name '*.log' -o -name '.git' \) \
                    -prune -exec rm -rf {} +
                find "$out" -type d -empty -delete
                chmod -R u+w "$out"

                # Last, after every cleanup above: anything still naming the
                # store fails the fixed-output check, and the error names one
                # path out of thousands of files. This names the files.
                if refs="$(grep -rlI /nix/store "$out" 2>/dev/null)" && [ -n "$refs" ]; then
                  echo "cljd-deps: these still reference the store:" >&2
                  echo "$refs" | head -20 >&2
                fi

                # If two runs disagree, this says which half to look in. Cheap,
                # and the alternative is a hash mismatch with nothing attached.
                for d in "$out"/*; do
                  echo "cljd-deps subtree $(basename "$d") $( (cd "$d" && find . -type f \
                      -exec sha256sum {} + | sort -k2 | sha256sum) )" >&2
                done
                for d in "$out"/pub-cache/*/*; do
                  [ -d "$d" ] || continue
                  echo "cljd-deps pub $(basename "$d") $( (cd "$d" && find . -type f \
                      -exec sha256sum {} + | sort -k2 | sha256sum) )" >&2
                done
              '';

              outputHashMode = "recursive";
              outputHashAlgo = "sha256";
              # Moves when flutter/deps.edn or flutter/pubspec.yaml move, and
              # not when frq's own source does — see the stub above.
              outputHash = "sha256-gfJGlKCPaJsKcXfCWOJY1089XEfzTndEx0LVf3JOXfs=";
            };

          # The Flutter desktop GUI, built rather than run out of the tree.
          #
          # `just flutter-desktop` is the working-tree loop and this is its
          # opposite number, the same way `nix build .#frq` is `just cosmic
          # run`'s: the source is the flake's, the output is a store path, and the build is
          # a sandbox with no network. It is the first thing here that builds
          # purely — the APK cannot, because Gradle fetches as it goes.
          #
          # Two stages, because the Dart does not exist until ClojureDart writes
          # it. `preBuild` runs the compiler over `flutter/src` and `common/`
          # with `--offline`, out of the caches `cljd-deps` fetched; everything
          # after that is an ordinary Flutter application as far as nixpkgs is
          # concerned.
          #
          # The caches are copied in rather than used where they lie. Maven,
          # tools.gitlibs and pub all expect to be able to write to their own
          # cache — a lock file, a resolved marker — and the store is read-only,
          # so pointing them at $out of a fixed-output derivation fails in three
          # different ways at three different depths.
          #
          # `src` is the whole tree and not `flutter/`: `flutter/deps.edn` puts
          # `../common` on the classpath, which is the entire point of that
          # directory, and a source root of `flutter/` would leave the screens
          # outside it.
          flutter-desktop-unwrapped = pkgs.flutter.buildFlutterApplication rec {
            pname = "frq-flutter";
            version = "0.1.0";

            src = lib.cleanSourceWith {
              src = ./.;
              # Build trees and caches, which are large, machine-specific and
              # would make every one of them a new store path.
              filter = path: type:
                let base = baseNameOf path; in
                !(builtins.elem base [
                  "build" ".home" ".clojuredart" ".cpcache" "cljd-out"
                  ".dart_tool" "result" ".git" ".jolt" "buck-out"
                ]);
            };
            sourceRoot = "source/flutter";

            # Read at eval time, so the lock in git is the lock that is built.
            autoPubspecLock = ./flutter/pubspec.lock;

            # git, because tools.deps resolves the ClojureDart dependency through
            # tools.gitlibs even when every byte of it is already on disk — see
            # the _repos note in cljd-deps.
            nativeBuildInputs = [ pkgs.clojure pkgs.jdk17 pkgs.git ];

            preBuild = ''
              export PUB_CACHE="$NIX_BUILD_TOP/pub-cache"
              export GITLIBS="$NIX_BUILD_TOP/gitlibs"
              cp -r ${self.packages.${pkgs.stdenv.hostPlatform.system}.cljd-deps}/pub-cache "$PUB_CACHE"
              cp -r ${self.packages.${pkgs.stdenv.hostPlatform.system}.cljd-deps}/gitlibs "$GITLIBS"
              cp -r ${self.packages.${pkgs.stdenv.hostPlatform.system}.cljd-deps}/m2 "$NIX_BUILD_TOP/m2"
              mkdir -p .clojuredart
              cp -r ${self.packages.${pkgs.stdenv.hostPlatform.system}.cljd-deps}/clojuredart/cache .clojuredart/cache
              chmod -R u+w "$PUB_CACHE" "$GITLIBS" "$NIX_BUILD_TOP/m2" .clojuredart

              # Resolve the analyzer project here rather than in cljd-deps,
              # which was not allowed to name the store. Offline, out of the
              # cache that derivation did fetch. ClojureDart only reaches for
              # the network when `bin/analyzer.dart` is missing, and it is not.
              for helper in .clojuredart/cache/*/cljd_helper; do
                ( cd "$helper" && flutter pub get --offline )
              done

              # --offline is what keeps `pub get` out of a sandbox that has no
              # network; the analyzer project it would otherwise resolve is
              # already in .clojuredart, put there by cljd-deps.
              clojure -Sdeps "{:mvn/local-repo \"$NIX_BUILD_TOP/m2\"}" \
                  -M:cljd compile --offline
            '';

            meta = {
              description = "frq's screens on Flutter's Linux target (no GL launcher)";
              mainProgram = "frq";
              platforms = systems;
            };
          };

          # The same shape as `frq` above: a launcher, and a package that is a
          # symlink to it. The reason is the same one `frqScript` gives — on
          # NixOS the store's Mesa is the system's and the window opens, and
          # anywhere else the real driver is the host's, so the process is
          # handed to nixGL. Without it the store build dies on a distrobox
          # Arch with "No provider of eglGetPlatformDisplayEXT found", which is
          # that failure wearing an EGL hat.
          #
          # A wrapper *around* the built application rather than a `postFixup`
          # inside it, because buildFlutterApplication's own dartFixupHook runs
          # after postFixup and rewrites `bin/frq` — so anything done to that
          # path from inside is undone on the way out.
          flutter-desktop =
            let
              unwrapped =
                self.packages.${pkgs.stdenv.hostPlatform.system}.flutter-desktop-unwrapped;
              script = pkgs.writeShellScript "frq" ''
                runner=""
                [ -e /run/current-system ] || runner="${nixGLFor pkgs}/bin/nixGLIntel"
                exec ''${runner} ${unwrapped}/bin/frq "$@"
              '';
            in
            pkgs.runCommand "frq-flutter-0.1.0"
              {
                meta = {
                  description = "frq's screens on Flutter's Linux target";
                  mainProgram = "frq";
                  platforms = systems;
                };
              }
              ''
                mkdir -p "$out/bin"
                ln -s ${script} "$out/bin/frq"
              '';
        });

      # Where `just cosmic run` runs, and — because entering it realises what it
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
      # where it gets built is the machine's business. The `cosmic` recipe asks for
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
            # than the host — `nix develop` and then `just cosmic run` is the
            # whole of what a machine with nix needs.
            packages = [ jolt pkgs.just (nixGLFor pkgs) ];

            # Read by the recipes rather than baked into a wrapper: the frq
            # source `just cosmic run` runs is the working tree, so the
            # launcher has to live in that tree and the shell has to hand it its answers.
            # Naming these is also what makes the shell build them.
            JOLT_NATIVE_LIB = "${nativeAll}/lib";
            # Spelled out rather than shared with the packages block, which
            # is a different `let`. See `alsaPluginDir` there for why.
            ALSA_PLUGIN_DIR = "${pkgs.pipewire}/lib/alsa-lib";
            GLIMMER_SRC = glimmer;
            GLIMMER_COSMIC_SRC = "${jolt-native}/glimmer-backends/glimmer-cosmic";
            GLIMMER_TUI_SRC = "${jolt-native}/glimmer-backends/glimmer-tui";
            FRQ_LIB_PATH = lib.makeLibraryPath (runtimeLibsFor pkgs);
            NIXGL = "${nixGLFor pkgs}/bin/nixGLIntel";

            # A checkout of jolt-native in place of the pin, when one is NAMED.
            #
            # The pin is a rev on a server, so the loop for a change to a
            # backend would be commit, push, re-pin, re-lock — four steps and
            # an upload for a line of Rust. Pointing FRQ_JOLT_NATIVE at a
            # working copy makes the loop `cargo build` and `just tui`.
            #
            # This used to find that copy by itself — ../jolt-native beside the
            # checkout — and that is gone, because a found tree is the wrong
            # default twice over. It fired on a sibling nobody had asked about,
            # so a shell could be running something other than the pin on the
            # strength of a directory existing. And what it prepended was a raw
            # `cargo build` artifact: no store RUNPATH, so its libc.so.6
            # resolves to the host's, and the Nix-glibc jolt that dlopens it
            # gets a second libc and fails. jolt reports that as "required
            # native library ... not found", which names neither libc nor the
            # tree the object came from. An override worth having is one you
            # can see in the command you typed.
            #
            # So: named or nothing. A named tree is taken even unbuilt (with a
            # word about what to run) — naming it is asking for it — and it has
            # to carry the RUNPATH the store copy does, which in practice means
            # building it under Nix.
            #
            # Only the sources and the objects a checkout actually builds move.
            # Everything else on the library path — libopus, libmoq_ffi, the
            # ALSA plugins — stays the pin's, since a checkout has no build of
            # those to offer.
            shellHook = ''
              if [ -n "''${FRQ_JOLT_NATIVE:-}" ]; then
                if [ -d "$FRQ_JOLT_NATIVE/crates/jolt-tui" ]; then
                  FRQ_JOLT_NATIVE="$(cd "$FRQ_JOLT_NATIVE" && pwd)"
                  export FRQ_JOLT_NATIVE
                  export GLIMMER_TUI_SRC="$FRQ_JOLT_NATIVE/glimmer-backends/glimmer-tui"
                  export GLIMMER_COSMIC_SRC="$FRQ_JOLT_NATIVE/glimmer-backends/glimmer-cosmic"
                  # First, so a cargo build wins over the pin's copy of the
                  # same object. The rest of the pin's lib directory is still
                  # behind it.
                  export JOLT_NATIVE_LIB="$FRQ_JOLT_NATIVE/target/release:$JOLT_NATIVE_LIB"
                  echo "frq: jolt-native from $FRQ_JOLT_NATIVE, not the pin (unset FRQ_JOLT_NATIVE for the pin)" >&2
                  if [ ! -e "$FRQ_JOLT_NATIVE/target/release/libjolttui.so" ]; then
                    echo "frq: no libjolttui.so there yet — cargo build --release --features terminal -p jolt-tui" >&2
                  fi
                else
                  echo "frq: FRQ_JOLT_NATIVE=$FRQ_JOLT_NATIVE is not a jolt-native checkout; using the pin" >&2
                fi
              fi
            '';
          };

          # The APK toolchain, which the default shell deliberately does not
          # carry: Flutter brings its own Dart, Gradle and a JDK's worth of
          # closure, and a desktop build has no use for any of it.
          #
          # `just apk` used to name these as `nix shell nixpkgs#clojure
          # nixpkgs#jdk17 nixpkgs#flutter`, which is the flake registry's
          # nixpkgs and not this flake's — so the Flutter under the APK
          # floated while everything else was locked. Same three packages,
          # from flake.lock now.
          #
          # JDK 17 and not newer on purpose: the Flutter template's Gradle
          # plugin pins a Gradle that rejects a JDK it was released before,
          # and the failure reads as an unsupported class file version rather
          # than as a version mismatch.
          flutter = pkgs.mkShellNoCC {
            name = "frq-flutter";

            # git, because tools.deps resolves the ClojureDart dependency
            # through tools.gitlibs even when every byte of it is already in
            # the seeded cache — the same reason flutter-desktop-unwrapped
            # names it. The host's git has always been there to answer; naming
            # it means the shell does not depend on that.
            packages = [ pkgs.clojure pkgs.jdk17 pkgs.flutter pkgs.just pkgs.git ];

            # Where the recipe copies from. Naming it here is also what makes
            # entering the shell build it, so the first `just apk` does not
            # stop for a few hundred megabytes of SDK with nothing said about
            # why.
            FRQ_ANDROID_SDK =
              "${androidSdkFor pkgs.stdenv.hostPlatform.system}/libexec/android-sdk";

            # The Maven, gitlibs and pub caches the ClojureDart compile would
            # otherwise fetch, plus the analyzer project it writes under
            # .clojuredart. Here for both of FRQ_ANDROID_SDK's reasons: it is
            # where the recipe copies from, and naming it is what makes
            # entering the shell build it.
            #
            # The compile still runs online. These are a warm start and not a
            # pin — `--offline` would be, and would turn adding a line to
            # flutter/deps.edn into a re-hash of cljd-deps before anything
            # compiled again. The sandbox build takes that trade because it
            # has no network; the loop someone edits in should not.
            FRQ_CLJD_DEPS = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cljd-deps}";
          };

          # The other desktop GUI. Same ClojureDart half as the APK — one
          # `clojure -M:cljd compile`, one flutter/src — over Flutter's Linux
          # target instead of its Android one, so `flutter/linux/` is the
          # runner and CMake and Ninja are the build rather than Gradle.
          #
          # A separate shell from `flutter` rather than one that carries both,
          # because the halves are disjoint: this wants GTK and a C++ toolchain
          # and no JDK, and the APK wants a JDK and an SDK and no GTK. Sharing
          # them would mean every desktop build paying for a few hundred
          # megabytes of Android SDK it never opens, which is the same argument
          # that keeps Flutter out of the default shell.
          #
          # mkShell and not mkShellNoCC, unlike every other shell here: this is
          # the one that actually compiles C++. stdenv brings the compiler, and
          # gtk3 in buildInputs is what puts its .pc file where the runner's
          # `pkg_check_modules(GTK gtk+-3.0)` can find it.
          flutter-desktop = pkgs.mkShell {
            name = "frq-flutter-desktop";

            # clojure and flutter are the APK shell's, and deliberately the
            # same two: the Dart that runs here is generated by the same
            # compiler from the same source, and a second Flutter version
            # under it would be a second set of engine artifacts and a second
            # answer to "does the phone build match the desktop one".
            nativeBuildInputs = [
              pkgs.clojure
              pkgs.flutter
              pkgs.just
              pkgs.cmake
              pkgs.ninja
              pkgs.pkg-config
            ];

            # gtk3 is the runner's own dependency; the rest are url_launcher's
            # Linux implementation, which is a GTK plugin compiled into the
            # bundle. path_provider needs nothing here — its Linux half is
            # pure Dart over the XDG directories.
            buildInputs = [ pkgs.gtk3 pkgs.glib ];

            # Same reason `just cosmic run` reaches for it: Flutter paints
            # through GL, and off NixOS the driver that can do that is the
            # host's, not the store's. The recipe reads this exactly as
            # `cosmic` does.
            NIXGL = "${nixGLFor pkgs}/bin/nixGLIntel";

            # The `flutter` shell's, deliberately the same one and for the
            # same reason clojure and flutter are: the ClojureDart half of
            # both builds is one compile over one deps.edn, so a second set of
            # caches would be a second answer to what it resolved against.
            # This recipe reads the variable directly — it is inside this
            # shell before it does any of the work — where `just apk` reaches
            # for the flake output itself.
            FRQ_CLJD_DEPS = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cljd-deps}";

            # The recipe's re-entry test, the way JOLT_NATIVE_LIB is the
            # default shell's. Nothing else sets it, so `just flutter-desktop`
            # outside the shell re-enters and lands back on the same recipe —
            # no flag to forget, and no second code path for someone who runs
            # `nix develop .#flutter-desktop --command just flutter-desktop`
            # by hand.
            FRQ_FLUTTER_DESKTOP = "1";
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
