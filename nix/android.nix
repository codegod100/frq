# The APK, as derivations.
#
# The only APK build there is: this replaced a buck2 graph and the script
# before it, both of which named an Android SDK, an NDK, a hand-built Chez
# cross target and an OpenSSL by absolute path and stopped when one was
# missing. Every one of those is built or fetched here instead, so this works
# from nothing on a machine with none of them and no ~/.cache at all:
#
#   nix build .#apk
#
# `just apk` is the same build with the store path handed to adb afterwards;
# see the `apk` recipe in the justfile.
#
# On a machine with a remote builder configured, prefer
#
#   nix build .#apk --store ssh-ng://eu.nixbuild.net --eval-store auto
#
# rather than letting `builders` do it. With `builders`, nix copies the output
# of every remotely-built derivation back, and androidenv's NDK is both
# `preferLocalBuild` and absent from cache.nixos.org — so the 3.1 GB unpacked
# toolchain is built here and uploaded. With the remote as the *store* the
# whole graph stays there, only .drv files go up, and the builder fetches
# Google's zip over its own link.
#
# The steps are the ones the graph before it ran, in the same order; where a
# genrule read a path out of `read_root_config`, a derivation takes an
# argument.
{ pkgs, lib, self, chez-src, jolt-native, jolt-native-android, glimmer, joltAndroid, androidSdk, ndk }:

