{ lib
, stdenv
, fetchFromGitHub
, bintools-unwrapped
, callPackage
, coreutils
, substituteAll
, unzip
, fetchurl
}:

let
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
      cp bin/ape-${stdenv.targetPlatform.parsed.cpu.name}.elf $out/bin/ape

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

  outputs = [ "out" "dist" ];

  # slashes are significant because upstream uses o/$(MODE)/foo.o
  buildFlags = [
    "o/cosmopolitan.h"
    "o//cosmopolitan.a"
    "o//libc/crt/crt.o"
    "o//ape/ape.o"
    "o//ape/ape.lds"
    "o//ape/ape-no-modify-self.o"
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

    mkdir -p $out/{include,lib}
    install o/cosmopolitan.h $out/include
    install o/cosmopolitan.a o/libc/crt/crt.o o/ape/ape.{o,lds} o/ape/ape-no-modify-self.o $out/lib
    cp -RT . "$dist"

    runHook postInstall
  '';

  passthru = {
    cosmocc = callPackage ./cosmocc.nix {
      cosmopolitan = finalAttrs.finalPackage;
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
