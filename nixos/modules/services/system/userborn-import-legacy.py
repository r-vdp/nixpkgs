#!@python3@
"""One-shot migration from update-users-groups.pl state in /var/lib/nixos to
the on-disk databases that userborn treats as authoritative.

userborn never deletes entries from /etc/{passwd,group,shadow}; it only locks
accounts and drains group members. That makes /etc/passwd itself the uid-map.
To migrate safely we therefore need to make /etc/passwd a superset of what
/var/lib/nixos/uid-map remembers: every name that ever had a dynamically
allocated id gets a locked stub entry, so the id can neither be reassigned to
a different name nor lost if the name is later re-added.

This script is intended to run exactly once, gated by ConditionPathExists in
the unit. It is deliberately small and will be removed once the perl
implementation is gone.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

LEGACY = Path("/var/lib/nixos")
USERBORN_STATE = Path("/var/lib/userborn")
SENTINEL = USERBORN_STATE / ".legacy-imported"
PREVIOUS = USERBORN_STATE / "previous-userborn.json"


def log(level: int, msg: str) -> None:
    # Kernel printk numeric prefix so journald picks up the level.
    print(f"<{level}>userborn-import-legacy: {msg}", file=sys.stderr)


def info(msg: str) -> None:
    log(6, msg)


def warn(msg: str) -> None:
    log(4, msg)


def try_load_json(path: Path) -> dict[str, int]:
    try:
        data: dict[str, int] = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    return data


def load_colon_db(path: Path) -> tuple[set[str], dict[int, str]]:
    """Return (names, id->name) from a passwd/group style file."""
    names: set[str] = set()
    by_id: dict[int, str] = {}
    try:
        text = path.read_text()
    except FileNotFoundError:
        return names, by_id
    for line in text.splitlines():
        fields = line.split(":")
        if len(fields) < 3 or not fields[0]:
            continue
        names.add(fields[0])
        try:
            by_id[int(fields[2])] = fields[0]
        except ValueError:
            pass
    return names, by_id


def append_lines(path: Path, lines: list[str], mode: int = 0o644) -> None:
    if not lines:
        return
    new = not path.exists()
    with path.open("a") as f:
        f.write("".join(lines))
    if new:
        path.chmod(mode)


def import_ids(directory: Path) -> None:
    passwd = directory / "passwd"
    group = directory / "group"
    shadow = directory / "shadow"

    passwd.touch()
    group.touch()
    if not shadow.exists():
        shadow.touch()
        shadow.chmod(0o640)

    user_names, user_ids = load_colon_db(passwd)
    group_names, group_ids = load_colon_db(group)

    gid_map = try_load_json(LEGACY / "gid-map")
    uid_map = try_load_json(LEGACY / "uid-map")

    new_group: list[str] = []
    for name, gid in sorted(gid_map.items()):
        if name in group_names:
            continue
        owner = group_ids.get(gid)
        if owner is not None:
            warn(
                f"gid {gid} from gid-map for {name!r} is already used by "
                f"{owner!r}; skipping"
            )
            continue
        info(f"reserving gid {gid} for removed group {name!r}")
        new_group.append(f"{name}:x:{gid}:\n")
        group_names.add(name)
        group_ids[gid] = name
    append_lines(group, new_group)

    new_passwd: list[str] = []
    new_shadow: list[str] = []
    for name, uid in sorted(uid_map.items()):
        if name in user_names:
            continue
        owner = user_ids.get(uid)
        if owner is not None:
            warn(
                f"uid {uid} from uid-map for {name!r} is already used by "
                f"{owner!r}; skipping"
            )
            continue
        # Prefer the gid recorded for the same name, falling back to nogroup.
        gid = gid_map.get(name, 65534)
        info(f"reserving uid {uid} for removed user {name!r}")
        new_passwd.append(
            f"{name}:x:{uid}:{gid}::/var/empty:/run/current-system/sw/bin/nologin\n"
        )
        new_shadow.append(f"{name}:!*:1::::::\n")
        user_names.add(name)
        user_ids[uid] = name
    append_lines(passwd, new_passwd)
    append_lines(shadow, new_shadow, mode=0o640)


def synthesise_previous_config() -> None:
    """Populate previous-userborn.json from declarative-{users,groups} so
    userborn's first run knows which entries were declarative under perl."""
    if PREVIOUS.exists():
        return

    def names(path: Path) -> list[dict[str, str]]:
        try:
            text = path.read_text()
        except FileNotFoundError:
            return []
        return [{"name": n} for n in text.split() if n]

    PREVIOUS.write_text(
        json.dumps(
            {
                "users": names(LEGACY / "declarative-users"),
                "groups": names(LEGACY / "declarative-groups"),
            }
        )
    )
    info(f"synthesised {PREVIOUS} from declarative-users/groups")


def seed_subids(directory: Path) -> None:
    """Seed /etc/sub{u,g}id from the perl auto-subuid-map so that nixos-subids
    preserves existing allocations. nixos-subids treats existing entries as
    authoritative and never shrinks the file."""
    auto = try_load_json(LEGACY / "auto-subuid-map")
    if not auto:
        return
    for fname in ("subuid", "subgid"):
        path = directory / fname
        seen, _ = load_colon_db(path)
        new = [
            f"{name}:{start}:65536\n"
            for name, start in sorted(auto.items())
            if name not in seen
        ]
        append_lines(path, new)


def main() -> None:
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else "/etc")
    directory.mkdir(parents=True, exist_ok=True)
    USERBORN_STATE.mkdir(parents=True, exist_ok=True)

    import_ids(directory)
    synthesise_previous_config()
    seed_subids(directory)

    SENTINEL.touch()


if __name__ == "__main__":
    main()
