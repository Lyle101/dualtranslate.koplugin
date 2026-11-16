"""Configuration for the DualTranslate MCP server (design 10.3).

Values come from a TOML file and are then overridden by environment
variables, so a stdio client can be configured with env only::

    DT_TRANSPORT=ssh DT_SSH_HOST=kindle DT_READ_KEY=~/.ssh/dt_ro ...

The two SSH keys are deliberately separate.  The read key is restricted to a
read-only SFTP chroot over mcp/jobs; the write key is locked to dtctl.sh and
cannot open an SFTP subsystem (10.3).
"""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path


DEFAULT_KO_ROOT = "/mnt/us/koreader"
JOBS_SUBDIR = "/cache/dualtranslate/mcp/jobs"


def _config_path() -> Path:
    explicit = os.environ.get("DT_CONFIG")
    if explicit:
        return Path(explicit).expanduser()
    base = os.environ.get("XDG_CONFIG_HOME") or "~/.config"
    return Path(base).expanduser() / "dualtranslate-mcp" / "config.toml"


def _default_work_dir() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or "~/.cache"
    return Path(base).expanduser() / "dualtranslate-mcp"


@dataclass
class Config:
    transport: str = "ssh"
    host: str = "kindle"
    user: str = "root"
    port: int = 22
    read_key: str | None = None
    write_key: str | None = None
    ko_root: str = DEFAULT_KO_ROOT
    local_root: str | None = None
    work_dir: Path = field(default_factory=_default_work_dir)
    max_segments_per_call: int = 100
    max_chars_per_segment: int = 20_000
    timeout: int = 30
    # import/extract write or parse a whole book; 16k segments took ~2 min on a
    # Voyage, so a 30 s timeout would report failure while the device kept
    # working (and a retry then collides with the book lock).
    long_timeout: int = 300

    def __post_init__(self) -> None:
        self.work_dir = Path(self.work_dir)

    @property
    def jobs_root(self) -> str:
        # Device-absolute path.  LocalTransport maps it onto local_root, so the
        # same job path works for a mounted Kindle and a test directory.
        return f"{self.ko_root}{JOBS_SUBDIR}"

    @property
    def inbox_root(self) -> str:
        return self.jobs_root.rsplit("/", 1)[0] + "/inbox"

    @classmethod
    def load(cls) -> "Config":
        config = cls()
        path = _config_path()
        if path.exists():
            with path.open("rb") as handle:
                document = tomllib.load(handle)
            device = document.get("device", {})
            config.transport = device.get("transport", config.transport)
            config.host = device.get("host", config.host)
            config.user = device.get("user", config.user)
            config.port = int(device.get("port", config.port))
            config.read_key = device.get("read_key", config.read_key)
            config.write_key = device.get("write_key", config.write_key)
            config.ko_root = device.get("koreader_root", config.ko_root)
            config.local_root = device.get("local_root", config.local_root)
            config.timeout = int(device.get("timeout", config.timeout))
            config.long_timeout = int(device.get("long_timeout", config.long_timeout))
            if device.get("work_dir"):
                config.work_dir = Path(device["work_dir"]).expanduser()

        env = os.environ
        config.transport = env.get("DT_TRANSPORT", config.transport)
        config.host = env.get("DT_SSH_HOST", config.host)
        config.user = env.get("DT_SSH_USER", config.user)
        if env.get("DT_SSH_PORT"):
            config.port = int(env["DT_SSH_PORT"])
        config.read_key = env.get("DT_READ_KEY", config.read_key)
        config.write_key = env.get("DT_WRITE_KEY", config.write_key)
        config.ko_root = env.get("DT_KO_ROOT", config.ko_root)
        config.local_root = env.get("DT_LOCAL_ROOT", config.local_root)
        if env.get("DT_WORK_DIR"):
            config.work_dir = Path(env["DT_WORK_DIR"]).expanduser()
        if env.get("DT_TIMEOUT"):
            config.timeout = int(env["DT_TIMEOUT"])
        if env.get("DT_LONG_TIMEOUT"):
            config.long_timeout = int(env["DT_LONG_TIMEOUT"])
        config.work_dir.mkdir(parents=True, exist_ok=True)
        return config
