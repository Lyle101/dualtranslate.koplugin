"""Job service tests against a local device mirror (no SSH, no mcp SDK)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from dualtranslate_mcp.config import Config
from dualtranslate_mcp.jobs import JobService
from dualtranslate_mcp.models import (
    ValidationError,
    build_result,
    provider_id_for,
    slugify,
    validate_job,
)
from dualtranslate_mcp.transport import LocalTransport

KO_ROOT = "/mnt/us/koreader"
JOB_ID = "20261115_120000_0001"


def make_job() -> dict:
    return {
        "schema": "dualtranslate.job.v1",
        "job_id": JOB_ID,
        "created_at": 1760000000,
        "book": {
            "device_path": "/mnt/us/documents/book.epub",
            "title": "Test Book",
            "source_lang": "en",
            "target_lang": "zh-Hans",
            "spine_count": 3,
            "file_size": 4096,
            "file_mtime": 1760000000,
        },
        "chapters": [{"index": 1, "title": "One"}, {"index": 2, "title": "Two"}],
        "segments": [
            {
                "id": "s000001", "parent_id": "s000001", "part": 1, "parent_total": 2,
                "chapter_index": 1, "chapter_title": "One", "selector": "sel-a",
                "xpointer": "/body/DocFragment/body/p[1]", "source": "Part one",
            },
            {
                "id": "s000002", "parent_id": "s000001", "part": 2, "parent_total": 2,
                "chapter_index": 1, "chapter_title": "One", "selector": "sel-a",
                "xpointer": "/body/DocFragment/body/p[1]", "source": "part two",
            },
            {
                "id": "s000003", "parent_id": "s000003", "part": 1, "parent_total": 1,
                "chapter_index": 2, "chapter_title": "Two", "selector": "sel-b",
                "xpointer": "/body/DocFragment/body/p[2]", "source": "Second chapter",
            },
        ],
        "options": {"max_chars_per_segment": 4500, "split_long_segments": True},
    }


@pytest.fixture()
def service(tmp_path: Path) -> JobService:
    device = tmp_path / "device"
    job_dir = device / "cache/dualtranslate/mcp/jobs" / JOB_ID
    job_dir.mkdir(parents=True)
    (job_dir / "job.json").write_text(json.dumps(make_job()), encoding="utf-8")
    (job_dir / "state.json").write_text(
        json.dumps({"schema": "dualtranslate.state.v1", "status": "exported",
                    "submitted": 0, "total": 3}),
        encoding="utf-8",
    )
    config = Config(
        transport="local",
        ko_root=KO_ROOT,
        local_root=str(device),
        work_dir=tmp_path / "work",
    )
    return JobService(config, LocalTransport(KO_ROOT, str(device)))


def test_validate_job_rejects_missing_selector() -> None:
    job = make_job()
    job["segments"][0]["selector"] = ""
    with pytest.raises(ValidationError):
        validate_job(job)


def test_provider_id_slug_and_hash() -> None:
    assert provider_id_for("GPT-5") == "mcp:gpt-5"
    assert provider_id_for("Claude Sonnet 4.5") == "mcp:claude-sonnet-4.5"
    hashed = provider_id_for("全中文模型")
    assert hashed.startswith("mcp:model-")
    assert len(hashed) <= 4 + 40


def test_list_jobs(service: JobService) -> None:
    jobs = service.list_jobs()
    assert len(jobs) == 1
    job = jobs[0]
    assert job["job_id"] == JOB_ID
    assert job["total"] == 3
    assert job["status"] == "exported"


def test_get_segments_pagination_and_context(service: JobService) -> None:
    page = service.get_segments(JOB_ID, offset=0, limit=2, include_context=True)
    assert page["total"] == 3
    assert page["next_offset"] == 2
    first, second = page["segments"]
    assert first["prev"] is None
    # Part 2 sees the tail of the previous part, not another paragraph's text.
    assert second["prev"] == "Part one"
    assert second["part"] == 2 and second["parent_total"] == 2

    tail = service.get_segments(JOB_ID, offset=2, limit=2)
    assert tail["next_offset"] is None
    assert len(tail["segments"]) == 1


def test_submit_validation(service: JobService) -> None:
    with pytest.raises(ValidationError):
        service.submit(JOB_ID, [])
    result = service.submit(JOB_ID, [{"id": "s999999", "text": "x"}])
    assert result["accepted"] == 0
    assert result["rejected"][0]["reason"] == "unknown id"

    result = service.submit(JOB_ID, [{"id": "s000001", "text": "  "}])
    assert result["accepted"] == 0
    assert result["remaining"] == 3

    too_long = "x" * (service.config.max_chars_per_segment + 1)
    result = service.submit(JOB_ID, [{"id": "s000001", "text": too_long}])
    assert result["accepted"] == 0


def test_submit_merges_and_reports_remaining(service: JobService) -> None:
    first = service.submit(JOB_ID, [{"id": "s000001", "text": "第一段上"}])
    assert first["accepted"] == 1
    assert first["submitted"] == 1 and first["remaining"] == 2
    second = service.submit(
        JOB_ID,
        [{"id": "s000002", "text": "第一段下"}, {"id": "s000003", "text": "第二章"}],
    )
    assert second["submitted"] == 3 and second["remaining"] == 0
    # Re-submitting an id overwrites instead of duplicating.
    third = service.submit(JOB_ID, [{"id": "s000003", "text": "第二章（改）"}])
    assert third["submitted"] == 3


def test_commit_requires_model_confirmation(service: JobService) -> None:
    service.submit(JOB_ID, [{"id": "s000001", "text": "a"}])
    reply = service.commit(JOB_ID)
    assert reply["ok"] is False
    assert reply["status"] == "needs_model_confirmation"


def test_commit_rejects_incomplete_job(service: JobService) -> None:
    service.confirm_model(JOB_ID, "gpt-5")
    service.submit(JOB_ID, [{"id": "s000001", "text": "a"}])
    reply = service.commit(JOB_ID)
    assert reply["ok"] is False
    assert reply["status"] == "incomplete_job"
    assert reply["remaining"] == 2


def test_commit_without_dtctl_reports_error(service: JobService) -> None:
    """A transport that cannot run dtctl must say so, not park the result."""
    state = service.confirm_model(JOB_ID, "GPT-5")
    assert state["provider_id"] == "mcp:gpt-5"
    service.submit(
        JOB_ID,
        [
            {"id": "s000001", "text": "第一段上"},
            {"id": "s000002", "text": "第一段下"},
            {"id": "s000003", "text": "第二章"},
        ],
    )
    reply = service.commit(JOB_ID)
    assert reply["ok"] is False
    assert reply["status"] == "import_unavailable"
    assert "dtctl" in reply["message"]
    assert reply["translated"] == 3


def test_build_result_keeps_job_order(service: JobService) -> None:
    segment_ids = service.status(JOB_ID)["segment_ids"]
    state = service.confirm_model(JOB_ID, "gpt-5")
    translations = {"s000003": "c", "s000001": "a"}
    result = build_result(JOB_ID, segment_ids, state, translations)
    assert [row["id"] for row in result["translations"]] == ["s000001", "s000003"]
    assert result["stats"]["rejected"] == 1


def test_job_meta_is_cached(service: JobService, monkeypatch) -> None:
    calls = {"n": 0}
    original = service.status

    def counting(job_id: str) -> dict:
        calls["n"] += 1
        return original(job_id)

    monkeypatch.setattr(service, "status", counting)
    first = service.job_meta(JOB_ID)
    second = service.job_meta(JOB_ID)
    assert first["total"] == 3 and second["segment_ids"] == first["segment_ids"]
    assert calls["n"] == 1
    service.job_meta(JOB_ID, refresh=True)
    assert calls["n"] == 2
