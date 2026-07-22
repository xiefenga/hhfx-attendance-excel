from __future__ import annotations

import io
import json
from pathlib import Path

from attendance_sidecar.main import response_for, serve


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "打卡时间.xlsx"


def test_worker_hello() -> None:
    response = response_for(
        {"request_id": "hello-1", "method": "hello", "payload": {}}
    )

    assert response == {
        "request_id": "hello-1",
        "ok": True,
        "result": {"protocol_version": 1, "worker_version": "0.1.0"},
    }


def test_worker_parse_and_generate(tmp_path: Path) -> None:
    parsed = response_for(
        {
            "request_id": "parse-1",
            "method": "parse",
            "payload": {"input_path": str(SOURCE)},
        }
    )
    output_path = tmp_path / "桌面端汇总.xlsx"
    generated = response_for(
        {
            "request_id": "generate-1",
            "method": "generate",
            "payload": {
                "input_path": str(SOURCE),
                "output_path": str(output_path),
                "config": {
                    "start_date": "2026-06-01",
                    "end_date": "2026-06-28",
                    "ignore_dates": ["2026-06-29"],
                    "overnight_cutoff": "07:00:00",
                    "work_start_time": "08:30:00",
                    "work_end_time": "18:00:00",
                    "overtime_start_time": "19:00:00",
                    "workday_overtime_2h_after": "21:00:00",
                    "workday_meal_after": "22:00:00",
                    "meal_allowance_amount": 30,
                    "output_filename": "ignored.xlsx",
                },
            },
        }
    )

    assert parsed["ok"] is True
    assert parsed["result"]["filename"] == SOURCE.name
    assert parsed["result"]["detected"]["employee_count"] == 75
    assert generated["ok"] is True
    assert generated["result"]["output_path"] == str(output_path)
    assert generated["result"]["stats"]["late_records"] == 197
    assert output_path.read_bytes().startswith(b"PK")


def test_worker_rejects_overwriting_source() -> None:
    response = response_for(
        {
            "request_id": "generate-1",
            "method": "generate",
            "payload": {
                "input_path": str(SOURCE),
                "output_path": str(SOURCE),
                "config": {},
            },
        }
    )

    assert response["ok"] is False
    assert response["error"]["code"] == "invalid_output"


def test_worker_stream_protocol_and_shutdown() -> None:
    source = io.StringIO(
        "not-json\n"
        + json.dumps({"request_id": "bye", "method": "shutdown"})
        + "\n"
    )
    target = io.StringIO()

    serve(source, target)

    responses = [json.loads(line) for line in target.getvalue().splitlines()]
    assert responses[0]["error"]["code"] == "invalid_json"
    assert responses[1] == {
        "request_id": "bye",
        "ok": True,
        "result": {"shutting_down": True},
    }
