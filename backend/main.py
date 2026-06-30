from __future__ import annotations

import uuid
from pathlib import Path
from typing import Annotated

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.responses import Response
from starlette.types import Scope

from attendance_app.config import AttendanceConfig
from attendance_app.models import ParsedWorkbook, SummaryStats
from attendance_app.processor import generate_summary, parse_workbook


ROOT = Path(__file__).resolve().parents[1]
WEB_OUTPUT_DIR = ROOT / "outputs" / "web"
FRONTEND_DIST = ROOT / "frontend" / "dist"


class SPAStaticFiles(StaticFiles):
    async def get_response(self, path: str, scope: Scope) -> Response:
        try:
            return await super().get_response(path, scope)
        except StarletteHTTPException as exc:
            if exc.status_code == 404 and not path.startswith("api/"):
                return await super().get_response("index.html", scope)
            raise


class HealthResponse(BaseModel):
    status: str


class GenerateResponse(BaseModel):
    file_id: str
    filename: str
    stats: SummaryStats


class ParseResponse(BaseModel):
    file_id: str
    filename: str
    detected: ParsedWorkbook


class GenerateRequest(BaseModel):
    source_file_id: str
    config: AttendanceConfig


app = FastAPI(title="Attendance Excel App", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

UPLOADED_FILES: dict[str, Path] = {}
GENERATED_FILES: dict[str, Path] = {}


@app.get("/api/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(status="ok")


@app.post("/api/parse", response_model=ParseResponse)
async def parse(file: Annotated[UploadFile, File()]) -> ParseResponse:
    if not file.filename or not file.filename.endswith(".xlsx"):
        raise HTTPException(status_code=400, detail="请上传 .xlsx 文件")

    file_id = uuid.uuid4().hex
    work_dir = WEB_OUTPUT_DIR / file_id
    work_dir.mkdir(parents=True, exist_ok=True)
    input_path = work_dir / file.filename
    input_path.write_bytes(await file.read())
    UPLOADED_FILES[file_id] = input_path

    detected = parse_workbook(input_path)
    return ParseResponse(file_id=file_id, filename=file.filename, detected=detected)


@app.post("/api/generate", response_model=GenerateResponse)
def generate(request: GenerateRequest) -> GenerateResponse:
    input_path = UPLOADED_FILES.get(request.source_file_id)
    if input_path is None or not input_path.exists():
        raise HTTPException(status_code=404, detail="源文件不存在或已过期，请重新解析")

    work_dir = input_path.parent
    result = generate_summary(input_path, work_dir, request.config)
    file_id = uuid.uuid4().hex
    GENERATED_FILES[file_id] = result.output_path
    return GenerateResponse(
        file_id=file_id,
        filename=result.output_path.name,
        stats=result.stats,
    )


@app.get("/api/download/{file_id}")
def download(file_id: str) -> FileResponse:
    output_path = GENERATED_FILES.get(file_id)
    if output_path is None or not output_path.exists():
        raise HTTPException(status_code=404, detail="文件不存在或已过期")
    return FileResponse(
        output_path,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        filename=output_path.name,
    )


if FRONTEND_DIST.exists():
    app.mount("/", SPAStaticFiles(directory=FRONTEND_DIST, html=True), name="frontend")
