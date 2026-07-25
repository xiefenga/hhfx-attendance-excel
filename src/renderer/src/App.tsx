import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";

import type {
  AttendanceConfig,
  DesktopSelection,
  GenerateResponse,
  ParseResponse
} from "../../shared/ipc-contract";
import {
  generateSummary,
  parseWorkbook,
  revealDesktopOutput,
  selectDesktopOutput,
  selectDesktopWorkbook
} from "./api";

type FileKind = "punch" | "monthly";
type BusyState = "idle" | "parsing" | "generating";

interface ErrorState {
  title: string;
  detail: string;
  fileKind: FileKind | null;
}

interface ModalProps {
  open: boolean;
  labelledBy: string;
  describedBy?: string;
  className?: string;
  onClose(): void;
  children: ReactNode;
}

const FILE_LABELS: Record<FileKind, string> = {
  punch: "打卡时间表",
  monthly: "月度汇总表"
};

function Modal({
  open,
  labelledBy,
  describedBy,
  className = "",
  onClose,
  children
}: ModalProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) {
      return;
    }
    if (open && !dialog.open) {
      dialog.showModal();
    } else if (!open && dialog.open) {
      dialog.close();
    }
  }, [open]);

  return (
    <dialog
      ref={dialogRef}
      className={className}
      aria-labelledby={labelledBy}
      aria-describedby={describedBy}
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
      onClose={onClose}
    >
      {children}
    </dialog>
  );
}

