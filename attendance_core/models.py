from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from pathlib import Path


@dataclass(frozen=True)
class DetailRow:
    name: str
    department: str
    employee_id: str
    work_date: date
    day_type: str
    raw_punches: str
    last_punch: str
    overtime_hours: float
    meal: bool
    meal_amount: int
    absent: bool
    late: bool
    note: str


@dataclass(frozen=True)
class SummaryStats:
    people: int
    detail_records: int
    overtime_records: int
    absence_records: int
    late_records: int
    meal_records: int
    total_overtime_hours: float
    total_meal_amount: int


@dataclass(frozen=True)
class GenerationResult:
    output_path: Path
    detail_rows: list[DetailRow]
    stats: SummaryStats


@dataclass(frozen=True)
class ParsedHoliday:
    date: date
    label: str


@dataclass(frozen=True)
class ParsedNonWorkday:
    date: date
    label: str


@dataclass(frozen=True)
class ParsedWorkbook:
    report_start: date
    report_end: date
    suggested_start_date: date
    suggested_end_date: date
    suggested_ignore_dates: list[date]
    holidays: list[ParsedHoliday]
    weekend_dates: list[date]
    non_workdays: list[ParsedNonWorkday]
    employee_count: int
    date_count: int
