"""Transport tests: path rebasing, chroot enforcement and sftp batch safety."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from dualtranslate_mcp.config import Config
from dualtranslate_mcp.transport import (
    HeadlessUnavailable,
    LocalTransport,
    SshTransport,
    TransportError,
)

KO_ROOT = "/mnt/us/koreader"
JOBS = f"{KO_ROOT}/cache/dualtranslate/mcp/jobs"


def make_config(tmp_path: Path, **overrides) -> Config:
    values = {
        "transport": "local",
        "ko_root": KO_ROOT,
        "local_root": str(tmp_path / "device"),
        "work_dir": tmp_path / "work",
    }
    values.update(overrides)
    return Config(**values)


def test_local_transport_rebases_device_paths(tmp_path: Path) -> None:
    device = tmp_path / "device"
    job_dir = device / "cache/dualtranslate/mcp/jobs/2026_1"
    job_dir.mkdir(parents=True)
    (job_dir / "job.json").write_text(json.dumps({"schema": "x"}), encoding="utf-8")
    transport = LocalTransport(KO_ROOT, str(device))
    assert json.loads(transport.read_text(f"{JOBS}/2026_1/job.json")) == {"schema": "x"}
    assert transport.list_dir(JOBS) == ["2026_1"]


def test_local_transport_refuses_paths_outside_root(tmp_path: Path) -> None:
    transport = LocalTransport(KO_ROOT, str(tmp_path / "device"))
    with pytest.raises(TransportError):
        transport.read_text("/etc/passwd")
    with pytest.raises(TransportError):
        # ".." must not climb out even when the prefix matches.
        transport.read_text(f"{KO_ROOT}/../../etc/passwd")


def test_local_transport_cannot_run_dtctl(tmp_path: Path) -> None:
    transport = LocalTransport(KO_ROOT, str(tmp_path / "device"))
    with pytest.raises(HeadlessUnavailable):
        transport.dtctl(["list-jobs"])


def test_chroot_path_maps_and_rejects(tmp_path: Path) -> None:
    transport = SshTransport(make_config(tmp_path, transport="ssh"))
    assert transport._chroot_path(JOBS) == "."
    assert transport._chroot_path(f"{JOBS}/abc/job.json") == "abc/job.json"
    with pytest.raises(TransportError):
        transport._chroot_path("/etc/passwd")
    with pytest.raises(TransportError):
        transport._chroot_path(f"{KO_ROOT}/cache/dualtranslate/books/x/manifest.json")


def test_sftp_batch_rejects_unsafe_paths(tmp_path: Path) -> None:
    transport = SshTransport(make_config(tmp_path, transport="ssh"))
    assert transport._sftp_path(f"{JOBS}/abc/job.json") == "abc/job.json"
    for unsafe in ("a b", "a\tb", 'a"b', "a'b", "a\\b"):
        with pytest.raises(TransportError):
            transport._sftp_path(f"{JOBS}/{unsafe}/job.json")


def test_ssh_read_text_checks_before_spawning_sftp(tmp_path: Path) -> None:
    transport = SshTransport(make_config(tmp_path, transport="ssh"))
    # No sftp process is spawned for a path outside the chroot.
    with pytest.raises(TransportError):
        transport.read_text("/etc/passwd")
