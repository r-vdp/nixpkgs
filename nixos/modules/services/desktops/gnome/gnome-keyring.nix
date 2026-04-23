# GNOME Keyring daemon.

{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.gnome.gnome-keyring;
in
{

  meta = {
    teams = [ lib.teams.gnome ];
  };

  options = {
    services.gnome.gnome-keyring = {
      enable = lib.mkEnableOption ''
        GNOME Keyring daemon, a service designed to
        take care of the user's security credentials,
        such as user names and passwords
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.gnome-keyring ];

    services.dbus.packages = [
      pkgs.gnome-keyring
      pkgs.gcr
    ];

    xdg.portal.extraPortals = [ pkgs.gnome-keyring ];

    security.pam.services.login.enableGnomeKeyring = true;

    # The socket listens on %t/keyring/control; pam_gnome_keyring connects
    # there to send the unlock password, which socket-activates the daemon
    # inside the named unit so it has a stable place for drop-ins and
    # restarts.
    systemd.packages = [ pkgs.gnome-keyring ];
    systemd.user.sockets.gnome-keyring-daemon.wantedBy = [ "sockets.target" ];
    systemd.user.services.gnome-keyring-daemon.serviceConfig = {
      # The daemon mlock()s its secret-memory pool (16 KiB blocks). It
      # checks for CAP_IPC_LOCK and warns if absent, but the actual
      # mlock() only needs RLIMIT_MEMLOCK headroom. Granting the cap via
      # a setcap wrapper hard-fails under no_new_privs (which any seccomp
      # sandbox option on a user unit forces), so set the rlimit instead.
      LimitMEMLOCK = "64M";
      Slice = "session.slice";
    };
  };
}
