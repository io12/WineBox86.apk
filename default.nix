{ wineVersion ? "6.0-rc6" }:

let
  # https://github.com/NixOS/nixpkgs/pull/113122
  pkgs = import (fetchTarball
    "https://github.com/s1341/nixpkgs/archive/android_prebuilt_working.tar.gz") {
      config = {
        android_sdk.accept_license = true;
        packageOverrides = pkgs:
          let isAndroid = pkgs.hostPlatform.isAndroid;
          in {
            pkg-config-unwrapped = pkgs.pkg-config-unwrapped.overrideAttrs
              (oldAttrs:
                (pkgs.lib.optionalAttrs isAndroid {
                  hardeningDisable = [ "all" ];
                  configureFlags = oldAttrs.configureFlags
                    ++ [ "CFLAGS=-Werror=implicit-function-declaration" ];
                }));
            bash = pkgs.bash.overrideAttrs (oldAttrs:
              pkgs.lib.optionalAttrs isAndroid {
                hardeningDisable = [ "all" ];
              });
            gnutls = pkgs.gnutls.overrideAttrs (oldAttrs:
              pkgs.lib.optionalAttrs isAndroid {
                buildInputs = [ pkgs.gmp ];
                outputs = [ "dev" "out" ];
                hardeningDisable = [ "all" ];
                configureFlags = oldAttrs.configureFlags ++ [
                  "--without-p11-kit"
                  "--without-idn"
                  "--with-included-libtasn1"
                  "--with-included-unistring"
                  "-disable-cxx"
                  "--disable-maintainer-mode"
                  "--disable-static"
                  "--disable-doc"
                  "--disable-tools"
                  "--disable-tests"
                ];
              });
            zlib = pkgs.zlib.overrideAttrs (oldAttrs:
              pkgs.lib.optionalAttrs isAndroid {
                # https://stackoverflow.com/questions/53129109/android-studio-gradle-is-not-packing-my-shared-library-named-mylib-so-1-in-apk
                postPatch = oldAttrs.postPatch + ''
                  substituteInPlace configure --replace 'libz.so.1' 'libz.so'
                '';
              });
            nettle = pkgs.nettle.overrideAttrs (oldAttrs:
              pkgs.lib.optionalAttrs isAndroid {
                # https://stackoverflow.com/questions/53129109/android-studio-gradle-is-not-packing-my-shared-library-named-mylib-so-1-in-apk
                configureFlags = oldAttrs.configureFlags ++ [ "LIBNETTLE_SONAME=libnettle.so" ];
              });
          };
      };
    };

  androidPkgs = pkgs.pkgsCross.armv7a-android-prebuilt;

  androidSdk = (pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "25" ];
    buildToolsVersions = [ "25.0.3" ];
  }).androidsdk;

  llvmMingw = pkgs.stdenv.mkDerivation {
    name = "llvm-mingw";
    src = pkgs.fetchurl {
      url =
        "https://github.com/mstorsjo/llvm-mingw/releases/download/20211002/llvm-mingw-20211002-ucrt-ubuntu-18.04-x86_64.tar.xz";
      hash = "sha256-MOlAB4NlIJHZJ4ziHlwXDQGl9E5PGiVxe2PNmtn74Ts=";
    };
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    dontStrip = true;
    installPhase = ''
      mkdir $out
      cp -r * $out
    '';
  };

  src = fetchGit {
    url = "git://source.winehq.org/git/wine.git";
    ref = "refs/tags/wine-${wineVersion}";
  };

  wineTools = pkgs.stdenv.mkDerivation {
    name = "wine-tools";
    inherit src;
    nativeBuildInputs = [ pkgs.flex pkgs.bison pkgs.freetype ];
    configurePhase = ''
      mkdir tools-build
      cd tools-build
      ../configure --without-x --enable-win64
      cd ..
    '';
    buildPhase = ''
      cd tools-build
      make __tooldeps__
      cd ..
    '';
    installPhase = ''
      mkdir -p $out
      cp -r * $out
    '';
  };

  androidGccSymlink = pkgs.linkFarm "android-gcc-symlink" [{
    name = "bin/${androidPkgs.hostPlatform.config}-gcc";
    path =
      "${androidPkgs.stdenv.cc}/bin/${androidPkgs.hostPlatform.config}-clang";
  }];

  gradle_3 = pkgs.stdenv.mkDerivation rec {
    name = "gradle-3.5.1";
    src = pkgs.fetchurl {
      url = "https://services.gradle.org/distributions/${name}-bin.zip";
      hash = "sha256-jc419S1Me0pJRt9zqigw52unFIhQdT2LXpTF3DJc7vg=";
    };
    nativeBuildInputs = [ pkgs.unzip ];
    installPhase = ''
      mkdir $out
      cp -r bin lib $out
    '';
  };

  androidWineGradleDeps = androidPkgs.stdenv.mkDerivation {
    name = "android-wine-gradle-deps";
    inherit src;
    nativeBuildInputs =
      [ pkgs.jdk8 gradle_3 pkgs.perl pkgs.librsvg androidSdk ];
    ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
    ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
    patchPhase = ''
      sed "s/@PACKAGE_VERSION@/7.0-rc1/g" dlls/wineandroid.drv/build.gradle.in > dlls/wineandroid.drv/build.gradle
    '';
    dontConfigure = true;
    buildPhase = ''
      mkdir /build/.android
      export GRADLE_USER_HOME=$(mktemp -d)
      (cd dlls/wineandroid.drv && gradle --no-daemon -Psrcdir=/build/source assembleDebug)
    '';
    installPhase = ''
      find $GRADLE_USER_HOME/caches/modules-2 -type f -regex '.*\.\(jar\|pom\)' \
        | perl -pe 's#(.*/([^/]+)/([^/]+)/([^/]+)/[0-9a-f]{30,40}/([^/\s]+))$# ($x = $2) =~ tr|\.|/|; "install -Dm444 $1 \$out/$x/$3/$4/$5" #e' \
        | sh
    '';
    outputHashMode = "recursive";
    outputHash = "sha256-jKykmhtp1F5rWupr5P7q/eh91FPPeffFJY/+bbPlUWg=";
  };

  fakeGradle = pkgs.writeShellScriptBin "gradle" ''
    mkdir -p build/outputs/apk
    : > build/outputs/apk/wine-debug.apk
  '';

  androidWineAssets = androidPkgs.stdenv.mkDerivation {
    name = "android-wine-assets";
    inherit src;
    buildInputs = [ androidPkgs.freetype ];
    nativeBuildInputs =
      [ pkgs.flex pkgs.bison androidGccSymlink llvmMingw fakeGradle wineTools ];
    configureFlags = [ "--with-wine-tools=${wineTools}/tools-build" ];
    installTargets = [ "install-lib" ];
    dontFixup = true;
  };

  androidWine = androidPkgs.stdenv.mkDerivation {
    name = "android-wine";
    inherit src;
    nativeBuildInputs = [
      pkgs.jdk8
      gradle_3
      androidSdk
      pkgs.librsvg
      androidWineAssets
      androidPkgs.zlib.out
      androidPkgs.bzip2.out
      androidPkgs.libpng.out
      androidPkgs.libjpeg_original.out
      androidPkgs.freetype.out
      androidPkgs.lcms2.out
      androidPkgs.libtiff.out
      androidPkgs.libxml2.out
      androidPkgs.libxslt.out
      androidPkgs.gmp.out
      androidPkgs.nettle.out
      androidPkgs.gnutls.out
    ];
    ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
    ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
    dontConfigure = true;
    buildPhase = ''
      export GRADLE_USER_HOME=$(mktemp -d)

      cp dlls/wineandroid.drv/build.gradle{.in,}

      # Point gradle to offline repo
      sed -i \
        -e "s#jcenter()#maven { url '${androidWineGradleDeps}' }#g" \
        -e "s/@PACKAGE_VERSION@/7.0-rc1/g" \
        dlls/wineandroid.drv/build.gradle

      # Copy any non-wine libs
      mkdir -p dlls/wineandroid.drv/lib/armeabi-v7a
      cp \
        ${androidPkgs.zlib.out}/lib/libz.so \
        ${androidPkgs.bzip2.out}/lib/libbz2.so \
        ${androidPkgs.libpng.out}/lib/libpng16.so \
        ${androidPkgs.libjpeg_original.out}/lib/libjpeg.so \
        ${androidPkgs.freetype.out}/lib/libfreetype.so \
        ${androidPkgs.lcms2.out}/lib/liblcms2.so \
        ${androidPkgs.libtiff.out}/lib/libtiff.so \
        ${androidPkgs.libxml2.out}/lib/libxml2.so \
        ${androidPkgs.libxslt.out}/lib/libxslt.so \
        ${androidPkgs.gmp.out}/lib/libgmp.so \
        ${androidPkgs.nettle.out}/lib/libnettle.so \
        ${androidPkgs.gnutls.out}/lib/libgnutls.so \
        dlls/wineandroid.drv/lib/armeabi-v7a

      # Copy wine files
      cp --no-preserve=all -r ${androidWineAssets} dlls/wineandroid.drv/assets

      # Build APK with gradle
      (cd dlls/wineandroid.drv && gradle --no-daemon -Psrcdir=/build/source assembleDebug)
    '';
    installPhase = ''
      mkdir $out
      mv dlls/wineandroid.drv/build/outputs/apk/wine-debug.apk $out/wine-${wineVersion}.apk
    '';
  };

in androidWine
