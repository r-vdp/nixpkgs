{ lib
, stdenv
, fetchFromGitHub
, bintools-unwrapped
, callPackage
, coreutils
, substituteAll
, runCommand
, unzip
, fetchurl
}:

let
  arch = stdenv.targetPlatform.parsed.cpu.name;
  kernel = stdenv.targetPlatform.parsed.kernel.name;

  ape = stdenv.mkDerivation (finalAttrs: {
    pname = "ape";
    version = "3.2.4";
    src = fetchurl {
      url = "https://cosmo.zip/pub/cosmocc/cosmocc-${finalAttrs.version}.zip";
      hash = "sha256-0vptv2+YcxBJRYHe/1uRXb3FynAfIPdhO7Dc8d4u5RE=";
    };

    unpackCmd = ''
      mkdir --parent realSrc
      unzip -d realSrc $curSrc
    '';

    dontConfigure = true;
    dontBuild = true;
    doCheck = false;
    dontFixup = true;

    outputs = [ "out" "cosmoccbin" ];

    installPhase = ''
      runHook preInstall

      mkdir --parent $out/bin
      cp bin/ape-${arch}.elf $out/bin/ape

      cp -a . $cosmoccbin

      runHook postInstall
    '';

    nativeBuildInputs = [
      unzip
    ];

    meta = {
      platforms = lib.platforms.linux;
    };
  });
in

