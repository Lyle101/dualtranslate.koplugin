"""Job orchestration: read jobs, collect translations, commit back (10.2/10.3).

The server keeps the merged translations in a local working copy and only
ships complete files to the device.  Every write goes through dtctl; when the
transport cannot execute it (USB mount), commit falls back to writing the
result into the inbox, which the plugin imports on its next open.
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
    validate_job,
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

    def _job_cache(self, job_id: str) -> Path:
        return self.cache_dir / job_id / "job.json"

    def _work_dir(self, job_id: str) -> Path:
        path = self.cache_dir / job_id
        path.mkdir(parents=True, exist_ok=True)
        return path

    # -- device state --------------------------------------------------------

    def load_job(self, job_id: str) -> dict:
        if not valid_job_id(job_id):
            raise ValidationError(f"invalid job id: {job_id}")
        cached = self._job_cache(job_id)
        if cached.exists():
            job = json.loads(cached.read_text(encoding="utf-8"))
            validate_job(job)
            return job
        raw = self.transport.read_text(self.job_path(job_id))
        job = json.loads(raw)
        validate_job(job)
        cached.parent.mkdir(parents=True, exist_ok=True)
        cached.write_text(raw, encoding="utf-8")
        return job

    def load_state(self, job_id: str) -> dict:
        local = self.cache_dir / job_id / "state.json"
        if local.exists():
            return json.loads(local.read_text(encoding="utf-8"))
        try:
            raw = self.transport.read_text(f"{self.config.jobs_root}/{job_id}/state.json")
        except (TransportError, FileNotFoundError):
            return {"schema": STATE_SCHEMA, "status": "exported"}
        try:
            state = json.loads(raw)
        except json.JSONDecodeError:
            return {"schema": STATE_SCHEMA, "status": "exported"}
        self._save_state_local(job_id, state)
        return state

    def _save_state_local(self, job_id: str, state: dict) -> None:
        path = self._work_dir(job_id) / "state.json"
        path.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")

    def _partial_path(self, job_id: str) -> Path:
        return self._work_dir(job_id) / "translations.json"

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

    # -- uploads -------------------------------------------------------------

    def _upload(self, job_id: str, name: str, payload: dict) -> str:
        """Uploads through dtctl put; returns "uploaded" or "inbox"."""
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        try:
            self.transport.dtctl(
                ["put", "--job", self.job_path(job_id), "--name", name], stdin=data
            )
            return "uploaded"
        except HeadlessUnavailable:
            return "unavailable"

    def _upload_state(self, job_id: str, state: dict) -> None:
        self._upload(job_id, "state.json", state)

    # -- read side -----------------------------------------------------------

    def list_jobs(self) -> list[dict]:
        try:
            names = self.transport.list_dir(self.config.jobs_root)
        except TransportError as error:
            return [{"error": str(error)}]
        jobs = []
        for name in names:
            if not valid_job_id(name):
                continue
            try:
                job = self.load_job(name)
                state = self.load_state(name)
            except (TransportError, ValidationError, json.JSONDecodeError):
                continue
            jobs.append(
                {
                    "job_id": name,
                    "created_at": job.get("created_at", 0),
                    "title": job.get("book", {}).get("title"),
                    "book_path": job.get("book", {}).get("device_path"),
                    "chapters": len(job.get("chapters", [])),
                    "total": len(job["segments"]),
                    "status": state.get("status", "exported"),
                    "provider_id": state.get("provider_id"),
                    "model_name": state.get("model_name"),
                    "submitted": state.get("submitted", 0),
                }
            )
        jobs.sort(key=lambda item: (item["created_at"], item["job_id"]), reverse=True)
        return jobs

    def get_job(self, job_id: str) -> dict:
        job = self.load_job(job_id)
        state = self.load_state(job_id)
        return {
            "job_id": job_id,
            "book": job.get("book"),
            "chapters": job.get("chapters", []),
            "total": len(job["segments"]),
            "options": job.get("options", {}),
            "status": state.get("status", "exported"),
            "provider_id": state.get("provider_id"),
            "model_name": state.get("model_name"),
            "submitted": len(self._load_partial(job_id)),
        }

    def get_segments(
        self, job_id: str, offset: int = 0, limit: int = 50, include_context: bool = False
    ) -> dict:
        job = self.load_job(job_id)
        segments = job["segments"]
        offset = max(0, int(offset))
        limit = max(1, min(int(limit), 100))
        window = segments[offset : offset + limit]
        rows = []
        for index, segment in enumerate(window, start=offset):
            row = {
                "id": segment["id"],
                "parent_id": segment.get("parent_id", segment["id"]),
                "part": segment.get("part", 1),
                "parent_total": segment.get("parent_total", 1),
                "chapter_index": segment.get("chapter_index"),
                "chapter_title": segment.get("chapter_title"),
                "source": segment["source"],
            }
            if include_context:
                # For part 2+ the "previous" text must be the previous part of
                # the same paragraph, not the previous paragraph, or the agent
                # loses the cross-part reference (design 10.2).
                row["prev"] = segments[index - 1]["source"][-200:] if index > 0 else None
                row["next"] = (
                    segments[index + 1]["source"][:200] if index + 1 < len(segments) else None
                )
            rows.append(row)
        return {
            "job_id": job_id,
            "total": len(segments),
            "next_offset": offset + len(rows) if offset + len(rows) < len(segments) else None,
            "segments": rows,
        }

    # -- write side ----------------------------------------------------------

    def submit(self, job_id: str, segments: list[dict]) -> dict:
        job = self.load_job(job_id)
        known = {segment["id"]: segment for segment in job["segments"]}
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
                "total": len(job["segments"]),
            }
        )
        self._save_state_local(job_id, state)
        self._upload_state(job_id, state)

        return {
            "job_id": job_id,
            "accepted": len(accepted),
            "rejected": rejected,
            "submitted": len(merged),
            "remaining": len(job["segments"]) - len(merged),
        }

    def confirm_model(
        self, job_id: str, model_name: str, display_name: str | None = None
    ) -> dict:
        job = self.load_job(job_id)
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
                "total": len(job["segments"]),
                "submitted": len(self._load_partial(job_id)),
            }
        )
        self._save_state_local(job_id, state)
        self._upload_state(job_id, state)
        return {"job_id": job_id, **state}

    def job_status(self, job_id: str) -> dict:
        job = self.load_job(job_id)
        state = self.load_state(job_id)
        submitted = len(self._load_partial(job_id))
        return {
            "job_id": job_id,
            "status": state.get("status", "exported"),
            "provider_id": state.get("provider_id"),
            "model_name": state.get("model_name"),
            "submitted": submitted,
            "total": len(job["segments"]),
            "remaining": len(job["segments"]) - submitted,
        }

    def commit(
        self,
        job_id: str,
        set_display: bool = False,
        allow_partial: bool = False,
    ) -> dict:
        job = self.load_job(job_id)
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
        missing = [
            segment["id"] for segment in job["segments"] if segment["id"] not in translations
        ]
        if missing and not allow_partial:
            return {
                "ok": False,
                "status": "incomplete_job",
                "remaining": len(missing),
                "message": "还有段落未提交；如需部分导入请显式允许",
            }

        result = build_result(job, state, translations)
        result_path = self._work_dir(job_id) / "result.json"
        result_path.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")

        upload = self._upload(job_id, "result.json", result)
        if upload != "uploaded":
            # No dtctl: park the result in the inbox and let the plugin import
            # it on the next open (design 10.5 fallback).
            inbox_id = self.transport.write_inbox(
                job_id, json.dumps(result, ensure_ascii=False).encode("utf-8")
            )
            state.update({"status": "pending_import", "submitted": len(translations)})
            self._save_state_local(job_id, state)
            return {
                "ok": True,
                "status": "pending_import",
                "job_id": job_id,
                "inbox": inbox_id,
                "translated": len(result["translations"]),
            }

        argv = ["import", "--job", self.job_path(job_id)]
        if allow_partial:
            argv.append("--allow-partial")
        try:
            reply = self.transport.dtctl(argv)
        except TransportError as error:
            return {"ok": False, "status": "import_failed", "message": str(error)}

        imported = reply.get("imported", {})
        if set_display and imported.get("confirmed", True):
            try:
                self.transport.dtctl(
                    [
                        "set-display",
                        "--book", job["book"]["device_path"],
                        "--target", job["book"]["target_lang"],
                        "--provider", result["provider"]["provider_id"],
                    ]
                )
            except TransportError:
                # The import succeeded; a failed display switch is not fatal.
                pass
        state.update(
            {
                "status": "committed",
                "provider_id": result["provider"]["provider_id"],
                "model_name": result["provider"]["model_name"],
                "submitted": len(translations),
                "total": len(job["segments"]),
            }
        )
        self._save_state_local(job_id, state)
        return {"ok": True, "status": "committed", "job_id": job_id, "imported": imported}

    # -- provider / display --------------------------------------------------

    def list_providers(self, book_path: str, target_lang: str) -> dict:
        try:
            reply = self.transport.dtctl(
                ["list-providers", "--book", book_path, "--target", target_lang]
            )
        except HeadlessUnavailable:
            return {"ok": False, "status": "headless_unsupported"}
        except TransportError as error:
            return {"ok": False, "status": "error", "message": str(error)}
        return {"ok": True, "providers": reply.get("providers", [])}

    def delete_provider(self, book_path: str, target_lang: str, provider_id: str) -> dict:
        try:
            reply = self.transport.dtctl(
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
            reply = self.transport.dtctl(
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
            reply = self.transport.dtctl(
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

