{
  stdenv,
  lib,
  buildPackages,
  gettext,
  meson,
  ninja,
  fetchurl,
  apacheHttpdPackages,
  pkg-config,
  glib,
  libxml2,
  systemd,
  wrapGAppsNoGuiHook,
  itstool,
  gnome,
}:

let
  inherit (apacheHttpdPackages) apacheHttpd mod_dnssd;
in

stdenv.mkDerivation (finalAttrs: {
  pname = "gnome-user-share";
  version = "47.2";

  src = fetchurl {
    url = "mirror://gnome/sources/gnome-user-share/${lib.versions.major finalAttrs.version}/gnome-user-share-${finalAttrs.version}.tar.xz";
    hash = "sha256-H6wbuIAN+kitnD4ZaQ9+EOZ6T5lNnLF8rh0b3/yRRLo=";
  };

  preConfigure =
    ''
      sed -e 's,^LoadModule dnssd_module.\+,LoadModule dnssd_module ${mod_dnssd}/modules/mod_dnssd.so,' \
        -e 's,''${HTTP_MODULES_PATH},${apacheHttpd}/modules,' \
        -i data/dav_user_2.4.conf
    ''
    + lib.optionalString (!stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      substituteInPlace meson.build --replace-fail \
        "run_command([httpd, '-v']" \
        "run_command(['${stdenv.hostPlatform.emulator buildPackages}', httpd, '-v']"
    '';

  mesonFlags = [
    "-Dhttpd=${apacheHttpd.out}/bin/httpd"
    "-Dmodules_path=${apacheHttpd}/modules"
    "-Dsystemduserunitdir=${placeholder "out"}/etc/systemd/user"
  ];

  nativeBuildInputs = [
    pkg-config
    meson
    ninja
    gettext
    glib # for glib-compile-schemas
    itstool
    libxml2
    wrapGAppsNoGuiHook
  ];

  buildInputs = [
    glib
    systemd
  ];

  doCheck = true;
  strictDeps = true;

  passthru = {
    updateScript = gnome.updateScript {
      packageName = "gnome-user-share";
    };
  };

  meta = with lib; {
    homepage = "https://gitlab.gnome.org/GNOME/gnome-user-share";
    changelog = "https://gitlab.gnome.org/GNOME/gnome-user-share/-/blob/${finalAttrs.version}/NEWS?ref_type=tags";
    description = "Service that exports the contents of the Public folder in your home directory on the local network";
    teams = [ teams.gnome ];
    license = licenses.gpl2Plus;
    platforms = platforms.linux;
  };
})
