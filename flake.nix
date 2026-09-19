{
  # frq is a Flutter app whose source is ClojureDart, so what this flake
  # provides is toolchains rather than a built program: the `flutter` shell
  # that `just apk` compiles in, the `flutter-desktop` shell for the Linux
  # target, and the Android SDK the first of those copies somewhere writable.
  #
  #   nix develop .#flutter-desktop --command just flutter-desktop run
  #
  # On a machine that is not NixOS the GL driver is the host's and the loader
  # will not find it, so the window never opens ("GL display: argument does not
  # name a valid config"). The recipes handle that themselves: off NixOS they
  # hand the process to nixGL, which puts the host's driver ahead of the
  # store's. A distrobox/container Arch is the same case as a bare one.
  description = "frq — a freeq client in Flutter";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Only ever used off NixOS, to put the host GL driver on the loader path.
    nixgl = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixgl }:
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

    in
    {
      packages = forEachSystem (pkgs:
        let
          inherit (pkgs) lib;
        in
        {
          # The Android SDK `just apk` copies into flutter/.home. A package
          # rather than something the recipe evaluates inline, so that
          # `nix build .#android-sdk` is how you pre-warm it and `nix flake
          # show` admits it exists.
          android-sdk = androidSdkFor pkgs.stdenv.hostPlatform.system;

          # There were `appimage` outputs here, and what they were for was a
          # host without Nix: they squashed the whole closure into one
          # runnable file, Mesa included, and the Mesa was not waste — off
          # NixOS the launcher goes through nixGL, which needs a store Mesa to
          # put the host's driver in front of. Nothing asks for that shape any
          # more, and they were the last thing evaluating nix-appimage, which
          # is why that input is gone too.

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
                # The lock, or `pub get` resolves against pub.dev and takes
                # whatever satisfies the ranges today. Every build then fetches
                # a slightly different set and the fixed-output hash is a
                # promise nothing can keep.
                cp ${./flutter/pubspec.lock} "$proj/pubspec.lock"
                chmod u+w "$proj/deps.edn" "$proj/pubspec.yaml" "$proj/pubspec.lock"
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
                #
                # active_roots is the one that was actually breaking this. Pub
                # records the project directories using the cache, sharded by
                # a hash of the path, and $NIX_BUILD_TOP is different on every
                # run -- so two builds whose hosted/ trees were byte-identical
                # still disagreed, purely over which directory had asked. Four
                # builds gave four hashes until this went.
                rm -rf "$out/pub-cache/log" "$out/pub-cache/_temp" \
                       "$out/pub-cache/git" "$out/pub-cache/global_packages" \
                       "$out/pub-cache/bin" "$out/pub-cache/active_roots"

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
                  # The path relative to $out, not the basename: two runs that
                  # disagree here disagree about *which* directory exists, and
                  # a bare `09` names nothing you can go and look at.
                  echo "cljd-deps pub ''${d#$out/} $( (cd "$d" && find . -type f \
                      -exec sha256sum {} + | sort -k2 | sha256sum) )" >&2
                done
              '';

              outputHashMode = "recursive";
              outputHashAlgo = "sha256";
              # Moves when flutter/deps.edn or flutter/pubspec.yaml move, and
              # not when frq's own source does — see the stub above.
              outputHash = "sha256-qSGx7WFdVyV7yu4R+EjiQHZcLqwDjYSlohiZcXB43DY=";
            };

          # The Flutter desktop GUI, built rather than run out of the tree.
          #
          # `just flutter-desktop` is the working-tree loop and this is its
          # opposite number: the source is the flake's, the output is a store
          # path, and the build is a sandbox with no network. It is the first thing here that builds
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
              # Two trees, and only two: `flutter/` is the app and `common/`
              # is the screens its deps.edn puts on the classpath. The root is
              # still the source root because of that `../common`, but letting
              # the *whole* root in means every file in the repo is an input —
              # so editing flake.nix or CLAUDE.md
              # invalidated the entire Dart compile and paid ten minutes for a
              # change the Flutter build cannot even see.
              #
              # Matched on the path relative to the root rather than on
              # basename: `src` as a basename would also exclude `flutter/src`
              # and `common/src`, which is everything that matters.
              filter =
                let root = toString ./.; in
                path: type:
                  let
                    rel = lib.removePrefix (root + "/") (toString path);
                    inTree = d: rel == d || lib.hasPrefix (d + "/") rel;
                  in
                  (inTree "flutter" || inTree "common")
                  # Build trees and caches, which are large, machine-specific
                  # and would make every one of them a new store path.
                  && !(builtins.elem (baseNameOf path) [
                    "build" ".home" ".clojuredart" ".cpcache" "cljd-out"
                    ".dart_tool" "result" ".git" "buck-out"
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

              # buildFlutterApplication's own wrapper appends a bare `/lib` to
              # LD_LIBRARY_PATH — the host's, not the bundle's. Off NixOS that
              # is a foreign library directory in front of nothing, and the app
              # dies in the loader before main: first
              #
              #   /lib/libc.so.6: undefined symbol: __pointer_chk_guard
              #
              # and, once the store's glibc is put ahead of it,
              #
              #   libc.so.6: version `GLIBC_2.43' not found
              #       (required by /lib/libglib-2.0.so.0)
              #
              # which is the same bug wearing the other hat: the host's glib
              # against the store's glibc. Ordering cannot fix a mixture, so
              # the entry goes rather than moves. The wrapper is generated, so
              # this edits a copy and asserts the edit landed — a silent miss
              # here is a runtime failure on someone else's machine.
              fixed = pkgs.runCommand "frq-flutter-wrapper" { } ''
                mkdir -p "$out/bin"
                sed "s|'/lib'||g" ${unwrapped}/bin/frq > "$out/bin/frq"
                chmod +x "$out/bin/frq"
                if grep -q "'/lib'" "$out/bin/frq"; then
                  echo "the /lib entry outlived the edit; look at the wrapper" >&2
                  exit 1
                fi
              '';

              script = pkgs.writeShellScript "frq" ''
                runner=""
                [ -e /run/current-system ] || runner="${nixGLFor pkgs}/bin/nixGLIntel"
                exec ''${runner} ${fixed}/bin/frq "$@"
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

      devShells = forEachSystem (pkgs:
        let
          inherit (pkgs) lib;
        in
        {
          # Dart on its own, for the tests that need no Flutter: the FFI
          # binding to the Nim core runs on the plain VM, and making it wait
          # for a Flutter toolchain would throw away the reason it is fast.
          #
          # Flutter bundles a Dart, so this is a duplicate in one sense. It is
          # also thirty times smaller, and the point of the boundary is that
          # you can check it without the thing on the other side of it.
          dart = pkgs.mkShellNoCC {
            name = "frq-dart";
            packages = [ pkgs.dart pkgs.just ];
            FRQ_DART = "1";
          };

          # Nim, for `nim/` — the portable core as a native library. Just the
          # compiler: the core has no dependencies outside Nim's own standard
          # library, deliberately, because a dependency here is one that has
          # to cross-compile to every target the Dart side runs on.
          #
          # `nim c` shells out to a C compiler, so this is mkShell and not
          # mkShellNoCC: stdenv brings the one Nim will find.
          nim = pkgs.mkShell {
            name = "frq-nim";
            packages = [ pkgs.nim pkgs.just ];

            # The recipe's re-entry test, the way FRQ_FLUTTER_DESKTOP is the
            # desktop one's.
            FRQ_NIM = "1";
          };

          # The APK toolchain. It is not in a default shell any more because
          # there is no default shell: what used to be one belonged to the
          # libcosmic frontend, and a Flutter build asks for a toolchain by
          # name.
          #
          # Flutter brings its own Dart, Gradle and a JDK's worth of
          # closure: Flutter brings its own Dart, Gradle and a JDK's worth of
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

            # Flutter paints through GL, and off NixOS the driver that can do
            # that is the host's, not the store's.
            NIXGL = "${nixGLFor pkgs}/bin/nixGLIntel";

            # The `flutter` shell's, deliberately the same one and for the
            # same reason clojure and flutter are: the ClojureDart half of
            # both builds is one compile over one deps.edn, so a second set of
            # caches would be a second answer to what it resolved against.
            # This recipe reads the variable directly — it is inside this
            # shell before it does any of the work — where `just apk` reaches
            # for the flake output itself.
            FRQ_CLJD_DEPS = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cljd-deps}";

            # The recipe's re-entry test. Nothing else sets it, so `just flutter-desktop`
            # outside the shell re-enters and lands back on the same recipe —
            # no flag to forget, and no second code path for someone who runs
            # `nix develop .#flutter-desktop --command just flutter-desktop`
            # by hand.
            FRQ_FLUTTER_DESKTOP = "1";
          };

          # No `flutter-web` shell here any more. The web target was the one
          # that needed nothing of the host -- no JDK and no Android SDK as
          # the APK wants, no GTK and no C++ and no nixGL as the desktop one
          # does -- and a devShell whose only job is to hand over a Dart and
          # a JVM is a devShell that a pinned tarball can replace. It did:
          # `tools/toolchain.sh` fetches Flutter, a JDK and the Clojure CLI by
          # sha256, `tools/build-web.sh` builds out of them, and
          # `.modal/flutter-web/` runs that same script on a plain Debian
          # image with no store to populate.
          #
          # The two shells above stay. What they supply is a host toolchain,
          # which is exactly what nix is better at than a tarball.
        });

    };
}
