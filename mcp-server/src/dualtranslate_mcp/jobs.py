"""Job orchestration: read jobs, collect translations, commit back (10.2/10.3).

All device access is a dtctl rpc call.  The server keeps only the merged
translations (a small working copy) and never downloads the whole job: the
device paginates segments and reports the id list, so a ten-thousand segment
book costs kilobytes per page instead of megabytes.

A transport that cannot execute dtctl (a USB mount) can inspect a job but
cannot commit it: the plugin has no device-side import any more.
"""

from __future__ import annotations

import functools
import json
import os
import re
import threading
from pathlib import Path

from .config import Config
from .models import (
    RESULT_SCHEMA,
    STATE_SCHEMA,
    ValidationError,
    build_result,
    provider_id_for,
    validate_translation_text,
    valid_job_id,
)
from .transport import HeadlessUnavailable, Transport, TransportError


# The local buffer before a model is confirmed.  It is adopted by the first
# confirmed provider; a provider_id cannot equal this because the device
# grammar only allows system / microsoft_free / mcp:<slug>.
PENDING_PROVIDER = "unconfirmed"
LEGACY_PARTIAL_NAME = "translations.json"


def _per_job_lock(method):
    """Serialize the read-modify-write paths for one job (design 10.3).

    The tools run on a thread pool, and the local buffer is also touched by
    read-only tools (legacy adoption).  An RLock lets the write methods call
    the locked helpers without deadlocking.
    """

    @functools.wraps(method)
    def wrapped(self, job_id, *args, **kwargs):
        with self._job_lock(job_id):
            return method(self, job_id, *args, **kwargs)

    return wrapped


