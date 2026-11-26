"""Job orchestration: read jobs, collect translations, commit back (10.2/10.3).

All device access is a dtctl rpc call.  The server keeps only the merged
translations (a small working copy) and never downloads the whole job: the
device paginates segments and reports the id list, so a ten-thousand segment
book costs kilobytes per page instead of megabytes.

A transport that cannot execute dtctl (a USB mount) can inspect a job but
cannot commit it: the plugin has no device-side import any more.
"""

from __future__ import annotations

import json
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


class JobService:
    def __init__(self, config: Config, transport: Transport):
        self.config = config
        self.transport = transport
        self.cache_dir = config.work_dir / "jobs"
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    # -- paths ---------------------------------------------------------------

    def job_path(self, job_id: str) -> str:
        return f"{self.config.jobs_root}/{job_id}/job.json"

    def _work_dir(self, job_id: str) -> Path:
        path = self.cache_dir / job_id
        path.mkdir(parents=True, exist_ok=True)
        return path

    def _partial_path(self, job_id: str) -> Path:
        return self._work_dir(job_id) / "translations.json"

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

    def _load_partial(self, job_id: str) -> dict[str, str]:
        path = self._partial_path(job_id)
        if not path.exists():
            return {}
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}
        return {str(key): str(value) for key, value in data.items()}

    def _save_partial(self, job_id: str, translations: dict[str, str]) -> None:
        path = self._partial_path(job_id)
        path.write_text(json.dumps(translations, ensure_ascii=False), encoding="utf-8")

    def list_jobs(self) -> list[dict]:
        try:
            reply = self._rpc(["list-jobs"])
        except TransportError as error:
            return [{"error": str(error)}]
        return reply.get("jobs", [])

    def get_job(self, job_id: str) -> dict:
        status = self.status(job_id)
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
            "provider_id": status.get("provider_id"),
            "model_name": status.get("model_name"),
            "submitted": len(self._load_partial(job_id)),
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

        merged = self._load_partial(job_id)
        merged.update(accepted)
        self._save_partial(job_id, merged)

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

    def confirm_model(
        self, job_id: str, model_name: str, display_name: str | None = None
    ) -> dict:
        status = self.job_meta(job_id)
        state = self.load_state(job_id)
        model_name = (model_name or "").strip()
        if not model_name:
            raise ValidationError("model_name must not be empty")
        if state.get("provider_id") and state.get("model_name") == model_name:
            return {"job_id": job_id, **state}
        provider_id = provider_id_for(model_name)
        state.update(
            {
                "schema": STATE_SCHEMA,
                "status": "confirmed",
                "provider_id": provider_id,
                "model_name": model_name,
                "display_name": (display_name or "").strip() or f"MCP · {model_name}",
                "confirmed": True,
                "total": status.get("total", 0),
                "submitted": len(self._load_partial(job_id)),
            }
        )
        self._save_state(job_id, state)
        return {"job_id": job_id, **state}

    def job_status(self, job_id: str) -> dict:
        status = self.status(job_id)
        submitted = len(self._load_partial(job_id))
        total = int(status.get("total", 0))
        return {
            "job_id": job_id,
            "status": status.get("status", "exported"),
            "provider_id": status.get("provider_id"),
            "model_name": status.get("model_name"),
            "submitted": submitted,
            "total": total,
            "remaining": max(0, total - submitted),
        }

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
