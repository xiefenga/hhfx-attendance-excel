from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import traceback
from zipfile import BadZipFile
from dataclasses import asdict
from datetime import date
from io import TextIOWrapper
from pathlib import Path
from typing import Any, TextIO, cast

from openpyxl.utils.exceptions import InvalidFileException

from attendance_core.monthly import parse_monthly_workbook
from attendance_core.processor import (
    generate_summary,
    monthly_workbook_employees,
    parse_sources,
    parse_workbook,
    workbook_employees,
)


PROTOCOL_VERSION = 2
WORKER_VERSION = "0.1.0"


class WorkerRequestError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def json_default(value: object) -> str:
    if isinstance(value, (date, Path)):
        return str(value)
    raise TypeError(f"Object of type {type(value).__name__} is not JSON serializable")


def require_xlsx(path_value: object, field_name: str) -> Path:
    if not isinstance(path_value, str) or not path_value.strip():
        raise WorkerRequestError("invalid_request", f"{field_name} 不能为空")
    path = Path(path_value).expanduser().resolve()
    if path.suffix.lower() != ".xlsx":
        raise WorkerRequestError("invalid_file", f"{field_name} 必须是 .xlsx 文件")
    return path


def handle_request(request: dict[str, Any]) -> dict[str, Any]:
    method = request.get("method")
    payload = request.get("payload") or {}
    if not isinstance(payload, dict):
        raise WorkerRequestError("invalid_request", "payload 必须是对象")

    if method == "hello":
        return {
            "protocol_version": PROTOCOL_VERSION,
            "worker_version": WORKER_VERSION,
        }

    if method == "parse":
        input_path = require_xlsx(payload.get("input_path"), "input_path")
        monthly_path = require_xlsx(payload.get("monthly_path"), "monthly_path")
        if not input_path.is_file():
            raise WorkerRequestError("file_not_found", "打卡时间表不存在")
        if not monthly_path.is_file():
            raise WorkerRequestError("file_not_found", "月度汇总表不存在")
        return {
            "source_path": str(input_path),
            "filename": input_path.name,
            "monthly_source_path": str(monthly_path),
            "monthly_filename": monthly_path.name,
            "detected": asdict(parse_sources(input_path, monthly_path)),
        }

    if method == "validate":
        kind = payload.get("kind")
        if kind not in {"punch", "monthly"}:
            raise WorkerRequestError("invalid_request", "kind 必须是 punch 或 monthly")
        input_path = require_xlsx(payload.get("input_path"), "input_path")
        label = "打卡时间表" if kind == "punch" else "月度汇总表"
        if not input_path.is_file():
            raise WorkerRequestError("file_not_found", f"{label}不存在")
        try:
            if kind == "punch":
                parsed = parse_workbook(input_path)
                employees = workbook_employees(input_path)
                report_start = parsed.report_start
                report_end = parsed.report_end
            else:
                monthly = parse_monthly_workbook(input_path)
                employees = monthly_workbook_employees(monthly)
                report_start = monthly.report_start
                report_end = monthly.report_end
        except (BadZipFile, InvalidFileException) as exc:
            raise WorkerRequestError(
                "invalid_workbook", f"{label}不是有效的 Excel 工作簿"
            ) from exc
        except PermissionError as exc:
            raise WorkerRequestError(
                "file_unavailable", f"无法访问{label}，文件可能正被其他程序占用"
            ) from exc
        return {
            "kind": kind,
            "source_path": str(input_path),
            "filename": input_path.name,
            "employee_count": len(employees),
            "report_start": report_start,
            "report_end": report_end,
        }

    if method == "generate":
        input_path = require_xlsx(payload.get("input_path"), "input_path")
        monthly_path = require_xlsx(payload.get("monthly_path"), "monthly_path")
        output_path = require_xlsx(payload.get("output_path"), "output_path")
        if not input_path.is_file():
            raise WorkerRequestError("file_not_found", "打卡时间表不存在")
        if not monthly_path.is_file():
            raise WorkerRequestError("file_not_found", "月度汇总表不存在")
        for source_path in (input_path, monthly_path):
            same_file = source_path == output_path or (
                output_path.exists() and source_path.samefile(output_path)
            )
            if same_file:
                raise WorkerRequestError("invalid_output", "输出文件不能覆盖任一原始考勤文件")

        output_path.parent.mkdir(parents=True, exist_ok=True)
        temp_dir = Path(
            tempfile.mkdtemp(prefix=".attendance-", dir=str(output_path.parent))
        )
        try:
            result = generate_summary(
                input_path,
                temp_dir,
                monthly_file=monthly_path,
                output_filename=output_path.name,
            )
            os.replace(result.output_path, output_path)
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

        return {
            "output_path": str(output_path),
            "filename": output_path.name,
            "stats": asdict(result.stats),
        }

    if method == "shutdown":
        return {"shutting_down": True}

    raise WorkerRequestError("method_not_found", f"未知方法：{method}")


def response_for(request: object) -> dict[str, Any]:
    request_id: object = None
    try:
        if not isinstance(request, dict):
            raise WorkerRequestError("invalid_request", "请求必须是对象")
        request_id = request.get("request_id")
        if not isinstance(request_id, str) or not request_id:
            raise WorkerRequestError("invalid_request", "request_id 不能为空")
        return {
            "request_id": request_id,
            "ok": True,
            "result": handle_request(request),
        }
    except WorkerRequestError as exc:
        return {
            "request_id": request_id,
            "ok": False,
            "error": {"code": exc.code, "message": str(exc)},
        }
    except Exception as exc:  # pragma: no cover - exercised through integration
        traceback.print_exc(file=sys.stderr)
        return {
            "request_id": request_id,
            "ok": False,
            "error": {"code": "internal_error", "message": str(exc) or "处理失败"},
        }


def serve(input_stream: TextIO, output_stream: TextIO) -> None:
    for raw_line in input_stream:
        request: object = None
        try:
            request = json.loads(raw_line)
        except json.JSONDecodeError:
            response = {
                "request_id": None,
                "ok": False,
                "error": {"code": "invalid_json", "message": "请求不是有效 JSON"},
            }
        else:
            response = response_for(request)

        output_stream.write(json.dumps(response, ensure_ascii=False, default=json_default))
        output_stream.write("\n")
        output_stream.flush()

        if (
            isinstance(request, dict)
            and request.get("method") == "shutdown"
            and response["ok"]
        ):
            break


def main() -> None:
    # Electron uses UTF-8 JSON Lines. Redirected stdio otherwise follows the
    # Windows ANSI code page and corrupts paths containing Chinese characters.
    cast(TextIOWrapper, sys.stdin).reconfigure(encoding="utf-8")
    cast(TextIOWrapper, sys.stdout).reconfigure(encoding="utf-8")
    serve(sys.stdin, sys.stdout)


if __name__ == "__main__":
    main()
