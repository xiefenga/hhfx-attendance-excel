from __future__ import annotations

import argparse
from pathlib import Path

from attendance_core.config import AttendanceConfig
from attendance_core.processor import generate_summary


def main() -> None:
    parser = argparse.ArgumentParser(description="根据钉钉两张考勤表生成汇总工作簿")
    parser.add_argument("punch_file", type=Path, help="钉钉打卡时间 .xlsx")
    parser.add_argument("monthly_file", type=Path, help="钉钉月度汇总 .xlsx")
    parser.add_argument("--output-dir", type=Path, default=Path("outputs/attendance-summary"))
    args = parser.parse_args()
    result = generate_summary(
        args.punch_file,
        args.output_dir,
        AttendanceConfig(),
        monthly_file=args.monthly_file,
    )
    print(result.output_path.resolve())
    print(
        f"detail_rows={result.stats.detail_records} "
        f"people={result.stats.people} "
        f"late_records={result.stats.late_records}"
    )


if __name__ == "__main__":
    main()
