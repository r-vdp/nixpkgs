{ config, lib, pkgs, ... }:

{

  imports = [ ./etc.nix ];

  config = lib.mkMerge [

    {
      system.activationScripts.etc =
        lib.stringAfter [ "users" "groups" ] config.system.build.etcActivationCommands;
    }

    (lib.mkIf config.system.etc.overlay.enable {

      assertions = [
        {
          assertion = config.boot.initrd.systemd.enable;
          message = "`system.etc.overlay.enable` requires `boot.initrd.systemd.enable`";
        }
        {
          assertion = (!config.system.etc.overlay.mutable) -> (config.systemd.sysusers.enable || config.services.userborn.enable);
          message = "`!system.etc.overlay.mutable` requires `systemd.sysusers.enable` or `services.userborn.enable`";
        }
        {
          assertion = lib.versionAtLeast config.boot.kernelPackages.kernel.version "6.6";
          message = "`system.etc.overlay.enable requires a newer kernel, at least version 6.6";
        }
      ];

      boot.initrd.availableKernelModules = [ "loop" "erofs" "overlay" ];

      boot.initrd.systemd = {
        mounts = [
          {
            where = "/run/etc-metadata";
            what = "/tmp/etc-metadata-image";
            type = "erofs";
            options = "loop";
            unitConfig = {
              DefaultDependencies = false;
              RequiresMountsFor = [
                "/sysroot/nix/store"
              ];
            };
            requires = [ "find-etc-metadata-image.service" ];
            after = [ "local-fs-pre.target" "find-etc-metadata-image.service" ];
          }
          {
            where = "/sysroot/etc";
            what = "overlay";
            type = "overlay";
            options = lib.concatStringsSep "," ([
              "relatime"
              "redirect_dir=on"
              "metacopy=on"
              "lowerdir=/run/etc-metadata::/sysroot${config.system.build.etcBasedir}"
            ] ++ lib.optionals config.system.etc.overlay.mutable [
              "rw"
              "upperdir=/sysroot/.rw-etc/upper"
              "workdir=/sysroot/.rw-etc/work"
            ] ++ lib.optionals (!config.system.etc.overlay.mutable) [
              "ro"
            ]);
            requiredBy = [ "initrd-fs.target" ];
            before = [ "initrd-fs.target" ];
            requires = lib.mkIf config.system.etc.overlay.mutable [ "rw-etc.service" ];
            after = lib.mkIf config.system.etc.overlay.mutable [ "rw-etc.service" ];
            unitConfig.RequiresMountsFor = [
              "/sysroot/nix/store"
              "/run/etc-metadata"
            ];
          }
        ];
        services = lib.mkMerge [
          (lib.mkIf config.system.etc.overlay.mutable {
            rw-etc = {
              unitConfig = {
                DefaultDependencies = false;
                RequiresMountsFor = "/sysroot";
              };
              serviceConfig = {
                Type = "oneshot";
                ExecStart = ''
                  /bin/mkdir -p -m 0755 /sysroot/.rw-etc/upper /sysroot/.rw-etc/work
                '';
              };
            };
          })
          {
            find-etc-metadata-image = {
              description = "Find the path to the etc metadata image";
              before = [ "shutdown.target" ];
              conflicts = [ "shutdown.target" ];
              unitConfig = {
                DefaultDependencies = false;
                RequiresMountsFor = "/sysroot/nix/store";
              };
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };

              script = /* bash */ ''
                set -uo pipefail

                # Figure out what closure to boot
                closure=
                for o in $(< /proc/cmdline); do
                    case $o in
                        init=*)
                            IFS='=' read -r -a initParam <<< "$o"
                            closure="''${initParam[1]}"
                            ;;
                    esac
                done

                # Sanity check
                if [ -z "''${closure:-}" ]; then
                  echo 'No init= parameter on the kernel command line' >&2
                  exit 1
                fi

                # Resolve symlinks in the init parameter
                closure="$(chroot /sysroot ${lib.getExe' pkgs.coreutils "realpath"} "$closure")"
                # Assume the directory containing the init script is the closure.
                closure="$(dirname "$closure")"

                metadata_image="$(chroot /sysroot ${lib.getExe' pkgs.coreutils "realpath"} "$closure/etc-metadata-image")"
                ln -s "/sysroot$metadata_image" /tmp/etc-metadata-image
              '';
            };
          }
        ];
      };

    })

  ];
}
