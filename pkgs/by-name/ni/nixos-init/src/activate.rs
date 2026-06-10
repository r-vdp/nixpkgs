use std::{
    env, fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use pathrs::{Root, flags::RenameFlags};

use rustix::mount::{mount, mount_remount};

use crate::{
    config::{Config, SpecialMount},
    etc_overlay::{EtcLayout, RwLayout, setup_etc},
    fs::{atomic_symlink, split_mount_opts},
    proc_mounts::Mounts,
};

/// Entrypoint for the `activate` binary.
///
/// Activate a `NixOS` system configuration on the running system.
pub fn activate_main() -> Result<()> {
    let args: Vec<String> = env::args().collect();

    if args.len() != 2 {
        bail!("Usage: {} <toplevel>", args[0]);
    }

    // Canonicalize so /run/current-system points at the resolved store path.
    let toplevel = fs::canonicalize(&args[1])
        .with_context(|| format!("Failed to canonicalize toplevel path {}", args[1]))?;

    let config =
        Config::from_toplevel(&toplevel, "/").context("Failed to load nixos-init config")?;

    log::info!("Setting up special filesystems...");
    setup_special_filesystems(&config.special_filesystems)?;

    activate("/", &toplevel, &config)?;

    // (Re)mount the /etc overlay. Skipped in initrd (initrd-etc-overlay
    // handles /sysroot/etc there) and when the overlay isn't enabled
    // (the perl setup-etc.pl path stays in the bash activation script).
    if env::var_os("IN_NIXOS_SYSTEMD_STAGE1").is_none()
        && let (Some(meta), Some(base)) = (&config.etc_metadata_image, &config.etc_basedir)
    {
        setup_etc(&EtcLayout {
            etc: "/etc".to_owned(),
            metadata_image: meta.clone(),
            basedir: base.clone(),
            rw: config.etc_overlay_mutable.then(|| RwLayout {
                base: PathBuf::from("/.rw-etc"),
            }),
        })?;
    }

    Ok(())
}

/// Mount or remount each entry in `boot.specialFileSystems`.
fn setup_special_filesystems(mounts: &[SpecialMount]) -> Result<()> {
    let existing = Mounts::parse_from_proc_mounts()?;
    for m in mounts {
        let (flags, data) = split_mount_opts(&m.options);
        if existing.find_mountpoint(&m.mountpoint).is_some() {
            mount_remount(m.mountpoint.as_str(), flags, data.as_c_str())
                .with_context(|| format!("Failed to remount {}", m.mountpoint))?;
        } else {
            fs::create_dir_all(&m.mountpoint)
                .with_context(|| format!("Failed to create {}", m.mountpoint))?;
            let mut perms = fs::metadata(&m.mountpoint)?.permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&m.mountpoint, perms)?;
            mount(
                m.device.as_str(),
                m.mountpoint.as_str(),
                m.fstype.as_str(),
                flags,
                data.as_c_str(),
            )
            .with_context(|| format!("Failed to mount {}", m.mountpoint))?;
        }
    }
    Ok(())
}

/// Activate the system.
///
/// This runs both during boot and during re-activation initiated by switch-to-configuration.
pub fn activate(prefix: &str, toplevel: impl AsRef<Path>, config: &Config) -> Result<()> {
    log::info!("Setting up /run/current-system...");
    let system_path = PathBuf::from(prefix).join("run/current-system");
    atomic_symlink(&toplevel, system_path)?;

    if let Some(modprobe_binary) = &config.modprobe_binary {
        log::info!("Setting up modprobe...");
        setup_modprobe(modprobe_binary)?;
    } else {
        log::info!("No modprobe binary provided. Not setting up modprobe.");
    }

    if let Some(firmware) = &config.firmware {
        log::info!("Setting up firmware search paths...");
        setup_firmware_search_path(firmware)?;
    } else {
        log::info!("No firmware path provided. Not setting up firmware search paths.");
    }

    log::info!("Setting up /usr/bin...");
    setup_usrbin(prefix)?;

    match config.env_binary.as_deref() {
        None => log::info!("/usr/bin/env not managed by nixos-init."),
        Some("") => {
            log::info!("Removing /usr/bin/env...");
            remove_usrbinenv(prefix)?;
        }
        Some(path) => {
            log::info!("Setting up /usr/bin/env...");
            setup_usrbinenv(prefix, path)?;
        }
    }

    match config.sh_binary.as_deref() {
        None => log::info!("/bin/sh not managed by nixos-init."),
        Some("") => {
            log::info!("Removing /bin/sh...");
            remove_binsh(prefix)?;
        }
        Some(path) => {
            log::info!("Setting up /bin/sh...");
            setup_binsh(prefix, path)?;
        }
    }

    log::info!("Setting up /bin...");
    setup_bin_symlink(prefix)
}