class JobService:
    def __init__(self, config: Config, transport: Transport):
        self.config = config
        self.transport = transport
        self.cache_dir = config.work_dir / "jobs"
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self._locks: dict[str, threading.RLock] = {}
        self._locks_guard = threading.Lock()

    def _job_lock(self, job_id: str) -> threading.RLock:
        with self._locks_guard:
            lock = self._locks.get(job_id)
            if lock is None:
                lock = threading.RLock()
                self._locks[job_id] = lock
            return lock

    # -- paths ---------------------------------------------------------------

    def job_path(self, job_id: str) -> str:
        return f"{self.config.jobs_root}/{job_id}/job.json"

    def _work_dir(self, job_id: str) -> Path:
        path = self.cache_dir / job_id
        path.mkdir(parents=True, exist_ok=True)
        return path

    @staticmethod
    def _partial_name(provider_id: str) -> str:
        # provider ids are constrained on the device, but this is also the
        # only place a PC-side value becomes a file name; keep it flat.
        key = re.sub(r"[^0-9A-Za-z._-]+", "_", provider_id or "")
        return f"translations.{key or PENDING_PROVIDER}.json"

    def _partial_path(self, job_id: str, provider_id: str) -> Path:
        return self._work_dir(job_id) / self._partial_name(provider_id)

    def _legacy_partial_path(self, job_id: str) -> Path:
        return self._work_dir(job_id) / LEGACY_PARTIAL_NAME

    def _rpc(self, argv: list[str], stdin: bytes | None = None) -> dict:
        return self.transport.rpc(argv, stdin)

    # -- read side -----------------------------------------------------------

    def status(self, job_id: str) -> dict:
        if not valid_job_id(job_id):
            raise ValidationError(f"invalid job id: {job_id}")
        return self._rpc(["job-status", "--job", self.job_path(job_id)])

    def _meta_path(self, job_id: str) -> Path:
        return self._work_dir(job_id) / "job-meta.json"

    def job_meta(self, job_id: str, refresh: bool = False) -> dict:
        """Cached job metadata (book fields, total, segment ids).

        A job's segments never change after export, so a submit/commit only
        needs this once.  Without the cache every submit would ask the device
        for ten thousand ids again (about 100 KB per call).
        """
        path = self._meta_path(job_id)
        if not refresh and path.exists():
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                pass
        meta = self.status(job_id)
        path.write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")
        return meta

    def _state_cache(self, job_id: str) -> Path:
        return self._work_dir(job_id) / "state.json"

    def load_state(self, job_id: str) -> dict:
        # The local copy is the newest when dtctl cannot upload (USB mount) and
        # avoids a device round trip on every submit.
        cached = self._state_cache(job_id)
        if cached.exists():
            try:
                return json.loads(cached.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                pass
        reply = self._rpc(
            ["cat", "--job", self.job_path(job_id), "--name", "state.json"]
        )
        if not reply.get("exists"):
            return {"schema": STATE_SCHEMA, "status": "exported"}
        try:
            state = json.loads(reply.get("content") or "{}")
        except json.JSONDecodeError:
            return {"schema": STATE_SCHEMA, "status": "exported"}
        self._save_state_local(job_id, state)
        return state

    def _save_state_local(self, job_id: str, state: dict) -> None:
        self._state_cache(job_id).write_text(
            json.dumps(state, ensure_ascii=False), encoding="utf-8"
        )

    def _save_state(self, job_id: str, state: dict) -> None:
        self._save_state_local(job_id, state)
        self._upload_state(job_id, state)

    @staticmethod
    def _read_partial_file(path: Path) -> dict[str, str]:
        if not path.exists():
            return {}
        try:
            raw = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return {}
        # Any other OSError must reach the caller: a transient unreadable
        # buffer that reads as {} would let the next submit overwrite every
        # translation it could not see.
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return {}
        if not isinstance(data, dict):
            return {}
        return {str(key): str(value) for key, value in data.items()}

    @staticmethod
    def _read_partial_for_migration(path: Path) -> dict[str, str] | None:
        """Read a buffer for a merge; None means unreadable or corrupt.

        Migration must never delete bytes it could not understand, and a
        read-only work dir must not turn a read-only tool into an error.
        """
        if not path.exists():
            return {}
        try:
            raw = path.read_text(encoding="utf-8")
        except OSError:
            return None
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return None
        if not isinstance(data, dict):
            return None
        return {str(key): str(value) for key, value in data.items()}

    @staticmethod
    def _write_partial_file(path: Path, translations: dict[str, str]) -> None:
        """Atomically replace a buffer; a crash must not leave half JSON."""
        raw = json.dumps(translations, ensure_ascii=False)
        temporary = path.with_name(path.name + ".tmp")
        try:
            temporary.write_text(raw, encoding="utf-8")
            os.replace(temporary, path)
        finally:
            if temporary.exists():
                try:
                    temporary.unlink()
                except OSError:
                    pass

    def _current_provider(self, job_id: str) -> str:
        provider_id = self.load_state(job_id).get("provider_id")
        if isinstance(provider_id, str) and provider_id.strip():
            return provider_id
        return PENDING_PROVIDER

    @_per_job_lock
    def _adopt_legacy_partial(self, job_id: str, provider_id: str) -> None:
        """Move a pre-3.4 single translation buffer to its provider's file.

        Old builds kept one ``translations.json`` per job.  The device state
        says which model wrote it, so it must be adopted before any provider
        starts reading, or the first per-provider load silently loses it.
        Called from read paths too: a failure leaves the legacy file exactly
        where it is (the next write retries) instead of failing a status read.
        """
        legacy = self._legacy_partial_path(job_id)
        try:
            if not legacy.exists():
                return
            legacy_data = self._read_partial_for_migration(legacy)
            if legacy_data is None:
                return
            target = self._partial_path(job_id, provider_id)
            if target.exists():
                target_data = self._read_partial_for_migration(target)
                if target_data is None:
                    return
                merged = dict(legacy_data)
                merged.update(target_data)
                self._write_partial_file(target, merged)
                legacy.unlink()
                return
            try:
                legacy.rename(target)
            except OSError:
                self._write_partial_file(target, legacy_data)
                legacy.unlink()
        except OSError:
            # Read-only or full work dir: keep the old buffer and let the
            # write path try again.
            return

    @_per_job_lock
    def _load_partial(
        self, job_id: str, provider_id: str | None = None
    ) -> dict[str, str]:
        provider_id = provider_id or self._current_provider(job_id)
        self._adopt_legacy_partial(job_id, provider_id)
        return self._read_partial_file(self._partial_path(job_id, provider_id))

    @_per_job_lock
    def _save_partial(
        self, job_id: str, provider_id: str, translations: dict[str, str]
    ) -> None:
        self._adopt_legacy_partial(job_id, provider_id)
        self._write_partial_file(
            self._partial_path(job_id, provider_id), translations
        )

    @_per_job_lock
    def _delete_partial(self, job_id: str, provider_id: str) -> None:
        self._partial_path(job_id, provider_id).unlink(missing_ok=True)

    def list_jobs(self) -> list[dict]:
        try:
            reply = self._rpc(["list-jobs"])
        except TransportError as error:
            return [{"error": str(error)}]
        return reply.get("jobs", [])

    def get_job(self, job_id: str) -> dict:
        status = self.status(job_id)
        state = self.load_state(job_id)
        # Provider and submitted must come from the same buffer.  dt_confirm_model
        # writes the local state first; the device state is the fallback after a
        # PC restart.
        provider_id = state.get("provider_id") or status.get("provider_id")
        model_name = state.get("model_name") or status.get("model_name")
        options = status.get("options") or {}
        return {
            "job_id": job_id,
            "book": {
                "device_path": status.get("book_path"),
                "title": status.get("title"),
                "source_lang": status.get("source_lang"),
                "target_lang": status.get("target_lang"),
                "spine_count": status.get("spine_count"),
            },
            "chapter_count": status.get("chapter_count", 0),
            "total": status.get("total", 0),
            "status": status.get("status", "exported"),
            "provider_id": provider_id,
            "model_name": model_name,
            # Snapshot the same provider even if a concurrent confirm_model
            # lands between the read above and this call.
            "submitted": len(
                self._load_partial(job_id, provider_id or PENDING_PROVIDER)
            ),
            # 17 Q5: always present (empty for jobs exported before it), so a
            # tool consumer can read options.glossary without a nil guard.
            "options": {
                "glossary": options.get("glossary") or [],
                "style_guide": options.get("style_guide") or "",
                "max_chars_per_segment": options.get("max_chars_per_segment"),
                "split_long_segments": options.get("split_long_segments"),
            },
        }

    def get_segments(
        self, job_id: str, offset: int = 0, limit: int = 50, include_context: bool = False
    ) -> dict:
        argv = [
            "get-segments", "--job", self.job_path(job_id),
            "--offset", str(int(offset)), "--limit", str(int(limit)),
        ]
        if include_context:
            argv.append("--context")
        return self._rpc(argv)

    # -- write side ----------------------------------------------------------

    def _upload(self, job_id: str, name: str, payload: dict) -> str:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        try:
            self._rpc(
                ["put", "--job", self.job_path(job_id), "--name", name], stdin=data
            )
            return "uploaded"
        except HeadlessUnavailable:
            return "unavailable"

    def _upload_state(self, job_id: str, state: dict) -> None:
        self._upload(job_id, "state.json", state)

    @_per_job_lock
    def submit(self, job_id: str, segments: list[dict]) -> dict:
        status = self.job_meta(job_id)
        known = set(status.get("segment_ids") or [])
        if not isinstance(segments, list) or not segments:
            raise ValidationError("segments must be a non-empty list")
        if len(segments) > self.config.max_segments_per_call:
            raise ValidationError(
                f"at most {self.config.max_segments_per_call} segments per call"
            )
        accepted: dict[str, str] = {}
        rejected: list[dict] = []
        for item in segments:
            segment_id = item.get("id") if isinstance(item, dict) else None
            if segment_id not in known:
                rejected.append({"id": str(segment_id), "reason": "unknown id"})
                continue
            try:
                accepted[segment_id] = validate_translation_text(
                    item.get("text"), self.config.max_chars_per_segment
                )
            except ValidationError as error:
                rejected.append({"id": segment_id, "reason": str(error)})

        provider_id = self._current_provider(job_id)
        merged = self._load_partial(job_id, provider_id)
        merged.update(accepted)
        self._save_partial(job_id, provider_id, merged)

        state = self.load_state(job_id)
        state.update(
            {
                "schema": STATE_SCHEMA,
                "status": "submitting",
                "submitted": len(merged),
                "total": status.get("total", 0),
            }
        )
        self._save_state(job_id, state)

        return {
            "job_id": job_id,
            "accepted": len(accepted),
            "rejected": rejected,
            "submitted": len(merged),
            "remaining": max(0, int(status.get("total", 0)) - len(merged)),
        }

    @_per_job_lock
    def confirm_model(
        self, job_id: str, model_name: str, display_name: str | None = None
    ) -> dict:
        status = self.job_meta(job_id)
        state = self.load_state(job_id)
        model_name = (model_name or "").strip()
        if not model_name:
            raise ValidationError("model_name must not be empty")
        if state.get("provider_id") and state.get("model_name") == model_name:
            self._adopt_legacy_partial(job_id, state["provider_id"])
            # A PC restart can lose the local state cache before the buffer;
            # only raise the reported count, never lower a device-reported one.
            current = len(self._load_partial(job_id, state["provider_id"]))
            if current > int(state.get("submitted") or 0):
                state["submitted"] = current
                self._save_state(job_id, state)
            return {"job_id": job_id, **state}
        provider_id = provider_id_for(model_name)
        old_provider = state.get("provider_id")
        old_key = old_provider if isinstance(old_provider, str) and old_provider else PENDING_PROVIDER
        # Read the old provider's buffer first, so a pre-confirmation buffer
        # is adopted before the first provider file is inspected.  Switching
        # models keeps each provider's uncommitted text in its own file: the
        # new model starts from whatever it submitted before (usually zero),
        # and switching back restores the old model's work.  Nothing from the
        # old model is sent as the new model's text (and the device ledger is
        # already keyed by provider).
        self._adopt_legacy_partial(job_id, old_key)
        translations = self._load_partial(job_id, provider_id)
        if old_key == PENDING_PROVIDER:
            pending = self._read_partial_file(
                self._partial_path(job_id, PENDING_PROVIDER)
            )
            if pending:
                merged = dict(translations)
                merged.update(pending)
                self._save_partial(job_id, provider_id, merged)
                self._delete_partial(job_id, PENDING_PROVIDER)
                translations = merged
        state.update(
            {
                "schema": STATE_SCHEMA,
                "status": "confirmed",
                "provider_id": provider_id,
                "model_name": model_name,
                "display_name": (display_name or "").strip() or f"MCP · {model_name}",
                "confirmed": True,
                "total": status.get("total", 0),
                "submitted": len(translations),
            }
        )
        self._save_state(job_id, state)
        return {"job_id": job_id, **state}

    def job_status(self, job_id: str) -> dict:
        status = self.status(job_id)
        state = self.load_state(job_id)
        provider_id = state.get("provider_id") or status.get("provider_id")
        model_name = state.get("model_name") or status.get("model_name")
        submitted = len(
            self._load_partial(job_id, provider_id or PENDING_PROVIDER)
        )
        total = int(status.get("total", 0))
        return {
            "job_id": job_id,
            "status": status.get("status", "exported"),
            "provider_id": provider_id,
            "model_name": model_name,
            "submitted": submitted,
            "total": total,
            "remaining": max(0, total - submitted),
        }

    @_per_job_lock
    def commit(
        self,
        job_id: str,
        set_display: bool = False,
        allow_partial: bool = False,
    ) -> dict:
        status = self.job_meta(job_id)
        state = self.load_state(job_id)
        if not state.get("provider_id") or not state.get("model_name"):
            return {
                "ok": False,
                "status": "needs_model_confirmation",
                "message": (
                    "请先询问用户本次翻译使用的模型名称，然后调用 dt_confirm_model"
                ),
                "suggested_schema": {"model_name": "string", "display_name": "string"},
            }
        translations = self._load_partial(job_id)
        segment_ids = status.get("segment_ids") or []
        missing = [segment_id for segment_id in segment_ids
                   if segment_id not in translations]
        if missing and not allow_partial:
            return {
                "ok": False,
                "status": "incomplete_job",
                "remaining": len(missing),
                "message": "还有段落未提交；如需部分导入请显式允许",
            }

        result = build_result(job_id, segment_ids, state, translations)
        result_path = self._work_dir(job_id) / "result.json"
        result_path.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")

        upload = self._upload(job_id, "result.json", result)
        if upload != "uploaded":
            # There is no device-side inbox any more: a job is only committed
            # through dtctl over SSH.  Saying so beats parking the file where
            # nothing will ever read it.
            return {
                "ok": False,
                "status": "import_unavailable",
                "job_id": job_id,
                "message": (
                    "this transport cannot run dtctl on the device, so the result "
                    "cannot be imported; configure the ssh transport "
                    "(read_key/write_key) or run dtctl import by hand"
                ),
                "translated": len(result["translations"]),
            }

        argv = ["import", "--job", self.job_path(job_id)]
        if allow_partial:
            argv.append("--allow-partial")
        try:
            reply = self._rpc(argv)
        except TransportError as error:
            return {"ok": False, "status": "import_failed", "message": str(error)}

        imported = reply.get("imported", {})
        state.update(
            {
                "schema": STATE_SCHEMA,
                "status": "committed",
                "provider_id": result["provider"]["provider_id"],
                "model_name": result["provider"]["model_name"],
                "submitted": len(translations),
                "total": status.get("total", 0),
            }
        )
        self._save_state_local(job_id, state)
        if set_display:
            try:
                self._rpc(
                    [
                        "set-display",
                        "--book", status.get("book_path") or "",
                        "--target", status.get("target_lang") or "",
                        "--provider", result["provider"]["provider_id"],
                    ]
                )
            except TransportError:
                # The import succeeded; a failed display switch is not fatal.
                pass
        return {"ok": True, "status": "committed", "job_id": job_id, "imported": imported}

    # -- provider / display --------------------------------------------------

    def list_providers(self, book_path: str, target_lang: str) -> dict:
        try:
            reply = self._rpc(
                ["list-providers", "--book", book_path, "--target", target_lang]
            )
        except HeadlessUnavailable:
            return {"ok": False, "status": "headless_unsupported"}
        except TransportError as error:
            return {"ok": False, "status": "error", "message": str(error)}
        return {"ok": True, "providers": reply.get("providers", [])}

    def delete_provider(self, book_path: str, target_lang: str, provider_id: str) -> dict:
        try:
            reply = self._rpc(
                [
                    "delete-provider", "--book", book_path,
                    "--target", target_lang, "--provider", provider_id,
                ]
            )
        except HeadlessUnavailable:
            return {"ok": False, "status": "headless_unsupported"}
        except TransportError as error:
            return {"ok": False, "status": "error", "message": str(error)}
        return {"ok": True, **reply}

    def set_display(self, book_path: str, target_lang: str, provider_id: str) -> dict:
        try:
            reply = self._rpc(
                [
                    "set-display", "--book", book_path,
                    "--target", target_lang, "--provider", provider_id,
                ]
            )
        except HeadlessUnavailable:
            return {"ok": False, "status": "headless_unsupported"}
        except TransportError as error:
            return {"ok": False, "status": "error", "message": str(error)}
        return {"ok": True, **reply}

    def refresh_device(self, book_path: str, target_lang: str) -> dict:
        try:
            reply = self._rpc(
                ["touch-reload", "--book", book_path, "--target", target_lang]
            )
        except HeadlessUnavailable:
            return {"ok": False, "status": "headless_unsupported"}
        except TransportError as error:
            return {"ok": False, "status": "error", "message": str(error)}
        return {"ok": True, **reply}


def result_from_file(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema") != RESULT_SCHEMA:
        raise ValidationError("not a dualtranslate result file")
    return data
