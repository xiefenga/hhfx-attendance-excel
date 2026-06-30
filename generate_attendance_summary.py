from __future__ import annotations

from pathlib import Path

from attendance_app.config import AttendanceConfig
from attendance_app.processor import generate_summary


def main() -> None:
    result = generate_summary(
        Path("打卡时间.xlsx"),
        Path("outputs/attendance-summary"),
        AttendanceConfig(),
    )
    print(result.output_path.resolve())
    print(
        f"detail_rows={result.stats.detail_records} "
        f"people={result.stats.people} "
        f"late_records={result.stats.late_records}"
    )


if __name__ == "__main__":
    main()