let
  # What the APK targets, in the three spellings the tools want it in.
  apiLevel = "28";
  targetSdk = "36";
  abi = "arm64-v8a";
  package = "uk.nandi.frq";
  version = "0.1.0";

  sdk = "${androidSdk}/libexec/android-sdk";
  buildTools = "${sdk}/build-tools/36.0.0";
  androidJar = "${sdk}/platforms/android-${targetSdk}/android.jar";

  # The NDK's clang finds its sysroot, resource directory and the rest of LLVM
  # relative to itself, so it is named by path rather than copied anywhere.
  # androidenv installs the tree under libexec/android-sdk and leaves
  # `ndk-bundle` pointing at the versioned directory beside it.
  ndkRoot = "${ndk}/libexec/android-sdk/ndk-bundle";
  ndkBin = "${ndkRoot}/toolchains/llvm/prebuilt/linux-x86_64/bin";
  cc = "${ndkBin}/aarch64-linux-android${apiLevel}-clang";

  # What comes out of jolt-native's CI, as a flake input rather than a fetchurl:
  # nix unpacks a tarball input itself, and flake.lock holds the digest that
  # used to be written here by hand. `just bump` moves it with
  # `nix flake update jolt-native-android` and nothing in this file changes.
  #
  # One archive, two libraries: libvidya (the retained-tree UI) and libjoltmoq
  # (the AV media plane). They are built together and only make sense together
  # — libjoltapp links both — so there is one pin for the pair rather than two
  # that could drift apart. It carries include/ and libc++_shared.so besides,
  # which is why the glue's headers and the C++ runtime come from here too.
  nativeLibs = jolt-native-android;

  # The C++ runtime, out of the archive rather than the NDK composed here.
  #
  # openh264 is C++, and its build script asks to be linked against
  # `libc++_shared.so` by name — so libjoltmoq carries that as a DT_NEEDED. An
  # app's linker namespace will not hand out the platform's own copy (there is
  # no stable one to hand out), so the APK carries it, exactly as it carries
  # OpenSSL below and for the same reason.
  #
  # jolt-native ships it beside the libraries that need it, so this is the copy
  # they were actually linked against — where the NDK path was whichever
  # revision `composeAndroidPackages` happened to resolve here.
  libcxx = "${nativeLibs}/lib/${abi}/libc++_shared.so";

  # --- Chez's arm64 cross target ------------------------------------------
  # The one piece with no nixpkgs equivalent: `pkgs.chez` builds a Scheme for
  # this machine, and what the boot image needs is Chez's `tarm64le` workarea —
  # the target boot files, the cross compiler's xpatch, and the arm64
  # libkernel.a that libjoltapp links.
  #
  # Three builds in one derivation, because each needs the one before it:
  #
  #   ta6le          a host Scheme, which is what cross-compiles anything
  #   boot XM=...    the target's boot files and xpatch, made by that host
  #   tarm64le       the target kernel, compiled by the NDK
  #
  # The flags are the ones the hand-built tree under ~/.cache/vidya-chez-android
  # was configured with, read back out of its Mf-config. zlib is Android's own
  # (`-lz`, which Bionic has); lz4 is the in-tree submodule, built for arm64
  # here because a cross configure links it rather than building it.
  chezAndroid = pkgs.stdenv.mkDerivation {
    pname = "chez-scheme-android";
    version = "10.4.1";
    src = chez-src;

    strictDeps = true;
    nativeBuildInputs = with pkgs; [ gnumake which ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      # Both workareas turn off the expression editor's two dependencies, which
      # is what ~/.cache/vidya-chez-android was configured with (its Mf-config
      # has empty cursesLib/ncursesLib, and disablex11=yes on the target). The
      # host Scheme here is only ever a cross compiler, and Bionic has no
      # curses.h at all — so on the target it is not a preference but a
      # requirement.
      ./configure -m=ta6le --disable-x11 --disable-curses CC_FOR_BUILD="$CC"
      make -j"$NIX_BUILD_CORES"
      make boot XM=tarm64le -j"$NIX_BUILD_CORES"

      # lz4 for the phone, not for this machine: the host build above left an
      # x86_64 liblz4.a in the same place, and the cross link needs it gone.
      make -C lz4/lib clean
      make -C lz4/lib liblz4.a -j"$NIX_BUILD_CORES" \
        CC=${cc} AR=${ndkBin}/llvm-ar

      # --disable-auto-flags stops configure appending -lrt and -lpthread, which
      # is what its unix branch does for a glibc host and what Bionic has no
      # separate libraries for — both live in libc there. Everything it would
      # otherwise add is passed explicitly below, matching the Mf-config of
      # the tree this was reconstructed from.
      ./configure -m=tarm64le --cross --disable-x11 --disable-curses \
        --disable-auto-flags \
        LIBS="-ldl -lm" \
        CC=${cc} \
        AR=${ndkBin}/llvm-ar \
        CC_FOR_BUILD="$CC" \
        ZLIB=-lz \
        LZ4="$PWD/lz4/lib/liblz4.a" \
        CPPFLAGS="-I$PWD/lz4/lib" \
        CFLAGS="-O2 -D_REENTRANT -pthread -fPIC"
      make -j"$NIX_BUILD_CORES"

      runHook postBuild
    '';

    # The whole workarea, at the paths CHEZ_ANDROID means: the host Scheme
    # loads xpatch out of xc-tarm64le/s, and the link below reads two archives
    # from elsewhere in the tree. Pruning it would only be guessing at which
    # of those the cross compiler still opens.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r . "$out/"
      runHook postInstall
    '';

    # A Scheme built for this machine and a kernel built for another one; the
    # usual fixups have an opinion about both, and neither wants it.
    dontStrip = true;
    dontPatchELF = true;
  };

  hostScheme = "${chezAndroid}/ta6le/bin/ta6le/scheme";
  targetBoot = "${chezAndroid}/boot/tarm64le";
  xpatch = "${chezAndroid}/xc-tarm64le/s/xpatch";

  # --- the Jolt half --------------------------------------------------------
  # frq's Scheme, cross-compiled to an arm64 boot image. The deps.edn below is
  # written out by hand rather than resolved: there is no dependency resolution
  # inside a cross compile, so every source root deps.edn would have resolved is
  # named as a :path instead.
  #
  # The jolt that runs it is the fork, not upstream and not the one the desktop
  # package builds: upstream reads the socket address out of `struct addrinfo`
  # at glibc's offset, which on Bionic is `ai_canonname`, and an APK built with
  # it cannot open a TLS connection at all.
  joltBoot = pkgs.stdenv.mkDerivation {
    pname = "frq-jolt-boot";
    inherit version;

    dontUnpack = true;
    strictDeps = true;
    nativeBuildInputs = [ joltAndroid ];

    buildPhase = ''
      runHook preBuild

      export HOME="$TMPDIR"
      mkdir -p project cross

      cat > project/deps.edn <<EOF
      {:paths ["${self}/src" "${glimmer}/src" "${jolt-native}/jolt/glimmer-vidya/src"]}
      EOF

      # The flat build, which is the one shape make-boot-file can take.
      ( cd project && JOLT_NO_FLAT_SPLIT=1 jolt build -m frq.app -o app )

      cat > cross/compile.ss <<EOF
      (import (chezscheme))
      (load "${xpatch}")
      (optimize-level 2)
      (generate-inspector-information #f)
      ;; Packed harder, not packed for the first time: fasl output is
      ;; compressed already, but with lz4 at its fastest setting, and on
      ;; this image that leaves 2.3 MB on the table. What reads it back is
      ;; the kernel linked into libjoltapp, which has zlib because
      ;; chezAndroid is configured ZLIB=-lz — so nothing extra ships to
      ;; decompress it.
      ;;
      ;; Less than the ratio of the whole file suggests (15.9 MB to 13.6):
      ;; compression is per fasl entry rather than over the image.
      (fasl-compressed #t)
      (compress-format 'gzip)
      (compress-level 'maximum)
      (compile-file "$PWD/project/app.build/flat.ss" "$PWD/cross/flat.so")
      (make-boot-file "$PWD/jolt.boot" '()
        "${targetBoot}/petite.boot"
        "${targetBoot}/scheme.boot"
        "$PWD/cross/flat.so")
      EOF

      SCHEMEHEAPDIRS="${chezAndroid}/ta6le/boot/ta6le" \
        ${hostScheme} --script cross/compile.ss

      runHook postBuild
    '';

    # scheme.h travels with the image because jolt_main.c includes it.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp jolt.boot "$out/jolt.boot"
      cp ${targetBoot}/scheme.h "$out/scheme.h"
      runHook postInstall
    '';
  };

  # The image travels as a blob in an object file's data section. The
  # _binary_jolt_boot_{start,end} symbols jolt_main.c reads are named after the
  # input *path*, so this copies the file somewhere it is called exactly
  # `jolt.boot` before converting it.
  joltBootObj = pkgs.runCommand "jolt-boot-obj" { } ''
    cp ${joltBoot}/jolt.boot jolt.boot
    ${ndkBin}/llvm-objcopy \
      --input-target=binary --output-target=elf64-littleaarch64 \
      --binary-architecture=aarch64 jolt.boot "$out"
  '';

  # The glue: jolt-native's jolt_main.c over the boot image, linked against
  # libvidya by name. --no-undefined is what makes a symbol the Scheme side
  # registers but the ABI no longer exports a build failure here rather than a
  # crash on the phone.
  libjoltapp = pkgs.runCommand "libjoltapp.so" { } ''
    mkdir -p lib
    cp ${nativeLibs}/lib/${abi}/libvidya.so lib/libvidya.so
    cp ${nativeLibs}/lib/${abi}/libjoltmoq.so lib/libjoltmoq.so

    ${cc} -shared -fPIC -O2 -o "$out" \
      ${jolt-native}/android/jolt_main.c \
      ${joltBootObj} \
      -I${joltBoot} \
      -I${nativeLibs}/include \
      -Llib \
      ${chezAndroid}/tarm64le/boot/tarm64le/libkernel.a \
      ${chezAndroid}/lz4/lib/liblz4.a \
      -lvidya -ljoltmoq -landroid -llog -lz -ldl -lm -Wl,--no-undefined
  '';

  # --- the Java half --------------------------------------------------------
  # One class: the photo chooser's result has to land somewhere, and native
  # code is not somewhere.
  classesDex = pkgs.runCommand "classes.dex"
    {
      nativeBuildInputs = [ pkgs.jdk17 ];
    } ''
    mkdir -p classes out
    # -encoding, because a build sandbox has no locale and javac then reads
    # the source as US-ASCII — on which the comments' em dashes are errors.
    javac --release 17 -encoding UTF-8 --class-path ${androidJar} -d classes \
      $(find ${self}/android/java -name '*.java')
    ${buildTools}/d8 --min-api ${apiLevel} --output out $(find classes -name '*.class')
    cp out/classes.dex "$out"
  '';

  # --- the package ----------------------------------------------------------
  # OpenSSL travels with the app because the platform's own is not ours to
  # load: an app's linker namespace refuses /system/lib64/libssl.so, and
  # without one there is no TLS on the phone at all.
  # Built by the NDK rather than by pkgsCross.aarch64-android: that cross
  # stdenv cannot build its own compiler-rt on this nixpkgs — os_version_check.c
  # includes <pthread.h> and the sysroot it is handed has no such header — and
  # an APK has no use for a second toolchain anyway. OpenSSL's own android-arm64
  # target wants the NDK's llvm on PATH and takes the API level from the flag.
  # The version is the one ~/.cache/frq-openssl-android was built from.
  opensslAndroid = pkgs.stdenv.mkDerivation {
    pname = "openssl-android";
    version = "3.5.4";

    src = pkgs.fetchurl {
      url = "https://github.com/openssl/openssl/releases/download/openssl-3.5.4/openssl-3.5.4.tar.gz";
      sha256 = "16ay6ppxsky3qhg6573370iz93kihfwx9n5ipmlnjcam97w12wwn";
    };

    strictDeps = true;
    nativeBuildInputs = with pkgs; [ perl ];

    configurePhase = ''
      runHook preConfigure
      export ANDROID_NDK_ROOT="${ndkRoot}"
      export PATH="${ndkBin}:$PATH"
      # Through perl rather than as a program: its shebang is /usr/bin/env,
      # which a build sandbox does not have.
      perl ./Configure android-arm64 -D__ANDROID_API__=${apiLevel} \
        shared no-tests no-docs \
        --prefix="$out" --openssldir="$out/etc/ssl"
      runHook postConfigure
    '';

    # install_sw, not install: the rest of an OpenSSL install is for a machine
    # that runs it, and this one only ships two .so files into an APK.
    installTargets = [ "install_sw" ];

    dontStrip = true;
    dontPatchELF = true;
  };

  # The libraries are stored rather than deflated: the loader maps them
  # straight out of the APK. The dex is read rather than mapped, so it may as
  # well compress.
  apkUnsigned = pkgs.runCommand "frq-unsigned.apk"
    {
      nativeBuildInputs = [ pkgs.zip ];
    } ''
    mkdir -p stage/lib/${abi}
    cp ${nativeLibs}/lib/${abi}/libvidya.so stage/lib/${abi}/libvidya.so
    cp ${nativeLibs}/lib/${abi}/libjoltmoq.so stage/lib/${abi}/libjoltmoq.so
    cp ${libcxx} stage/lib/${abi}/libc++_shared.so
    cp ${libjoltapp} stage/lib/${abi}/libjoltapp.so
    cp ${opensslAndroid.out}/lib/libssl.so stage/lib/${abi}/libssl.so
    cp ${opensslAndroid.out}/lib/libcrypto.so stage/lib/${abi}/libcrypto.so
    cp ${classesDex} stage/classes.dex
    chmod -R u+w stage

    # Everything the loader needs is in .dynsym, and that is what --strip-all
    # keeps: what goes is .symtab and the debug sections, which are read by a
    # debugger and by nothing on the phone. Worth about a third of the package
    # — libjoltmoq and libc++_shared are most of it, and the release libraries
    # arrive unstripped because jolt-native's own build does not strip them.
    #
    # Here rather than in the derivations that produce them: the inputs stay
    # whole (a stripped libjoltapp is a worse thing to hand a debugger, and
    # `nix build .#libjoltapp` is how it is looked at), and this is the one
    # place that knows the difference between an object and a shipped one.
    # The NDK's, not nixpkgs' — the host strip has no opinion worth trusting
    # about an arm64 object.
    ${ndkBin}/llvm-strip --strip-all stage/lib/${abi}/*.so

    ${buildTools}/aapt2 link -o "$out" -I ${androidJar} \
      --manifest ${self}/android/AndroidManifest.xml \
      --min-sdk-version ${apiLevel} --target-sdk-version ${targetSdk} \
      --version-code 1 --version-name ${version}

    ( cd stage && \
      zip -q -0 "$out" lib/${abi}/libvidya.so lib/${abi}/libjoltmoq.so \
                       lib/${abi}/libc++_shared.so lib/${abi}/libjoltapp.so \
                       lib/${abi}/libssl.so lib/${abi}/libcrypto.so && \
      zip -q "$out" classes.dex )
  '';

  # Aligned and signed with a debug key. The key is generated here rather than
  # read from ~/.android, which is the one place this build is deliberately
  # not what the builds before it did: a keystore outside the store would make
  # the output
  # depend on the machine, and a release key has no business in the store at
  # all. So this output is installable and not reproducible — keytool stamps
  # the certificate with the time — and anything meant for a store should be
  # signed from .#apk-unsigned instead.
  apk = pkgs.runCommand "frq-${version}.apk"
    {
      nativeBuildInputs = [ pkgs.jdk17 ];
      meta = {
        description = "frq for Android, debug-signed";
        platforms = [ "x86_64-linux" ];
      };
    } ''
    export HOME="$TMPDIR"
    keytool -genkeypair -keystore debug.keystore \
      -storepass android -keypass android -alias androiddebugkey \
      -keyalg RSA -keysize 2048 -validity 10000 \
      -dname 'CN=Android Debug,O=Android,C=US'

    ${buildTools}/zipalign -f -p 4 ${apkUnsigned} aligned.apk
    ${buildTools}/apksigner sign --ks debug.keystore \
      --ks-key-alias androiddebugkey \
      --ks-pass pass:android --key-pass pass:android \
      --out "$out" aligned.apk
    ${buildTools}/apksigner verify "$out"
  '';
in
{
  inherit chezAndroid joltBoot libjoltapp classesDex apk;
  apk-unsigned = apkUnsigned;
}
