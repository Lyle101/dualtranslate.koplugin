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


def parse_sftp_ls(output: str) -> list[str]:
    """Parse the stdout of `sftp -b -`.

    The batch is echoed with a "sftp> " prompt and `ls -1 <absolute>` prints
    absolute paths, so both the echo and the directory part must be stripped.
    """
    names = []
    for line in output.splitlines():
        line = line.strip()
        if not line or line.startswith("sftp>"):
            continue
        name = line.rstrip("/").rsplit("/", 1)[-1]
        if name and name not in (".", ".."):
            names.append(name)
    return sorted(set(names))


class SshTransport:
    """OpenSSH based transport: SFTP for reads, dtctl for writes.

    A key is mandatory.  Falling back to the default identity would silently
    use the unrestricted login key and defeat the read/write split (10.3).
    The read key is optional: without it, read commands go through the write
    key, which is still locked to dtctl by the forced command.
    """

    def __init__(self, config: Config):
        self.config = config
        if not shutil.which("ssh") or not shutil.which("sftp"):
            raise TransportError("ssh/sftp binaries not found")
        if not config.write_key:
            raise TransportError("device.write_key is not configured")
        self.write_key_path = Path(config.write_key).expanduser()
        if not self.write_key_path.exists():
            raise TransportError(f"write key not found: {self.write_key_path}")
        if config.read_key:
            self.read_key_path = Path(config.read_key).expanduser()
            if not self.read_key_path.exists():
                raise TransportError(f"read key not found: {self.read_key_path}")
        else:
            self.read_key_path = self.write_key_path

    def _key_args(self, read: bool) -> list[str]:
        return ["-i", str(self.read_key_path if read else self.write_key_path)]

    def _run(self, command: list[str], input_bytes: bytes | None = None):
        try:
            return subprocess.run(
                command, input=input_bytes, capture_output=True,
                timeout=self.config.timeout,
            )
        except subprocess.TimeoutExpired as error:
            raise TransportError(
                f"ssh command timed out after {self.config.timeout}s"
            ) from error

    def _chroot_path(self, remote_path: str) -> str:
        # The read key is not chrooted on the device (the filesystem is a
        # world-writable FUSE mount, so ChrootDirectory is impossible), but the
        # server still only ever asks for paths below mcp/jobs.
        if not remote_path.startswith(self.config.ko_root):
            raise TransportError(
                f"path outside the koreader root: {remote_path}"
            )
        root = self.config.jobs_root.rstrip("/")
        if remote_path == root:
            return "."
        if remote_path.startswith(root + "/"):
            return remote_path[len(root) + 1:]
        raise TransportError(
            f"path outside the job directory ({root}): {remote_path}"
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

    def _sftp(self, batch: str) -> str:
        command = ["sftp", "-q", "-b", "-"] + self._key_args(read=True)
        command += ["-P", str(self.config.port),
                    f"{self.config.user}@{self.config.host}"]
        result = self._run(command, batch.encode())
        if result.returncode != 0:
            raise TransportError(
                f"sftp failed: {result.stderr.decode(errors='replace').strip()}"
            )
        return result.stdout.decode(errors="replace")

    def read_text(self, remote_path: str) -> str:
        remote_path = self._sftp_path(remote_path)
        with tempfile.NamedTemporaryFile(delete=False) as handle:
            local = handle.name
        try:
            self._sftp(f"get {remote_path} {local}\n")
            return Path(local).read_text(encoding="utf-8")
        finally:
            Path(local).unlink(missing_ok=True)

    def list_dir(self, remote_path: str) -> list[str]:
        output = self._sftp(f"ls -1 {self._sftp_path(remote_path)}\n")
        return parse_sftp_ls(output)

    def write_inbox(self, job_id: str, payload: bytes) -> str:
        device_path = f"{self.config.inbox_root}/{job_id}.json"
        reply = self.dtctl(
            ["put", "--job", f"{self.config.jobs_root}/{job_id}/job.json", "--inbox"],
            stdin=payload,
        )
        # dtctl answers with the path it actually wrote; fall back only when an
        # older device build omits it.
        return reply.get("path") or device_path

    def dtctl(self, argv: list[str], stdin: bytes | None = None) -> dict:
        command = [
            "ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", f"ConnectTimeout={self.config.timeout}",
            "-p", str(self.config.port),
        ] + self._key_args(read=False)
        command += [f"{self.config.user}@{self.config.host}"] + list(argv)
        result = self._run(command, stdin)
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
