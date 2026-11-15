"""Transports: how the server reaches the device (design 10.4).

Reads go through the read-only key's SFTP chroot; every write (file upload,
import, delete, display switch) goes through the write key's dtctl forced
command.  A transport that cannot execute dtctl (a USB mount) raises
HeadlessUnavailable, and the job layer falls back to the inbox.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Protocol

from .config import Config


class TransportError(RuntimeError):
    """The device answered with an error or was unreachable."""


class HeadlessUnavailable(TransportError):
    """This transport cannot execute dtctl; callers must use the inbox."""


class Transport(Protocol):
    def read_text(self, remote_path: str) -> str: ...

    def list_dir(self, remote_path: str) -> list[str]: ...

    def dtctl(self, argv: list[str], stdin: bytes | None = None) -> dict: ...

    def write_inbox(self, job_id: str, payload: bytes) -> str: ...


class LocalTransport:
    """A directory that looks like the device's data dir (tests, USB mount).

    Reads and writes work; ``dtctl`` raises HeadlessUnavailable, which is
    exactly the USB case the inbox fallback exists for.
    """

    def __init__(self, ko_root: str, local_root: str):
        self.ko_root = ko_root.rstrip("/")
        self.root = Path(local_root).resolve()

    def _path(self, remote_path: str) -> Path:
        # Device-absolute paths are rebased under local_root: the caller can use
        # the same /mnt/us/koreader/... string for a real device and a mount.
        if not remote_path.startswith(self.ko_root):
            raise TransportError(f"path outside the koreader root: {remote_path}")
        suffix = remote_path[len(self.ko_root):].lstrip("/")
        candidate = (self.root / suffix).resolve()
        if not str(candidate).startswith(str(self.root)):
            raise TransportError(f"path escapes the device root: {remote_path}")
        return candidate

    def read_text(self, remote_path: str) -> str:
        return self._path(remote_path).read_text(encoding="utf-8")

    def list_dir(self, remote_path: str) -> list[str]:
        path = self._path(remote_path)
        if not path.is_dir():
            return []
        return sorted(entry.name for entry in path.iterdir())

    def dtctl(self, argv: list[str], stdin: bytes | None = None) -> dict:
        raise HeadlessUnavailable("local transport cannot run dtctl")

    def write_inbox(self, job_id: str, payload: bytes) -> str:
        device_path = f"{self.ko_root}/cache/dualtranslate/mcp/inbox/{job_id}.json"
        path = self._path(device_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        return device_path


class SshTransport:
    """OpenSSH based transport: SFTP for reads, dtctl for writes.

    Uses the system ssh/sftp binaries so keys, known_hosts and agent
    configuration stay under the user's control.  Host key checking is always
    on (design 10.3 forbids StrictHostKeyChecking=no).
    """

    def __init__(self, config: Config):
        self.config = config
        if not shutil.which("ssh") or not shutil.which("sftp"):
            raise TransportError("ssh/sftp binaries not found")

    def _read_key(self) -> list[str]:
        if not self.config.read_key:
            return []
        return ["-i", str(Path(self.config.read_key).expanduser())]

    def _write_key(self) -> list[str]:
        if not self.config.write_key:
            return []
        return ["-i", str(Path(self.config.write_key).expanduser())]

    def _chroot_path(self, remote_path: str) -> str:
        # The read key is chrooted to mcp/jobs (10.3): device-absolute paths
        # must be made relative before sftp can see them.  Anything outside the
        # chroot is a bug, not something to silently rewrite.
        root = self.config.jobs_root.rstrip("/")
        if remote_path == root:
            return "."
        if remote_path.startswith(root + "/"):
            return remote_path[len(root) + 1:]
        raise TransportError(
            f"path outside the read-only chroot ({root}): {remote_path}"
        )

    # sftp -b is not a shell: quoting rules differ and a newline starts a new
    # command.  Only paths the server itself constructed may go into a batch.
    SFTP_UNSAFE = re.compile(r"""[\s"'\\]""")

    def _sftp_path(self, remote_path: str) -> str:
        relative = self._chroot_path(remote_path)
        if self.SFTP_UNSAFE.search(relative):
            raise TransportError(
                f"path is not safe for an sftp batch command: {relative}"
            )
        return relative

    def read_text(self, remote_path: str) -> str:
        remote_path = self._sftp_path(remote_path)
        with tempfile.NamedTemporaryFile(delete=False) as handle:
            local = handle.name
        try:
            batch = f"get {remote_path} {local}\n"
            command = ["sftp", "-q", "-b", "-"] + self._read_key()
            command += ["-P", str(self.config.port), f"{self.config.user}@{self.config.host}"]
            result = subprocess.run(command, input=batch.encode(), capture_output=True)
            if result.returncode != 0:
                raise TransportError(
                    f"sftp read failed: {result.stderr.decode(errors='replace').strip()}"
                )
            return Path(local).read_text(encoding="utf-8")
        finally:
            Path(local).unlink(missing_ok=True)

    def list_dir(self, remote_path: str) -> list[str]:
        command = ["sftp", "-q", "-b", "-"] + self._read_key()
        command += ["-P", str(self.config.port), f"{self.config.user}@{self.config.host}"]
        batch = f"ls -1 {self._sftp_path(remote_path)}\n"
        result = subprocess.run(command, input=batch.encode(), capture_output=True)
        if result.returncode != 0:
            raise TransportError(
                f"sftp list failed: {result.stderr.decode(errors='replace').strip()}"
            )
        names = []
        for line in result.stdout.decode(errors="replace").splitlines():
            name = line.strip()
            if name and name not in (".", ".."):
                names.append(name)
        return sorted(names)

    def write_inbox(self, job_id: str, payload: bytes) -> str:
        device_path = f"{self.config.inbox_root}/{job_id}.json"
        self.dtctl(
            ["put", "--job", f"{self.config.jobs_root}/{job_id}/job.json", "--inbox"],
            stdin=payload,
        )
        return device_path

    def dtctl(self, argv: list[str], stdin: bytes | None = None) -> dict:
        command = [
            "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-p", str(self.config.port),
        ] + self._write_key()
        command += [f"{self.config.user}@{self.config.host}"] + list(argv)
        result = subprocess.run(command, input=stdin, capture_output=True)
        return _parse_dtctl_reply(result)


def _parse_dtctl_reply(result: subprocess.CompletedProcess) -> dict:
    stdout = result.stdout.decode(errors="replace").strip()
    line = stdout.splitlines()[-1] if stdout.splitlines() else ""
    payload: dict = {}
    if line:
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            payload = {}
    if not payload:
        message = result.stderr.decode(errors="replace").strip() or "empty reply from dtctl"
        raise TransportError(f"dtctl failed (exit {result.returncode}): {message}")
    if result.returncode != 0 or payload.get("ok") is False:
        raise TransportError(
            f"{payload.get('code', 'DTCTL_ERROR')}: {payload.get('message', 'unknown error')}"
        )
    return payload


def build_transport(config: Config) -> Transport:
    if config.transport == "local":
        if not config.local_root:
            raise TransportError("local transport requires device.local_root")
        return LocalTransport(config.ko_root, config.local_root)
    return SshTransport(config)
