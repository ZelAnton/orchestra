"""Frozen review bytes without extra source/build inputs in the consumer tree."""

import json
import math
import os
from pathlib import Path
import time
import uuid
import zipfile

from cycle_state import Blocked, atomic_write, digest, encode


def logical_path(name):
    if (not isinstance(name, str) or not name or "\\" in name or ":" in name
            or Path(name).is_absolute() or any(p in (".", "..") for p in name.split("/"))
            or "" in name.split("/")):
        raise ValueError("Invalid frozen source path")
    return name


def safe_path(path):
    path = Path(path)
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError("Frozen source storage must not follow symlinks")
    return path


def archive_path(root):
    return safe_path(Path(root).parent / "source.zip")


class open_archive:
    """One open snapshot archive for several reads. It opens the archive at the first read that needs it."""
    def __init__(self, root):
        self.root, self.archive = Path(root), None

    def read(self, name):
        if self.archive is None:
            self.archive = zipfile.ZipFile(archive_path(self.root))
        return self.archive.read(name)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        if self.archive is not None:
            self.archive.close()


def read_source(view, name, archive=None):
    """The verified bytes of one frozen file. ARCHIVE is an open_archive for several reads."""
    name = logical_path(name)
    expected = view["files"][name]
    root = safe_path(Path(view["root"]))
    source = safe_path(root / name)
    if source.exists():
        data = source.read_bytes()
    else:
        try:
            if archive is not None:
                data = archive.read(name)
            else:
                with zipfile.ZipFile(archive_path(root)) as opened:
                    data = opened.read(name)
        except (zipfile.BadZipFile, KeyError, RuntimeError, OSError) as error:
            raise ValueError("Frozen input archive cannot be read: " + name) from error
    if digest(data) != expected:
        raise ValueError("Frozen input changed: " + name)
    return data


class SnapshotWriter:
    def __init__(self, root):
        self.root = safe_path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.path = archive_path(root)
        self.temporary = self.path.with_name(".source-" + uuid.uuid4().hex + ".tmp")
        self.archive = zipfile.ZipFile(self.temporary, "x", compression=zipfile.ZIP_DEFLATED)
        self.files = {}

    def write(self, name, data):
        name = logical_path(name)
        if name in self.files:
            raise ValueError("Duplicate frozen source path")
        self.archive.writestr(name, data)
        self.files[name] = digest(data)

    def finish(self):
        self.archive.close()
        validate_archive(self.temporary, self.files)
        # The only replacement is our unsealed new view or a migration archive
        # whose absence was checked by the caller. Existing sealed views are read.
        safe_path(self.path)
        with self.temporary.open("r+b") as stream:
            os.fsync(stream.fileno())
        os.replace(self.temporary, self.path)
        if os.name != "nt":
            directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)

    def close(self):
        self.archive.close()
        self.temporary.unlink(missing_ok=True)


def validate_archive(path, files):
    with zipfile.ZipFile(safe_path(path)) as archive:
        names = archive.namelist()
        if len(names) != len(files) or set(names) != set(files):
            raise ValueError("Snapshot archive entries do not match its manifest")
        for name, expected in files.items():
            logical_path(name)
            if digest(archive.read(name)) != expected:
                raise ValueError("Snapshot archive content changed: " + name)


def compact_legacy_views(store, heartbeat):
    """Lease-owned maintenance, never called by status or provider inspection.

    Keep every sealed manifest unchanged. Persist a verified archive and receipt
    before retiring the redundant loose copies. An interrupted retirement resumes
    from the archive; unknown files, drift or symlinks block without discarding them.
    """
    try:
        return _compact_legacy_views(store, heartbeat)
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        raise Blocked("snapshot-storage", "Cannot safely archive frozen review inputs: " + str(error)) from error


def _compact_legacy_views(store, heartbeat):
    receipts = []
    directory = safe_path(store.directory / "pair-reviews")
    for root in directory.glob("*/*/view-*/source"):
        safe_path(root)
        if not (root.parent / "view.json").exists() and any(root.rglob("*")):
            raise Blocked("snapshot-storage", "Unsealed legacy source copies need recovery; preserved: " + str(root))
    for path in sorted(directory.glob("*/*/view-*/view.json")):
        heartbeat()
        try:
            safe_path(path)
            data = path.read_bytes()
            view = json.loads(data)
            root = safe_path(path.parent / "source")
            if Path(view["root"]).absolute() != root.absolute():
                raise ValueError("Frozen view root differs from its runtime-owned location")
            if view.get("storage") == "zip":
                validate_archive(archive_path(root), view["files"])
                if any(root.rglob("*")):
                    raise ValueError("Unexpected loose inputs beside an archived snapshot")
                continue
            if view.get("storage") is not None:
                raise ValueError("Unknown snapshot storage format")
            files = view["files"]
            for name in files:
                logical_path(name)
            loose = []
            for entry in root.rglob("*"):
                safe_path(entry)
                if entry.is_file():
                    name = entry.relative_to(root).as_posix()
                    if name not in files or digest(entry.read_bytes()) != files[name]:
                        raise ValueError("Unexpected or changed loose review input: " + name)
                    loose.append(entry)
                elif not entry.is_dir():
                    raise ValueError("Unexpected entry in frozen source storage")
            archive = archive_path(root)
            if not archive.exists():
                if {p.relative_to(root).as_posix() for p in loose} != set(files):
                    raise ValueError("Incomplete legacy snapshot; preserve it for recovery")
                writer = SnapshotWriter(root)
                try:
                    for entry in loose:
                        writer.write(entry.relative_to(root).as_posix(), entry.read_bytes())
                    if writer.files != files:
                        raise ValueError("Legacy snapshot changed while archiving")
                    writer.finish()
                finally:
                    writer.close()
            validate_archive(archive, files)
            receipt_path = safe_path(path.parent / "source-archive.json")
            identity = {"manifest": digest(data), "archive": digest(archive.read_bytes()), "files": len(files)}
            if receipt_path.exists():
                receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                if (set(receipt) != set(identity) | {"at"}
                        or any(receipt.get(k) != v for k, v in identity.items())
                        or type(receipt["at"]) not in (int, float)
                        or not math.isfinite(receipt["at"]) or receipt["at"] <= 0):
                    raise ValueError("Legacy snapshot archive receipt changed")
            else:
                receipt = dict(identity, at=time.time())
                atomic_write(receipt_path, encode(receipt))
            for entry in loose:
                heartbeat()
                name = entry.relative_to(root).as_posix()
                safe_path(entry)
                if digest(entry.read_bytes()) != files[name]:
                    raise ValueError("Loose input changed before retirement: " + name)
                entry.unlink()
            # Preserve root as the provider's cwd, including existing sessions.
            root.mkdir(parents=True, exist_ok=True)
            for entry in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
                safe_path(entry)
                if entry.is_dir():
                    entry.rmdir()  # Nonempty/unexpected entries fail closed.
            if any(root.iterdir()):
                raise ValueError("Unexpected inputs appeared during snapshot archival")
            receipts.append({"path": receipt_path.relative_to(store.directory).as_posix(), **receipt})
        except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
            raise Blocked("snapshot-storage", "Cannot safely archive frozen review inputs: " + str(error)) from error
    return receipts
