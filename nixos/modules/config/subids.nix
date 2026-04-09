{
  config,
  lib,
  pkgs,
  ...
}:

# Manage /etc/subuid and /etc/subgid when user creation is handled by userborn
# or systemd-sysusers. The legacy perl path (update-users-groups.pl) writes
# these files itself; this module is a no-op there to avoid two writers.

let
  cfg = config.users.subIdRanges;
  userCfg = config.users;

  usePerl = !(config.services.userborn.enable || config.systemd.sysusers.enable);

  relevantUsers = lib.filterAttrs (
    _: u: u.enable && (u.autoSubUidGidRange || u.subUidRanges != [ ] || u.subGidRanges != [ ])
  ) userCfg.users;

  subidsJson = pkgs.writers.writeJSON "nixos-subids.json" {
    autoBase = 100000;
    autoCount = 65536;
    users = lib.mapAttrsToList (_: u: {
      inherit (u) name;
      auto = u.autoSubUidGidRange;
      subUidRanges = map (r: {
        start = r.startUid;
        inherit (r) count;
      }) u.subUidRanges;
      subGidRanges = map (r: {
        start = r.startGid;
        inherit (r) count;
      }) u.subGidRanges;
    }) relevantUsers;
  };
in
{
  options.users.subIdRanges = {
    strictOverlapCheck = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Refuse to write {file}`/etc/subuid` and {file}`/etc/subgid` when the
        resulting set of ranges would overlap across users.

        Overlapping subordinate id ranges allow one user's unprivileged
        containers to access another's. By default such overlaps only
        produce a warning, since failing would leave the files absent or
        stale; enable this to guarantee that an overlap never reaches disk.

        Only effective when [](#opt-services.userborn.enable) or
        [](#opt-systemd.sysusers.enable) is set.
      '';
    };
  };

  config = lib.mkIf (!usePerl) {
    systemd.services.nixos-subids = {
      wantedBy = [ "sysinit.target" ];
      requiredBy = [ "sysinit-reactivation.target" ];
      after = [
        "systemd-remount-fs.service"
        # Run after user creation so /etc/passwd is fully populated; the
        # tool itself only needs the file to exist for the symlink-removal
        # check, but ordering after user creation keeps the boot graph
        # simple and matches the perl-path semantics.
        "userborn.service"
        "systemd-sysusers.service"
        "userborn-import-legacy.service"
      ];
      before = [
        "sysinit.target"
        "sysinit-reactivation.target"
        "shutdown.target"
      ];
      conflicts = [ "shutdown.target" ];
      restartTriggers = [ subidsJson ];
      unitConfig = {
        Description = "Manage /etc/subuid and /etc/subgid";
        DefaultDependencies = false;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe pkgs.nixos-subids} ${lib.optionalString cfg.strictOverlapCheck "--strict "}${subidsJson} /etc";
      };
    };
  };
}