stdenv.mkDerivation (finalAttrs: {
  pname = "cosmopolitan";
  version = "3.2.4";

  src = fetchFromGitHub {
    owner = "jart";
    repo = "cosmopolitan";
    rev = finalAttrs.version;
    hash = "sha256-DWacTVHZQ1yKpH+moSkf5wTs9TVaeuVaRcrZKWFVujw=";
  };

  #patches = [
  #  # make sure tests set PATH correctly
  #  (substituteAll {
  #    src = ./fix-paths.patch;
  #    inherit coreutils;
  #  })
  #];

  nativeBuildInputs = [
    ape
    bintools-unwrapped
    unzip
  ];

  strictDeps = true;

  outputs = [ "out" ];

  # slashes are significant because upstream uses o/$(MODE)/foo.o
  buildFlags = [
    "o//tool/build/apelink.com"

    "o/cosmopolitan.h"

    "o/cosmocc.h.txt"
    "o//ape/ape.lds"
    "o//libc/crt/crt.o"
    "o//ape/ape.elf"
    "o//ape/ape.macho"
    "o//ape/ape.o"
    "o//ape/ape-copy-self.o"
    "o//ape/ape-no-modify-self.o"
    "o//cosmopolitan.a"
    "o//third_party/libcxx/libcxx.a"
    "o//tool/build/assimilate.com.dbg"
    "o//tool/build/march-native.com.dbg"
    "o//tool/build/mktemper.com.dbg"
    "o//tool/build/fixupobj.com.dbg"
    "o//tool/build/zipcopy.com.dbg"
    "o//tool/build/mkdeps.com.dbg"
    "o//tool/build/zipobj.com.dbg"
    "o//tool/build/apelink.com.dbg"
    "o//tool/build/pecheck.com.dbg"
    "o//third_party/make/make.com.dbg"
    "o//third_party/ctags/ctags.com.dbg"



    #"o/cosmopolitan.h"
    #"o//cosmopolitan.a"
    #"o//libc/crt/crt.o"
    #"o//ape/ape.o"
    #"o//ape/ape.lds"
    #"o//ape/ape-no-modify-self.o"
  ];

  buildPhase = ''
    runHook preBuild

    mkdir --parent .cosmocc
    cp -a ${ape.cosmoccbin} .cosmocc/3.2

    # shellcheck disable=SC2086
    local flagsArray=(
      ''${enableParallelBuilding:+-j''${NIX_BUILD_CORES}}
      SHELL=$SHELL
    )
    _accumFlagsArray makeFlags makeFlagsArray buildFlags buildFlagsArray

    echoCmd 'build flags' "''${flagsArray[@]}"
    $src/build/bootstrap/make.com "''${flagsArray[@]}"

    foundMakefile=1

    runHook postBuild
  '';

  checkTarget = "o//test";

  enableParallelBuilding = true;

  doCheck = true;
  dontConfigure = true;
  dontFixup = true;

  preCheck =
    let
      failingTests = [
        # some syscall tests fail because we're in a sandbox
        "test/libc/calls/sched_setscheduler_test.c"
        "test/libc/thread/pthread_create_test.c"
        "test/libc/calls/getgroups_test.c"
        "test/libc/calls/getprogramexecutablename_test.c"
        "test/libc/calls/ioctl_test.c"
        "test/libc/proc/execve_test.c"
        "test/libc/proc/posix_spawn_test.c"
        "test/libc/proc/sched_getaffinity_test.c"
        "test/libc/sock/socket_test.c"
        "test/posix/sigchld_test.c"
        "test/tool/net/lunix_test.lua"
      ];
    in
    lib.concatStringsSep ";\n" (map (t: "rm -v ${t}") failingTests);

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin/"
    cp tool/cosmocc/README.md "$out/"
    cp tool/cosmocc/LICENSE.* "$out/"

    mkdir -p "$out/include/"
    cp -R libc/isystem/* "$out/include/"
    cp -R libc/integral "$out/include/libc/"
    for x in $(cat o/cosmocc.h.txt); do
      mkdir -p "$out/include/''${x%/*}/"
      cp -f $x "$out/include/''${x%/*}/"
    done


    # TODO: include patched GCC

    mkdir -p "$out/${arch}-${kernel}-cosmo/lib/"
    cp -f o/libc/crt/crt.o "$out/${arch}-${kernel}-cosmo/lib/"
    cp -f o/cosmopolitan.a "$out/${arch}-${kernel}-cosmo/lib/libcosmo.a"
    cp -f o/third_party/libcxx/libcxx.a "$out/${arch}-${kernel}-cosmo/lib/"
    for lib in c dl gcc_s m pthread resolv rt dl z stdc++; do
      printf '\041\074\141\162\143\150\076\012' >"$out/${arch}-${kernel}-cosmo/lib/lib$lib.a"
    done

    cp -f o/ape/ape.o "$out/${arch}-${kernel}-cosmo/lib/"
    cp -f o/ape/ape.lds "$out/${arch}-${kernel}-cosmo/lib/"
    cp -f o/ape/ape-no-modify-self.o "$out/${arch}-${kernel}-cosmo/lib/"

    cp -af tool/cosmocc/bin/* "$out/bin/"
    cp -f o/ape/ape.elf "$out/bin/ape-${arch}.elf"
    for x in assimilate march-native mktemper fixupobj zipcopy apelink pecheck mkdeps zipobj; do
      ape o/tool/build/apelink.com \
        -l o/ape/ape.elf \
        -o "$out/bin/$x" \
        o/tool/build/$x.com.dbg
    done



    #mkdir -p $out/{include,lib}
    #install o/cosmopolitan.h $out/include
    #install o/cosmopolitan.a o/libc/crt/crt.o o/ape/ape.{o,lds} o/ape/ape-no-modify-self.o $out/lib
    #cp -RT . "$dist"

    runHook postInstall
  '';

  passthru = {
    cosmocc = callPackage ./cosmocc.nix {
      cosmopolitan = finalAttrs.finalPackage;
    };
    tests = {
      cc = runCommand "c-test" { } ''
        ${lib.getExe' finalAttrs.finalPackage "cosmocc"} ${./hello.c}
        ./a.out > $out
      '';
    };
  };

  meta = {
    homepage = "https://justine.lol/cosmopolitan/";
    description = "Your build-once run-anywhere c library";
    license = lib.licenses.isc;
    maintainers = lib.teams.cosmopolitan.members;
    platforms = lib.platforms.x86_64;
    badPlatforms = lib.platforms.darwin;
  };
})
