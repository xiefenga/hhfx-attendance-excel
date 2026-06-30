from __future__ import annotations

from datetime import date, time

from pydantic import BaseModel, Field


class AttendanceConfig(BaseModel):
    start_date: date | None = None
    end_date: date | None = None
    ignore_dates: list[date] = Field(default_factory=lambda: [date(2026, 6, 29)])
    overnight_cutoff: time = time(7, 0)
    work_start_time: time = time(8, 30)
    work_end_time: time = time(18, 0)
    overtime_start_time: time = time(19, 0)
    workday_overtime_2h_after: time = time(21, 0)
    workday_meal_after: time = time(22, 0)
    meal_allowance_amount: int = 30
    output_filename: str = "考勤加班汇总.xlsx"
