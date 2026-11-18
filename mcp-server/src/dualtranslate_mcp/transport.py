"""Transports: how the server reaches the device (design 10.4).

Every device operation is a dtctl JSON-RPC call: the command array travels on
stdin, so a book path with spaces or quotes never goes through shell splitting
or an SSH command string.  The read key is locked to a read-only command
whitelist by its forced command; the write key may run everything.  A transport
that cannot execute dtctl (a USB mount) raises HeadlessUnavailable, and the job
layer is a local directory instead.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path
from typing import Protocol

from .config import Config
from .models import validate_job


JOB_ID_RE = re.compile(r"^[0-9A-Za-z_-]+$")
CAT_NAMES = {"job.json", "state.json", "result.json", "result.partial.json"}
CM_FLAGS = {"context", "allow-partial"}
# list-providers opens the cache DB, and opening a v2 DB migrates it (a
# write), so that command needs the write key (design 10.3).
READ_COMMANDS = frozenset({"list-jobs", "job-status", "get-segments", "cat"})
# Commands that touch a whole book and must not be cut off by the short timeout.
LONG_COMMANDS = frozenset({"import", "extract"})


class TransportError(RuntimeError):
    """The device answered with an error or was unreachable."""


class HeadlessUnavailable(TransportError):
    """This transport cannot execute dtctl, so it cannot commit a job."""


class Transport(Protocol):
    def rpc(self, argv: list[str], stdin: bytes | None = None) -> dict: ...


def parse_command_options(argv: list[str]) -> dict:
    """Parse --key value / --flag the same way dtctl does."""
    options: dict = {}
    index = 1
    while index < len(argv):
        token = argv[index]
        if not token.startswith("--"):
            raise TransportError(f"unexpected argument: {token}")
        key = token[2:]
        if key in CM_FLAGS:
            options[key] = True
            index += 1
        else:
            if index + 1 >= len(argv):
                raise TransportError(f"missing value for --{key}")
            options[key] = argv[index + 1]
            index += 2
    return options


class LocalTransport:
    """A directory that looks like the device's data dir (tests, USB mount).

    Reads and writes work; ``dtctl`` raises HeadlessUnavailable, so a job can
    be inspected but never committed through this transport.
    """

    def __init__(self, ko_root: str, local_root: str):
        self.ko_root = ko_root.rstrip("/")
        self.root = Path(local_root).resolve()
        self.jobs_root = f"{self.ko_root}/cache/dualtranslate/mcp/jobs"

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

    def rpc(self, argv: list[str], stdin: bytes | None = None) -> dict:
        if not argv:
            raise TransportError("empty rpc command")
        command = argv[0]
        options = parse_command_options(argv)
        if command == "list-jobs":
            return {"ok": True, "jobs": self._list_jobs()}
        if command == "job-status":
            return self._job_status(options.get("job", ""))
        if command == "get-segments":
            return self._get_segments(options)
        if command == "cat":
            return self._cat(options)
        raise HeadlessUnavailable(f"local transport cannot run {command}")

    # -- device-side read commands, mirrored for USB mounts and tests --------

    def _job_bundle(self, job_path: str) -> tuple[dict, dict]:
        if not job_path.endswith("/job.json"):
            raise TransportError("--job must be mcp/jobs/<id>/job.json")
        directory = self._path(job_path).parent
        job = json.loads((directory / "job.json").read_text(encoding="utf-8"))
        validate_job(job)
        state: dict = {}
        state_path = directory / "state.json"
        if state_path.exists():
            try:
                state = json.loads(state_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                state = {}
        return job, state

    def _list_jobs(self) -> list[dict]:
        root = self._path(self.jobs_root)
        jobs: list[dict] = []
        if not root.is_dir():
            return jobs
        for entry in sorted(root.iterdir()):
            if not entry.is_dir() or not JOB_ID_RE.fullmatch(entry.name):
                continue
            try:
                job = json.loads((entry / "job.json").read_text(encoding="utf-8"))
                validate_job(job)
            except (OSError, ValueError, json.JSONDecodeError):
                continue
            state: dict = {}
            if (entry / "state.json").exists():
                try:
                    state = json.loads((entry / "state.json").read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    state = {}
            book = job.get("book", {})
            jobs.append(
                {
                    "job_id": entry.name,
                    "created_at": int(job.get("created_at") or 0),
                    "book_path": book.get("device_path"),
                    "title": book.get("title"),
                    "chapter_count": len(job.get("chapters", [])),
                    "total": len(job["segments"]),
                    "status": state.get("status", "exported"),
                    "provider_id": state.get("provider_id"),
                    "model_name": state.get("model_name"),
                    "submitted": int(state.get("submitted") or 0),
                    "updated_at": int(state.get("updated_at") or 0),
                }
            )
        jobs.sort(key=lambda item: (item["created_at"], item["job_id"]), reverse=True)
        return jobs

    def _job_status(self, job_path: str) -> dict:
        job, state = self._job_bundle(job_path)
        book = job.get("book", {})
        return {
            "ok": True,
            "job_id": job["job_id"],
            "book_path": book.get("device_path"),
            "title": book.get("title"),
            "source_lang": book.get("source_lang"),
            "target_lang": book.get("target_lang"),
            "spine_count": book.get("spine_count"),
            "file_size": book.get("file_size"),
            "file_mtime": book.get("file_mtime"),
            "total": len(job["segments"]),
            "chapter_count": len(job.get("chapters", [])),
            "segment_ids": [segment["id"] for segment in job["segments"]],
            "status": state.get("status", "exported"),
            "provider_id": state.get("provider_id"),
            "model_name": state.get("model_name"),
            "submitted": int(state.get("submitted") or 0),
        }

    def _get_segments(self, options: dict) -> dict:
        job, _ = self._job_bundle(options.get("job", ""))
        segments = job["segments"]
        offset = max(0, int(options.get("offset", 0)))
        limit = max(1, min(int(options.get("limit", 50)), 100))
        rows = []
        for index, segment in enumerate(segments[offset : offset + limit], start=offset):
            row = {
                "id": segment["id"],
                "parent_id": segment.get("parent_id", segment["id"]),
                "part": segment.get("part", 1),
                "parent_total": segment.get("parent_total", 1),
                "chapter_index": segment.get("chapter_index"),
                "chapter_title": segment.get("chapter_title"),
                "source": segment["source"],
            }
            if options.get("context"):
                row["prev"] = segments[index - 1]["source"][-200:] if index > 0 else None
                row["next"] = (
                    segments[index + 1]["source"][:200]
                    if index + 1 < len(segments) else None
                )
            rows.append(row)
        last = offset + len(rows)
        return {
            "ok": True,
            "job_id": job["job_id"],
            "total": len(segments),
            "next_offset": last if last < len(segments) else None,
            "segments": rows,
        }

    def _cat(self, options: dict) -> dict:
        name = options.get("name", "")
        if name not in CAT_NAMES:
            raise TransportError(f"unsupported file: {name}")
        path = self._path(options.get("job", "")).parent / name
        if not path.exists():
            return {"ok": True, "name": name, "exists": False}
        content = path.read_text(encoding="utf-8")
        return {
            "ok": True, "name": name, "exists": True,
            "bytes": len(content.encode("utf-8")), "content": content,
        }

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
    """OpenSSH based transport: every device call is a dtctl rpc over ssh.

    A key is mandatory.  Falling back to the default identity would silently
    use the unrestricted login key and defeat the read/write split (10.3).
    The read key is optional: without it, read commands go through the write
    key, which is still locked to dtctl by the forced command.
    """

    def __init__(self, config: Config):
        self.config = config
        if not shutil.which("ssh"):
            raise TransportError("ssh binary not found")
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

    def _control_path(self, read: bool) -> str:
        # %C hashes host/port/user only, so the prefix keeps the two key
        # identities on separate master connections.  The path plus ssh's
        # temporary suffix must fit in a Unix socket path (104 bytes), which
        # rules out the (longer) work_dir.
        base = Path.home() / ".dtmcp"
        base.mkdir(parents=True, exist_ok=True)
        return str(base / ("cm-ro-%C" if read else "cm-rw-%C"))

    def rpc(self, argv: list[str], stdin: bytes | None = None) -> dict:
        if not argv:
            raise TransportError("empty rpc command")
        read = argv[0] in READ_COMMANDS
        command = [
            "ssh", "-T", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", f"ConnectTimeout={self.config.timeout}",
            "-o", "ControlMaster=auto",
            "-o", f"ControlPath={self._control_path(read)}",
            "-o", "ControlPersist=300",
            "-p", str(self.config.port),
        ] + self._key_args(read=read)
        command += [f"{self.config.user}@{self.config.host}", "rpc"]
        envelope: dict = {"argv": [str(value) for value in argv]}
        if stdin is not None:
            try:
                envelope["stdin"] = stdin.decode("utf-8")
            except UnicodeDecodeError as error:
                raise TransportError("stdin is not valid UTF-8") from error
        payload = json.dumps(envelope, ensure_ascii=False).encode("utf-8")
        timeout = self.config.long_timeout if argv[0] in LONG_COMMANDS else None
        result = self._run(command, payload, timeout)
        return _parse_dtctl_reply(result)

    def _run(self, command: list[str], input_bytes: bytes | None = None,
             timeout: int | None = None):
        limit = timeout or self.config.timeout
        try:
            return subprocess.run(
                command, input=input_bytes, capture_output=True, timeout=limit,
            )
        except subprocess.TimeoutExpired as error:
            raise TransportError(
                f"ssh command timed out after {limit}s; the device may still be "
                "writing — check dt_list_providers before retrying"
            ) from error

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
