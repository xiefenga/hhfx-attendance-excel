from __future__ import annotations

from datetime import date, time
from pathlib import Path

from openpyxl import load_workbook

from attendance_app.config import AttendanceConfig
from attendance_app.processor import (
    assign_punch_base_date,
    expand_cell_timeline,
    generate_summary,
    parse_workbook,
    previous_day_is_incomplete,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "打卡时间.xlsx"


def test_sample_workbook_ignores_june_29() -> None:
    result = generate_summary(SOURCE, ROOT / "outputs" / "tests", AttendanceConfig())

    assert all(row.work_date != date(2026, 6, 29) for row in result.detail_rows)


def test_workday_late_boundary_uses_0830() -> None:
    assert generate_summary(SOURCE, ROOT / "outputs" / "tests", AttendanceConfig()).stats.late_records == 197


def test_work_start_time_drives_late_detection() -> None:
    result = generate_summary(
        SOURCE,
        ROOT / "outputs" / "tests",
        AttendanceConfig(work_start_time=time(9, 0)),
    )

    assert result.stats.late_records < 215


def test_workday_overtime_values_are_only_two_or_four() -> None:
    result = generate_summary(SOURCE, ROOT / "outputs" / "tests", AttendanceConfig())
    workday_hours = {
        row.overtime_hours
        for row in result.detail_rows
        if row.day_type == "工作日" and row.overtime_hours > 0
    }

    assert workday_hours == {2.0, 4.0}


def test_early_morning_punch_stays_today_when_today_has_no_normal_start_punch() -> None:
    result = generate_summary(SOURCE, ROOT / "outputs" / "tests", AttendanceConfig())

    rows = {
        (row.name, row.work_date): row
        for row in result.detail_rows
        if row.name in {"柴伟", "郭孟良"}
    }

    chai_24 = rows[("柴伟", date(2026, 6, 24))]
    chai_25 = rows[("柴伟", date(2026, 6, 25))]
    guo_11 = rows[("郭孟良", date(2026, 6, 11))]

    assert chai_24.last_punch == "22:44"
    assert chai_24.overtime_hours == 2.0
    assert "6月25日 06:40" in chai_25.raw_punches
    assert not chai_25.late
    assert chai_25.overtime_hours == 2.0

    assert guo_11.last_punch == "21:14"
    assert guo_11.overtime_hours == 2.0
    assert not any(
        row.name == "郭孟良" and row.work_date == date(2026, 6, 12) and row.absent
        for row in result.detail_rows
    )


def test_previous_day_incomplete_means_only_one_punch() -> None:
    config = AttendanceConfig()

    assert previous_day_is_incomplete([time(21, 14)], config)
    assert not previous_day_is_incomplete([time(8, 25), time(21, 14)], config)
    assert (
        assign_punch_base_date(
            date(2026, 6, 12),
            time(6, 37),
            {date(2026, 6, 11): [time(8, 25), time(21, 14)], date(2026, 6, 12): [time(6, 37)]},
            config,
        )
        == date(2026, 6, 12)
    )


def test_same_cell_time_rollover_counts_as_next_day_overtime() -> None:
    result = generate_summary(SOURCE, ROOT / "outputs" / "tests", AttendanceConfig())

    row = next(
        item
        for item in result.detail_rows
        if item.name == "付陈良" and item.work_date == date(2026, 6, 26)
    )

    assert row.raw_punches == "6月26日 07:30\n6月27日 01:54"
    assert row.last_punch == "次日 01:54"
    assert row.overtime_hours == 4.0
    assert row.meal
    assert not row.absent
    assert not any(
        item.name == "付陈良" and item.work_date == date(2026, 6, 25) and "01:54" in item.raw_punches
        for item in result.detail_rows
    )


def test_overnight_notes_are_human_readable() -> None:
    result = generate_summary(SOURCE, ROOT / "outputs" / "tests", AttendanceConfig())
    notes = {row.note for row in result.detail_rows if row.note}

    assert "次日凌晨打卡，工作日加班按4小时折算" in notes
    assert "次日凌晨打卡，按跨天记录处理" in notes
    assert not any("约束已满足" in note for note in notes)


def test_same_cell_next_day_only_uses_trailing_early_off_work_punches() -> None:
    source_date = date(2026, 6, 26)

    assert expand_cell_timeline(source_date, [time(7, 30), time(1, 54)], AttendanceConfig()) == [
        (date(2026, 6, 26), time(7, 30)),
        (date(2026, 6, 27), time(1, 54)),
    ]
    assert expand_cell_timeline(source_date, [time(8, 30), time(8, 20), time(18, 0)], AttendanceConfig()) == [
        (date(2026, 6, 26), time(8, 30)),
        (date(2026, 6, 26), time(8, 20)),
        (date(2026, 6, 26), time(18, 0)),
    ]


def test_weekend_single_punch_is_not_absent() -> None:
    result = generate_summary(SOURCE, ROOT / "outputs" / "tests", AttendanceConfig())

    assert not any(
        row.name == "余祖应" and row.work_date == date(2026, 6, 13) and row.absent
        for row in result.detail_rows
    )


def test_holiday_header_marks_day_as_rest_day_without_config_parameter() -> None:
    result = generate_summary(SOURCE, ROOT / "outputs" / "tests", AttendanceConfig())

    assert any(
        row.work_date == date(2026, 6, 19) and row.day_type == "端午节"
        for row in result.detail_rows
    )


def test_weekend_day_type_uses_specific_weekday_name() -> None:
    result = generate_summary(SOURCE, ROOT / "outputs" / "tests", AttendanceConfig())

    assert any(row.work_date == date(2026, 6, 13) and row.day_type == "周六" for row in result.detail_rows)
    assert any(row.work_date == date(2026, 6, 14) and row.day_type == "周日" for row in result.detail_rows)


def test_person_summary_splits_overtime_hours_by_day_type() -> None:
    result = generate_summary(SOURCE, ROOT / "outputs" / "tests", AttendanceConfig())
    wb = load_workbook(result.output_path, data_only=True)
    ws = wb["人员汇总"]

    headers = [cell.value for cell in ws[1]]
    assert headers[7:11] == [
        "工作日加班时长",
        "周末加班时长",
        "节假日加班时长",
        "本月加班时长合计",
    ]

    expected: dict[tuple[str, str, str], dict[str, float]] = {}
    for row in result.detail_rows:
        key = (row.name, row.department, row.employee_id)
        person = expected.setdefault(
            key,
            {"workday": 0.0, "weekend": 0.0, "holiday": 0.0, "total": 0.0},
        )
        if row.overtime_hours <= 0:
            continue
        if row.day_type == "工作日":
            person["workday"] += row.overtime_hours
        elif row.day_type in {"周六", "周日"}:
            person["weekend"] += row.overtime_hours
        else:
            person["holiday"] += row.overtime_hours
        person["total"] += row.overtime_hours

    actual_rows = {
        (
            str(row[0].value or ""),
            str(row[1].value or ""),
            str(row[2].value or ""),
        ): row
        for row in ws.iter_rows(min_row=2)
    }
    for key, values in expected.items():
        if values["total"] == 0:
            continue
        row = actual_rows[key]
        assert float(row[7].value or 0) == round(values["workday"], 2)
        assert float(row[8].value or 0) == round(values["weekend"], 2)
        assert float(row[9].value or 0) == round(values["holiday"], 2)
        assert float(row[10].value or 0) == round(values["total"], 2)

    wb.close()


def test_parse_workbook_returns_detected_defaults() -> None:
    parsed = parse_workbook(SOURCE)

    assert parsed.report_start == date(2026, 6, 1)
    assert parsed.report_end == date(2026, 6, 29)
    assert parsed.suggested_start_date == date(2026, 6, 1)
    assert parsed.suggested_end_date == date(2026, 6, 29)
    assert parsed.suggested_ignore_dates == []
    assert [(item.date, item.label) for item in parsed.holidays] == [
        (date(2026, 6, 19), "端午节")
    ]
    assert (date(2026, 6, 13), "周六") in [
        (item.date, item.label) for item in parsed.non_workdays
    ]
    assert (date(2026, 6, 14), "周日") in [
        (item.date, item.label) for item in parsed.non_workdays
    ]
    assert (date(2026, 6, 19), "端午节") in [
        (item.date, item.label) for item in parsed.non_workdays
    ]
    assert parsed.employee_count == 75
    assert parsed.date_count == 29
