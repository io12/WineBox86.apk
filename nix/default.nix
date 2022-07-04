{ wineVersion ? "7.0-rc5" }:

let
  # https://github.com/NixOS/nixpkgs/pull/113122
  pkgsFun = import (fetchTarball
    "https://github.com/s1341/nixpkgs/archive/android_prebuilt_working.tar.gz");

  pkgsConfig = {
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
          pkgs.lib.optionalAttrs isAndroid { hardeningDisable = [ "all" ]; });
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
            configureFlags = oldAttrs.configureFlags
              ++ [ "LIBNETTLE_SONAME=libnettle.so" ];
          });
      };
  };

  pkgs = pkgsFun { config = pkgsConfig; };

  androidX86Pkgs = pkgsFun {
    config = pkgsConfig;
    crossSystem = {
      config = "i686-unknown-linux-android";
      sdkVer = "29";
      ndkVer = "21";
      useAndroidPrebuilt = true;
    };
  };

  androidArmPkgs = pkgs.pkgsCross.armv7a-android-prebuilt;

  ndkBundle = (pkgs.androidenv.composeAndroidPackages {
    includeNDK = true;
    ndkVersion = "21.0.6113669";
  }).ndk-bundle;

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

  androidX86GccSymlink = pkgs.linkFarm "android-gcc-symlink" [{
    name = "bin/${androidX86Pkgs.hostPlatform.config}-gcc";
    path =
      "${androidX86Pkgs.stdenv.cc}/bin/${androidX86Pkgs.hostPlatform.config}-clang";
  }];

  androidArmGccSymlink = pkgs.linkFarm "android-gcc-symlink" [{
    name = "bin/${androidArmPkgs.hostPlatform.config}-gcc";
    path =
      "${androidArmPkgs.stdenv.cc}/bin/${androidArmPkgs.hostPlatform.config}-clang";
  }];

  fakeGradle = pkgs.writeShellScriptBin "gradle" ''
    mkdir -p build/outputs/apk
    : > build/outputs/apk/wine-debug.apk
  '';

  androidX86Wine = androidX86Pkgs.stdenv.mkDerivation {
    name = "android-x86-wine";
    inherit src;
    buildInputs = [ androidX86Pkgs.freetype androidX86Pkgs.xorg.libX11 ];
    nativeBuildInputs = [
      pkgs.flex
      pkgs.bison
      androidX86GccSymlink
      llvmMingw
      fakeGradle
      wineTools
    ];
    configureFlags = [
      "--with-wine-tools=${wineTools}/tools-build"
      "--with-x"
      "enable_wineandroid_drv=no"
    ];
    enableParallelBuilding = true;
    dontFixup = true;
  };

  androidArmWine = androidArmPkgs.stdenv.mkDerivation {
    name = "android-arm-wine";
    inherit src;
    buildInputs = [ androidArmPkgs.freetype androidArmPkgs.xorg.libX11 ];
    nativeBuildInputs = [
      pkgs.flex
      pkgs.bison
      androidArmGccSymlink
      llvmMingw
      fakeGradle
      wineTools
    ];
    configureFlags = [
      "--with-wine-tools=${wineTools}/tools-build"
      "--with-x"
      "enable_wineandroid_drv=no"
    ];
    enableParallelBuilding = true;
    dontFixup = true;
  };

  androidArmBox86 = pkgs.stdenv.mkDerivation {
    name = "android-arm-box86";
    src = fetchGit {
      url = "https://github.com/ptitSeb/box86";
      rev = "fe53eeb010733e5a1bfa79b8e73399ed63a8a524";
    };
    nativeBuildInputs = [ pkgs.cmake pkgs.python3 ndkBundle ];
    configurePhase = ''
      mkdir build
      cd build
      cmake .. \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DANDROID=1 \
        -DNOLOADADDR=1 \
        -DANDROID_ABI=armeabi-v7a \
        -DCMAKE_TOOLCHAIN_FILE=${ndkBundle}/libexec/android-sdk/ndk-bundle/build/cmake/android.toolchain.cmake \
        -DANDROID_NATIVE_API_LEVEL=28
    '';
    preBuild = "make clean";
    installPhase = ''
      mkdir $out
      cp box86 $out
    '';
  };

in androidArmBox86
