{
  runCommand,
  evalSystem,
}:
let
  config =
    (evalSystem (
      { pkgs, ... }:
      let
        mkServices =
          name:
          pkgs.runCommand "dbus-test-${name}" { } ''
            for d in services system-services interfaces; do
              mkdir -p $out/share/dbus-1/$d
              touch $out/share/dbus-1/$d/org.nixos.test.${name}.service
            done
          '';
        registered = mkServices "Registered";
      in
      {
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "nodev";
          fsType = "tmpfs";
        };
        system.stateVersion = "26.11";

        # Several desktop modules link all of /share, see #47173.
        environment.pathsToLink = [ "/share" ];
        environment.systemPackages = [ (mkServices "Unregistered") ];

        services.dbus.packages = [
          registered
          registered
        ];
      }
    )).config;
in
runCommand "dbus-config-test"
  {
    etc = config.environment.etc."dbus-1".source;
    systemPath = config.system.path;
  }
  ''
    fail() {
      echo "$1"
      exit 1
    }

    for conf in $etc/system.conf $etc/session.conf; do
      dirs=$(grep --only-matching '<servicedir>[^<]*' $conf)
      if ! grep --quiet dbus-test-Registered <<<"$dirs"; then
        fail "registered package missing in $conf"
      fi
      if grep --quiet dbus-test-Unregistered <<<"$dirs"; then
        fail "unregistered package in $conf"
      fi
      dups=$(sort <<<"$dirs" | uniq --repeated)
      if [[ -n $dups ]]; then
        fail "duplicate servicedirs in $conf: $dups"
      fi
    done

    # Service files must not reach the system profile, where the session
    # bus would find them through XDG_DATA_DIRS. Other D-Bus files stay.
    if [[ ! -e $systemPath/share/dbus-1/interfaces/org.nixos.test.Unregistered.service ]]; then
      fail "share/dbus-1/interfaces missing from the system profile"
    fi
    for d in services system-services; do
      if [[ -e $systemPath/share/dbus-1/$d ]]; then
        fail "share/dbus-1/$d is in the system profile"
      fi
    done

    touch $out
  ''
