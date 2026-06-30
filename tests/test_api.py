from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.main import SPAStaticFiles, app


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "打卡时间.xlsx"


def test_health() -> None:
    client = TestClient(app)

    response = client.get("/api/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_spa_routes_fall_back_to_index() -> None:
    static_app = FastAPI()
    static_dir = ROOT / "outputs" / "tests" / "spa"
    static_dir.mkdir(parents=True, exist_ok=True)
    (static_dir / "index.html").write_text("<div id=\"root\"></div>", encoding="utf-8")
    static_app.mount("/", SPAStaticFiles(directory=static_dir, html=True), name="frontend")
    client = TestClient(static_app)

    response = client.get("/settings")

    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]


def test_unknown_api_routes_do_not_fall_back_to_spa() -> None:
    static_app = FastAPI()
    static_dir = ROOT / "outputs" / "tests" / "spa"
    static_dir.mkdir(parents=True, exist_ok=True)
    (static_dir / "index.html").write_text("<div id=\"root\"></div>", encoding="utf-8")
    static_app.mount("/", SPAStaticFiles(directory=static_dir, html=True), name="frontend")
    client = TestClient(static_app)

    response = client.get("/api/missing")

    assert response.status_code == 404
    assert "application/json" in response.headers["content-type"]


def test_generate_and_download() -> None:
    client = TestClient(app)
    config = {
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
        "output_filename": "考勤加班汇总.xlsx",
    }

    with SOURCE.open("rb") as workbook:
        parse_response = client.post(
            "/api/parse",
            files={
                "file": (
                    "打卡时间.xlsx",
                    workbook,
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                )
            },
        )

    assert parse_response.status_code == 200
    parsed = parse_response.json()
    assert parsed["filename"] == "打卡时间.xlsx"
    assert parsed["detected"]["report_start"] == "2026-06-01"
    assert parsed["detected"]["report_end"] == "2026-06-29"
    assert parsed["detected"]["suggested_end_date"] == "2026-06-29"
    assert parsed["detected"]["suggested_ignore_dates"] == []
    assert parsed["detected"]["holidays"] == [{"date": "2026-06-19", "label": "端午节"}]
    assert {"date": "2026-06-13", "label": "周六"} in parsed["detected"]["non_workdays"]
    assert {"date": "2026-06-14", "label": "周日"} in parsed["detected"]["non_workdays"]
    assert {"date": "2026-06-19", "label": "端午节"} in parsed["detected"]["non_workdays"]
    assert parsed["detected"]["employee_count"] == 75

    response = client.post(
        "/api/generate",
        json={"source_file_id": parsed["file_id"], "config": config},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["filename"] == "考勤加班汇总.xlsx"
    assert payload["stats"]["late_records"] == 197
    assert payload["stats"]["overtime_records"] > 0

    download = client.get(f"/api/download/{payload['file_id']}")
    assert download.status_code == 200
    assert download.content.startswith(b"PK")