function CheckIcon({ className = "" }: { className?: string }) {
  return (
    <svg
      className={className}
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8" />
      <path
        d="m8 12 2.5 2.5L16 9"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function UploadIcon() {
  return (
    <svg width="17" height="17" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path
        d="M12 16V4m0 0L8 8m4-4 4 4M5 14v5a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-5"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function FolderIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path
        d="M3 7h7l2 2h9v10H3V7ZM3 7V5h7l2 2"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function formatFileSize(bytes: number): string {
  if (bytes >= 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

function compactDate(value: string): string {
  return value.replace(/-/g, "");
}

function buildConfig(parsed: ParseResponse): AttendanceConfig {
  const { detected } = parsed;
  return {
    start_date: detected.suggested_start_date,
    end_date: detected.suggested_end_date,
    ignore_dates: detected.suggested_ignore_dates,
    overnight_cutoff: "07:00:00",
    work_start_time: "08:30:00",
    work_end_time: "18:00:00",
    overtime_start_time: "19:00:00",
    workday_overtime_2h_after: "21:00:00",
    workday_meal_after: "22:00:00",
    meal_allowance_amount: 30,
    output_filename: `考勤汇总_${compactDate(detected.suggested_start_date)}_${compactDate(
      detected.suggested_end_date
    )}.xlsx`
  };
}

function classifyError(caught: unknown): ErrorState {
  const detail = caught instanceof Error ? caught.message : "处理失败，请更换文件后重试。";
  let fileKind: FileKind | null = null;
  if (detail.includes("打卡时间表")) {
    fileKind = "punch";
  } else if (detail.includes("月度汇总表")) {
    fileKind = "monthly";
  }
  return {
    title: fileKind ? `无法读取${FILE_LABELS[fileKind]}` : "无法生成考勤汇总表",
    detail,
    fileKind
  };
}

function FileCard({
  kind,
  file,
  parseResult,
  disabled,
  isError,
  onSelect
}: {
  kind: FileKind;
  file: DesktopSelection | null;
  parseResult: ParseResponse | null;
  disabled: boolean;
  isError: boolean;
  onSelect(): void;
}) {
  const label = FILE_LABELS[kind];
  const employeeCount = parseResult
    ? kind === "punch"
      ? parseResult.detected.employee_count
      : parseResult.detected.monthly_employee_count
    : null;

  return (
    <article
      className={`file-card${file ? " is-ready" : ""}${isError ? " is-error" : ""}`}
      aria-label={label}
    >
      <div className="file-card-head">
        <h2>{label}</h2>
        <p>
          {kind === "punch"
            ? "读取每日上下班打卡时间"
            : "核对人员与月度考勤状态"}
        </p>
      </div>

      <div className="file-state" aria-live="polite">
        {file ? (
          <div className="selected-file">
            <CheckIcon className="selected-check" />
            <div className="selected-file-copy">
              <span className="file-name" title={file.name}>
                {file.name}
              </span>
              <span className="file-meta">
                {employeeCount === null
                  ? `${formatFileSize(file.size)} · 等待校验`
                  : `已校验 · ${employeeCount} 人`}
              </span>
            </div>
          </div>
        ) : (
          <span className="empty-state">尚未选择 · 支持钉钉导出的 .xlsx 文件</span>
        )}
      </div>

      <button className="choose-button" type="button" disabled={disabled} onClick={onSelect}>
        <UploadIcon />
        <span>{file ? "更换文件" : `选择${label}`}</span>
      </button>
    </article>
  );
}

export default function App() {
  const [punchFile, setPunchFile] = useState<DesktopSelection | null>(null);
  const [monthlyFile, setMonthlyFile] = useState<DesktopSelection | null>(null);
  const [busy, setBusy] = useState<BusyState>("idle");
  const [parseResult, setParseResult] = useState<ParseResponse | null>(null);
  const [result, setResult] = useState<GenerateResponse | null>(null);
  const [error, setError] = useState<ErrorState | null>(null);
  const [differenceOpen, setDifferenceOpen] = useState(false);
  const [resultOpen, setResultOpen] = useState(false);
  const [revealed, setRevealed] = useState(false);

  const ready = punchFile !== null && monthlyFile !== null;
  const isBusy = busy !== "idle";
  const differences = useMemo(() => {
    if (!parseResult) {
      return [];
    }
    return [
      ...parseResult.detected.punch_only_employees.map((name) => ({
        name,
        location: "仅在打卡时间表"
      })),
      ...parseResult.detected.monthly_only_employees.map((name) => ({
        name,
        location: "仅在月度汇总表"
      }))
    ];
  }, [parseResult]);

  async function handleDesktopSelect(kind: FileKind) {
    try {
      const selected = await selectDesktopWorkbook(kind);
      if (!selected) {
        return;
      }
      if (kind === "punch") {
        setPunchFile(selected);
      } else {
        setMonthlyFile(selected);
      }
      setParseResult(null);
      setResult(null);
      setError(null);
      setRevealed(false);
    } catch (caught) {
      setError(classifyError(caught));
    }
  }

  async function generateFromParsed(parsed: ParseResponse) {
    if (!punchFile || !monthlyFile) {
      return;
    }
    const config = buildConfig(parsed);
    const outputPath = await selectDesktopOutput(config.output_filename);
    if (!outputPath) {
      return;
    }
    setBusy("generating");
    const generated = await generateSummary(
      punchFile.path,
      monthlyFile.path,
      outputPath,
      config
    );
    setResult(generated);
    setResultOpen(true);
    setRevealed(false);
  }

  async function handleGenerate() {
    if (!punchFile || !monthlyFile || isBusy) {
      return;
    }
    setError(null);
    try {
      let parsed = parseResult;
      if (!parsed) {
        setBusy("parsing");
        parsed = await parseWorkbook(punchFile.path, monthlyFile.path);
        setParseResult(parsed);
      }
      const hasDifferences =
        parsed.detected.punch_only_employees.length > 0 ||
        parsed.detected.monthly_only_employees.length > 0 ||
        parsed.detected.source_warnings.length > 0;
      if (hasDifferences) {
        setDifferenceOpen(true);
        return;
      }
      await generateFromParsed(parsed);
    } catch (caught) {
      setError(classifyError(caught));
    } finally {
      setBusy("idle");
    }
  }

  async function handleContinueWithDifferences() {
    if (!parseResult || isBusy) {
      return;
    }
    setDifferenceOpen(false);
    setError(null);
    try {
      await generateFromParsed(parseResult);
    } catch (caught) {
      setError(classifyError(caught));
    } finally {
      setBusy("idle");
    }
  }

  async function handleReveal() {
    if (!result) {
      return;
    }
    try {
      await revealDesktopOutput(result.output_path);
      setRevealed(true);
    } catch (caught) {
      setResultOpen(false);
      setError(classifyError(caught));
    }
  }

  const buttonLabel =
    busy === "parsing"
      ? "正在校验两张表…"
      : busy === "generating"
        ? "正在计算并生成…"
        : parseResult
          ? "生成考勤汇总表"
          : "校验并生成汇总表";

  return (
    <div className="application-window">
      <header className="titlebar" aria-label="窗口标题栏" />

      <main>
        <section className="setup-view" aria-busy={isBusy}>
          <div className="intro">
            <h1>生成考勤汇总表</h1>
          </div>

          <div className="file-grid">
            <FileCard
              kind="punch"
              file={punchFile}
              parseResult={parseResult}
              disabled={isBusy}
              isError={error?.fileKind === "punch"}
              onSelect={() => void handleDesktopSelect("punch")}
            />
            <FileCard
              kind="monthly"
              file={monthlyFile}
              parseResult={parseResult}
              disabled={isBusy}
              isError={error?.fileKind === "monthly"}
              onSelect={() => void handleDesktopSelect("monthly")}
            />
          </div>

          <div className="message-slot" aria-live="assertive" aria-atomic="true">
            {error ? (
              <div className="message error-message" role="alert">
                <span className="error-symbol" aria-hidden="true">
                  !
                </span>
                <div className="message-body">
                  <strong>{error.title}</strong>
                  <p>{error.detail}</p>
                </div>
              </div>
            ) : parseResult ? (
              <div className="validation-summary">
                <CheckIcon />
                <span>
                  已校验，{parseResult.detected.matched_employee_count} 名员工可参与汇总
                </span>
              </div>
            ) : null}
          </div>

          <div className="action-zone">
            <button
              className="primary-button generate-button"
              type="button"
              disabled={!ready || isBusy}
              onClick={() => void handleGenerate()}
            >
              {isBusy ? <span className="spinner" aria-hidden="true" /> : null}
              <span>{buttonLabel}</span>
            </button>
          </div>
        </section>
      </main>

      <Modal
        open={differenceOpen}
        labelledBy="difference-title"
        describedBy="difference-description"
        onClose={() => setDifferenceOpen(false)}
      >
        <div className="dialog-body">
          <div className="dialog-title">
            <span className="warning-icon" aria-hidden="true">
              !
            </span>
            <h2 id="difference-title">两张表的人员名单不一致</h2>
          </div>
          <p id="difference-description">
            发现 {differences.length || parseResult?.detected.source_warnings.length || 0}{" "}
            项人员差异。继续生成时，仅汇总两张表中均存在的人员。
          </p>
          <ul className="difference-list">
            {differences.length > 0
              ? differences.map((item) => (
                  <li key={`${item.location}-${item.name}`}>
                    <span>{item.name}</span>
                    <span>{item.location}</span>
                  </li>
                ))
              : parseResult?.detected.source_warnings.map((warning) => (
                  <li key={warning}>
                    <span>{warning}</span>
                  </li>
                ))}
          </ul>
        </div>
        <div className="dialog-actions">
          <button
            className="secondary-button"
            type="button"
            onClick={() => setDifferenceOpen(false)}
          >
            返回更换文件
          </button>
          <button
            className="primary-button"
            type="button"
            onClick={() => void handleContinueWithDifferences()}
          >
            仍然生成
          </button>
        </div>
      </Modal>

      <Modal
        open={resultOpen}
        labelledBy="result-title"
        className="result-dialog"
        onClose={() => setResultOpen(false)}
      >
        <button
          className="result-dialog-close"
          type="button"
          aria-label="关闭生成结果"
          title="关闭"
          onClick={() => setResultOpen(false)}
        />
        <div className="result-panel">
          <span className="success-icon" aria-hidden="true">
            ✓
          </span>
          <div>
            <h2 id="result-title">考勤汇总表已生成</h2>
            <p className="result-description">
              {result
                ? `已汇总 ${result.stats.people} 人、${result.stats.overtime_records} 条加班记录与 ${result.stats.meal_records} 次餐补。`
                : ""}
            </p>
          </div>
          {result ? (
            <div className="output-file" title={result.output_path}>
              <span>输出文件</span>
              <strong>{result.filename}</strong>
            </div>
          ) : null}
          <div className="result-actions">
            <button className="primary-button" type="button" onClick={() => void handleReveal()}>
              {revealed ? <CheckIcon /> : <FolderIcon />}
              <span>{revealed ? "已在文件夹中定位" : "在文件夹中显示"}</span>
            </button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