/// Create `/usr/bin` if it doesn't exist.
///
/// The mode is only set on a newly created directory, so an existing directory or mount (e.g.
/// envfs) is left alone.
fn setup_usrbin(prefix: &str) -> Result<()> {
    let usrbin_path = PathBuf::from(prefix).join("usr/bin");
    if usrbin_path.exists() {
        return Ok(());
    }
    fs::create_dir_all(&usrbin_path).context("Failed to create /usr/bin")?;
    fs::set_permissions(&usrbin_path, fs::Permissions::from_mode(0o755))
        .context("Failed to set permissions on /usr/bin")
}

/// Setup modprobe so that the kernel can find the wrapped binary.
///
/// See <https://docs.kernel.org/admin-guide/sysctl/kernel.html#modprobe>
fn setup_modprobe(modprobe_binary: impl AsRef<Path>) -> Result<()> {
    // This uses the procfs setup in the initrd, which is fine because it points to the same kernel
    // a procfs in a chroot would.
    const MODPROBE_PATH: &str = "/proc/sys/kernel/modprobe";

    if Path::new(MODPROBE_PATH).exists() {
        fs::write(
            MODPROBE_PATH,
            modprobe_binary.as_ref().as_os_str().as_encoded_bytes(),
        )
        .with_context(|| {
            format!(
                "Failed to populate modprobe path with {}",
                modprobe_binary.as_ref().display()
            )
        })?;
    } else {
        log::info!("{MODPROBE_PATH} doesn't exist. Not populating it...");
    }

    Ok(())
}

/// Setup the firmware search path so that the kernel can find the firmware.
///
/// See <https://www.kernel.org/doc/html/latest/driver-api/firmware/fw_search_path.html>
fn setup_firmware_search_path(firmware: impl AsRef<Path>) -> Result<()> {
    // This uses the sysfs setup in the initrd, which is fine because it points to the same kernel
    // a procfs in a chroot would.
    const FIRMWARE_SERCH_PATH: &str = "/sys/module/firmware_class/parameters/path";

    if Path::new(FIRMWARE_SERCH_PATH).exists() {
        fs::write(
            FIRMWARE_SERCH_PATH,
            firmware.as_ref().as_os_str().as_encoded_bytes(),
        )
        .with_context(|| {
            format!(
                "Failed to populate firmware search path with {}",
                firmware.as_ref().display()
            )
        })?;
    } else {
        log::info!("{FIRMWARE_SERCH_PATH} doesn't exist. Not populating it...");
    }

    Ok(())
}

/// Setup `/usr/bin/env`.
///
/// We have to setup `/usr` for `NixOS` to work.
///
/// We do this here accidentally. `/usr/bin/env` is currently load-bearing for `NixOS`.
fn setup_usrbinenv(prefix: &str, env_binary: impl AsRef<Path>) -> Result<()> {
    let usrbin_path = PathBuf::from(prefix).join("usr/bin");
    atomic_symlink(&env_binary, usrbin_path.join("env"))
}

/// Remove `/usr/bin/env`.
///
/// `/usr/bin` itself is kept by `setup_usrbin` so that `/usr` is never empty, which systemd
/// treats as a fatal boot error.
fn remove_usrbinenv(prefix: &str) -> Result<()> {
    remove_if_exists(&PathBuf::from(prefix).join("usr/bin/env"))
}

/// Setup /bin/sh.
///
/// `/bin/sh` is an essential part of a Linux system as this path is hardcoded in the `system()` call
/// from libc. See `man systemd(3)`.
///
/// The actual symlink lives in `/usr/bin` and `/bin` is a symlink to `usr/bin`. Otherwise systemd
/// taints the system with `unmerged-usr`.
fn setup_binsh(prefix: &str, sh_binary: impl AsRef<Path>) -> Result<()> {
    let usrbin_path = PathBuf::from(prefix).join("usr/bin");
    atomic_symlink(&sh_binary, usrbin_path.join("sh"))
}

