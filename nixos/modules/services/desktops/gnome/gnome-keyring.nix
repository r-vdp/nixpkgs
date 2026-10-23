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
      pkgs.gcr_3
    ];

    xdg.portal.extraPortals = [ pkgs.gnome-keyring ];

    security.pam.services.login.enableGnomeKeyring = true;

    # The socket listens on %t/keyring/control; pam_gnome_keyring connects
    # there to send the unlock password, which socket-activates the daemon
    # inside the named unit so it has a stable place for drop-ins and
    # restarts.
    systemd.packages = [ pkgs.gnome-keyring ];
    systemd.user.sockets.gnome-keyring-daemon = {
      wantedBy = [ "sockets.target" ];
      # Greeters and other system users get a user manager too, but have
      # no writable home to keep keyrings in.
      unitConfig.ConditionUser = "!@system";
    };
    systemd.user.services.gnome-keyring-daemon.serviceConfig.Slice = "session.slice";
  };
}
