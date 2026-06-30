# Attendance App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a first-version local attendance Excel application with a typed Python API backend and typed React frontend.

**Architecture:** Extract the current Excel generation logic into a reusable Python package, expose it through FastAPI upload/generate/download endpoints, and add a React + TypeScript + Ant Design frontend. Keep files local and generated outputs under `outputs/web/`.

**Tech Stack:** Python 3, FastAPI, Pydantic, openpyxl, pytest, mypy, React, TypeScript, Vite, Ant Design, Axios.

---

### Task 1: Python package and typed attendance engine

**Files:**
- Create: `attendance_app/__init__.py`
- Create: `attendance_app/config.py`
- Create: `attendance_app/models.py`
- Create: `attendance_app/processor.py`
- Modify: `generate_attendance_summary.py`
- Test: `tests/test_processor.py`

- [ ] Move reusable business logic from `generate_attendance_summary.py` into `attendance_app/processor.py`.
- [ ] Define typed Pydantic config models in `attendance_app/config.py` for ignore dates, holidays, meal amount, late threshold, and output naming.
- [ ] Define typed dataclasses/Pydantic models in `attendance_app/models.py` for summary stats and generated file result.
- [ ] Keep `generate_attendance_summary.py` as a CLI wrapper that calls the package.
- [ ] Add pytest coverage for: 08:30 not late, 08:31 late, ignored 2026-06-29, workday overtime values only 2/4, weekend single punch not absent.

### Task 2: FastAPI backend

**Files:**
- Create: `backend/__init__.py`
- Create: `backend/main.py`
- Create: `requirements.txt`
- Test: `tests/test_api.py`

- [ ] Add `/api/health` returning typed status.
- [ ] Add `/api/generate` accepting multipart Excel file plus JSON config string.
- [ ] Return typed JSON with generated file id, output filename, and summary stats.
- [ ] Add `/api/download/{file_id}` to download the generated xlsx.
- [ ] Add FastAPI TestClient coverage for health and generate/download using the sample workbook.

### Task 3: React + TypeScript frontend

**Files:**
- Create: `frontend/package.json`
- Create: `frontend/tsconfig.json`
- Create: `frontend/tsconfig.node.json`
- Create: `frontend/vite.config.ts`
- Create: `frontend/index.html`
- Create: `frontend/src/main.tsx`
- Create: `frontend/src/App.tsx`
- Create: `frontend/src/api.ts`
- Create: `frontend/src/types.ts`
- Create: `frontend/src/styles.css`

- [ ] Build an Ant Design single-page tool with upload, config form, generate button, result stats, and download button.
- [ ] Define TypeScript request/response types matching backend Pydantic models.
- [ ] Add frontend typecheck script using `tsc --noEmit`.
- [ ] Add Vite dev proxy from `/api` to `http://127.0.0.1:8000`.

### Task 4: Verification and developer ergonomics

**Files:**
- Create: `README.md`
- Create: `mypy.ini`
- Modify: `requirements.txt`

- [ ] Document backend and frontend startup commands.
- [ ] Run `python3 -m pytest`.
- [ ] Run `python3 -m mypy attendance_app backend`.
- [ ] Run `npm install` then `npm run typecheck` and `npm run build` in `frontend`.
- [ ] Start backend and frontend dev servers and verify the first screen loads.
