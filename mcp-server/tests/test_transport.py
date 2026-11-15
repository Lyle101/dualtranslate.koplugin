"""Transport tests: path rebasing, sftp parsing, key policy and timeouts."""

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
    parse_sftp_ls,
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


def make_ssh(tmp_path: Path, **overrides) -> SshTransport:
    key = tmp_path / "id_test"
    key.write_text("dummy", encoding="utf-8")
    values = {"transport": "ssh", "write_key": str(key)}
    values.update(overrides)
    return SshTransport(make_config(tmp_path, **values))


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


def test_parse_sftp_ls_strips_prompt_and_absolute_paths() -> None:
    # Captured from the device: sftp echoes the batch and `ls -1 <abs>` prints
    # absolute paths, which used to survive valid_job_id and yield [].
    output = (
        "sftp> ls -1 /mnt/us/koreader/cache/dualtranslate/mcp/jobs\n"
        "/mnt/us/koreader/cache/dualtranslate/mcp/jobs/20261116_031914_6988\n"
        "\n"
    )
    assert parse_sftp_ls(output) == ["20261116_031914_6988"]


def test_chroot_path_maps_and_rejects(tmp_path: Path) -> None:
    transport = make_ssh(tmp_path)
    assert transport._chroot_path(JOBS) == "."
    assert transport._chroot_path(f"{JOBS}/abc/job.json") == "abc/job.json"
    with pytest.raises(TransportError):
        transport._chroot_path("/etc/passwd")
    with pytest.raises(TransportError):
        transport._chroot_path(f"{KO_ROOT}/cache/dualtranslate/books/x/manifest.json")


def test_sftp_batch_rejects_unsafe_paths(tmp_path: Path) -> None:
    transport = make_ssh(tmp_path)
    assert transport._sftp_path(f"{JOBS}/abc/job.json") == "abc/job.json"
    for unsafe in ("a b", "a\tb", 'a"b', "a'b", "a\\b"):
        with pytest.raises(TransportError):
            transport._sftp_path(f"{JOBS}/{unsafe}/job.json")


def test_ssh_read_text_checks_before_spawning_sftp(tmp_path: Path) -> None:
    transport = make_ssh(tmp_path)
    with pytest.raises(TransportError):
        transport.read_text("/etc/passwd")


def test_ssh_requires_write_key(tmp_path: Path) -> None:
    with pytest.raises(TransportError):
        SshTransport(make_config(tmp_path, transport="ssh"))
    with pytest.raises(TransportError):
        SshTransport(make_config(tmp_path, transport="ssh",
                                 write_key=str(tmp_path / "missing")))


def test_ssh_read_key_is_optional(tmp_path: Path) -> None:
    transport = make_ssh(tmp_path)
    # Without a read key, reads use the write key (still dtctl-locked).
    assert transport.read_key_path == transport.write_key_path