/// Remove `/bin/sh`.
///
/// The symlink lives in `/usr/bin`. A `sh` left in an old `/bin` directory is removed when
/// `setup_bin_symlink` migrates it.
fn remove_binsh(prefix: &str) -> Result<()> {
    remove_if_exists(&PathBuf::from(prefix).join("usr/bin/sh"))
}

fn remove_if_exists(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e).with_context(|| format!("Failed to remove {}", path.display())),
    }
}

/// Make `/bin` a symlink to `usr/bin`.
///
/// Older generations created `/bin` as a directory that only contains `sh`. Atomically exchange it
/// with the symlink so that `/bin/sh` never disappears.
fn setup_bin_symlink(prefix: &str) -> Result<()> {
    let bin_path = PathBuf::from(prefix).join("bin");

    if bin_path.is_symlink() || !bin_path.is_dir() {
        return atomic_symlink("usr/bin", bin_path);
    }

    let tmp_path = PathBuf::from(prefix).join(".bin.tmp");
    std::os::unix::fs::symlink("usr/bin", &tmp_path)
        .with_context(|| format!("Failed to create {}", tmp_path.display()))?;
    Root::open(prefix)
        .with_context(|| format!("Failed to open prefix {prefix}"))?
        .rename(".bin.tmp", "bin", RenameFlags::RENAME_EXCHANGE)
        .context("Failed to exchange /bin with a symlink")?;
    // /bin is already migrated at this point, so failing to clean up must not fail the boot.
    if let Err(err) = fs::remove_file(tmp_path.join("sh")).and_then(|()| fs::remove_dir(&tmp_path))
    {
        log::warn!("Failed to remove old /bin at {}: {err}", tmp_path.display());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    use tempfile::tempdir;

    const SH: &str = "/nix/store/xxx-bash/bin/sh";

    #[test]
    fn binsh_migrates_bin_dir() -> Result<()> {
        let prefix = tempdir()?;
        fs::create_dir(prefix.path().join("bin"))?;
        std::os::unix::fs::symlink(SH, prefix.path().join("bin/sh"))?;

        let prefix_str = prefix.path().to_str().unwrap();
        setup_usrbin(prefix_str)?;
        setup_binsh(prefix_str, SH)?;
        setup_bin_symlink(prefix_str)?;

        assert_eq!(
            fs::read_link(prefix.path().join("bin"))?,
            Path::new("usr/bin")
        );
        assert_eq!(
            fs::read_link(prefix.path().join("usr/bin/sh"))?,
            Path::new(SH)
        );
        assert!(!prefix.path().join(".bin.tmp").exists());
        Ok(())
    }

    #[test]
    fn usrbin_keeps_existing_mode() -> Result<()> {
        let prefix = tempdir()?;
        let usrbin = prefix.path().join("usr/bin");
        fs::create_dir_all(&usrbin)?;
        fs::set_permissions(&usrbin, fs::Permissions::from_mode(0o700))?;

        setup_usrbin(prefix.path().to_str().unwrap())?;

        assert_eq!(fs::metadata(&usrbin)?.permissions().mode() & 0o777, 0o700);
        Ok(())
    }

    #[test]
    fn usrbin_created_with_mode() -> Result<()> {
        let prefix = tempdir()?;

        setup_usrbin(prefix.path().to_str().unwrap())?;

        let usrbin = prefix.path().join("usr/bin");
        assert_eq!(fs::metadata(&usrbin)?.permissions().mode() & 0o777, 0o755);
        Ok(())
    }

    #[test]
    fn remove_binsh_migrates_bin_dir() -> Result<()> {
        let prefix = tempdir()?;
        fs::create_dir(prefix.path().join("bin"))?;
        std::os::unix::fs::symlink(SH, prefix.path().join("bin/sh"))?;

        let prefix_str = prefix.path().to_str().unwrap();
        setup_usrbin(prefix_str)?;
        remove_binsh(prefix_str)?;
        setup_bin_symlink(prefix_str)?;

        assert_eq!(
            fs::read_link(prefix.path().join("bin"))?,
            Path::new("usr/bin")
        );
        assert!(!prefix.path().join("usr/bin/sh").exists());
        assert!(!prefix.path().join(".bin.tmp").exists());
        Ok(())
    }
}
