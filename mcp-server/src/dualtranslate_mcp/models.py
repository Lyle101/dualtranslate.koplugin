"""Job/result schema helpers (design 10.2 / 6.1).

The device is the schema owner: everything here only validates what it wrote,
so a malformed job fails before any translation is paid for.
"""

from __future__ import annotations

import hashlib
import re
from typing import Any

JOB_SCHEMA = "dualtranslate.job.v1"
RESULT_SCHEMA = "dualtranslate.result.v1"
STATE_SCHEMA = "dualtranslate.state.v1"

JOB_ID_RE = re.compile(r"^[0-9A-Za-z_-]+$")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,39}$")


class ValidationError(ValueError):
    """A job/result/segment did not follow the device schema."""


def valid_job_id(job_id: Any) -> bool:
    return isinstance(job_id, str) and bool(JOB_ID_RE.fullmatch(job_id))


def slugify(model_name: str) -> str:
    """Design 6.1: mcp:<slug>, with a hash fallback for non-ASCII names."""
    base = re.sub(r"[^a-z0-9._-]+", "-", model_name.strip().lower())
    base = base.strip("-")[:40]
    if not base or not SLUG_RE.fullmatch(base):
        digest = hashlib.sha1(model_name.encode("utf-8")).hexdigest()[:8]
        base = f"model-{digest}"
    return base


def provider_id_for(model_name: str) -> str:
    if not model_name or not model_name.strip():
        raise ValidationError("model_name must not be empty")
    return f"mcp:{slugify(model_name)}"


def validate_job(job: dict) -> None:
    if job.get("schema") != JOB_SCHEMA:
        raise ValidationError("job schema mismatch")
    if not valid_job_id(job.get("job_id")):
        raise ValidationError("invalid job_id")
    book = job.get("book")
    if not isinstance(book, dict) or not book.get("device_path"):
        raise ValidationError("job has no book.device_path")
    if not isinstance(job.get("segments"), list) or not job["segments"]:
        raise ValidationError("job has no segments")
    seen = set()
    for segment in job["segments"]:
        if not isinstance(segment, dict):
            raise ValidationError("segment is not an object")
        segment_id = segment.get("id")
        if not isinstance(segment_id, str) or not segment_id:
            raise ValidationError("segment without id")
        if segment_id in seen:
            raise ValidationError(f"duplicate segment id: {segment_id}")
        seen.add(segment_id)
        if not segment.get("selector"):
            raise ValidationError(f"segment {segment_id} has no selector")
        if not isinstance(segment.get("source"), str) or not segment["source"]:
            raise ValidationError(f"segment {segment_id} has no source")
        parent_total = segment.get("parent_total", 1)
        if not isinstance(parent_total, int) or parent_total < 1:
            raise ValidationError(f"segment {segment_id} has invalid parent_total")
        part = segment.get("part", 1)
        if not isinstance(part, int) or not 1 <= part <= parent_total:
            raise ValidationError(f"segment {segment_id} has invalid part")


def validate_translation_text(text: Any, max_chars: int) -> str:
    if not isinstance(text, str):
        raise ValidationError("translation text must be a string")
    if not text.strip():
        raise ValidationError("translation text is empty")
    if "\x00" in text:
        raise ValidationError("translation text contains NUL")
    if len(text) > max_chars:
        raise ValidationError(f"translation text exceeds {max_chars} characters")
    return text


def build_result(job: dict, state: dict, translations: dict[str, str]) -> dict:
    """One result row per job segment, in job order, so import is deterministic."""
    rows = []
    for segment in job["segments"]:
        text = translations.get(segment["id"])
        if text:
            rows.append({"id": segment["id"], "text": text})
    return {
        "schema": RESULT_SCHEMA,
        "job_id": job["job_id"],
        "provider": {
            "provider_id": state["provider_id"],
            "kind": "mcp",
            "model_name": state["model_name"],
            "display_name": state.get("display_name") or state["model_name"],
            "confirmed": True,
        },
        "translations": rows,
        "stats": {
            "submitted": len(rows),
            "accepted": len(rows),
            "rejected": len(job["segments"]) - len(rows),
        },
    }
