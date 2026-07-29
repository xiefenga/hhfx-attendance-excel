import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";

import type {
  DesktopSelection,
  GenerateResponse,
  ParseResponse,
  ValidateResponse
} from "../../shared/ipc-contract";
import {
  checkForDesktopUpdates,
  generateSummary,
  parseWorkbook,
  revealDesktopOutput,
  selectDesktopOutput,
  selectDesktopWorkbook,
  validateWorkbook
} from "./api";

type FileKind = "punch" | "monthly";
type BusyState = "idle" | "generating";
type ValidationStatus = "idle" | "validating" | "valid" | "error";

interface FileValidation {
  status: ValidationStatus;
  result: ValidateResponse | null;
  error: ErrorState | null;
}

interface ErrorState {
  title: string;
  detail: string;
  suggestion: string;
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
const EMPTY_VALIDATION: FileValidation = {
  status: "idle",
  result: null,
  error: null
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

function RefreshIcon({ className = "" }: { className?: string }) {
  return (
    <svg
      className={className}
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden="true"
    >
      <path
        d="M20 11a8 8 0 1 0-2.34 5.66M20 5v6h-6"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
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

function buildOutputFilename(parsed: ParseResponse): string {
  const { detected } = parsed;
  return `考勤汇总_${compactDate(detected.report_start)}_${compactDate(
    detected.report_end
  )}.xlsx`;
}

function readableDate(value: string): string {
  const [year, month, day] = value.split("-").map(Number);
  return `${year}年${month}月${day}日`;
}

function classifyError(
  caught: unknown,
  fallbackTitle = "无法生成考勤汇总表",
  fileKindHint: FileKind | null = null
): ErrorState {
  const rawDetail =
    caught instanceof Error ? caught.message : "处理失败，请更换文件后重试。";
  let fileKind = fileKindHint;
  const mentionsPunch = rawDetail.includes("打卡时间表");
  const mentionsMonthly = rawDetail.includes("月度汇总表");
  if (mentionsPunch && !mentionsMonthly) {
    fileKind = "punch";
  } else if (mentionsMonthly && !mentionsPunch) {
    fileKind = "monthly";
  } else if (mentionsPunch && mentionsMonthly && fileKindHint === null) {
    fileKind = null;
  }

  let title = fileKind ? `${FILE_LABELS[fileKind]}校验未通过` : fallbackTitle;
  let detail = "应用无法识别这个文件的内容。";
  let suggestion = "请确认选择了正确的钉钉导出文件，然后重新选择。";
  if (
    /not a zip file|BadZipFile|invalid workbook/i.test(rawDetail) ||
    rawDetail.includes("不是有效的 Excel 工作簿")
  ) {
    title = "这个文件无法打开";
    detail = "文件可能已损坏，或者不是由 Excel 生成的工作簿。";
    suggestion = "请从钉钉重新导出 .xlsx 文件后再选择。";
  } else if (/permission denied|无法访问|文件不存在/i.test(rawDetail)) {
    title = "找不到这个文件";
    detail = "文件可能已被移动、删除，或者当前无法访问。";
    suggestion = "请确认文件可以正常打开，然后重新选择。";
  } else if (rawDetail.includes("缺少钉钉 UserId")) {
    const employee = rawDetail.match(/员工“([^”]+)”/)?.[1];
    title = "员工信息不完整";
    detail = employee
      ? `员工“${employee}”缺少用于匹配两张表的 UserId。`
      : "有员工缺少用于匹配两张表的 UserId。";
    suggestion = "请从钉钉重新导出包含完整员工信息的考勤表。";
  } else if (rawDetail.includes("重复钉钉 UserId")) {
    const duplicateUserId = rawDetail.match(/UserId：(.+)$/)?.[1];
    title = "员工信息有重复";
    detail = duplicateUserId
      ? `UserId“${duplicateUserId}”在表中出现了多次，无法准确匹配人员。`
      : "表中有多名员工使用了同一个 UserId，无法准确匹配人员。";
    suggestion = "请检查重复的员工记录，修正后重新选择文件。";
  } else if (rawDetail.includes("统计日期范围不一致")) {
    const ranges = [
      ...rawDetail.matchAll(/(\d{4}-\d{2}-\d{2}) 至 (\d{4}-\d{2}-\d{2})/g)
    ];
    title = "两张表的统计日期不一致";
    detail =
      ranges.length >= 2
        ? `打卡时间表是 ${readableDate(ranges[0][1])} 至 ${readableDate(
            ranges[0][2]
          )}，月度汇总表是 ${readableDate(ranges[1][1])} 至 ${readableDate(
            ranges[1][2]
          )}。`
        : "两张表的统计开始日期或结束日期不同。";
    suggestion = "请选择统计周期完全相同的两张表。";
  } else if (rawDetail.includes("标题中未找到完整统计日期范围")) {
    title = "找不到统计日期";
    detail = "表格标题中没有可识别的开始日期和结束日期。";
    suggestion = `请确认选择的是钉钉导出的${fileKind ? FILE_LABELS[fileKind] : "考勤表"}，且没有修改标题。`;
  } else if (rawDetail.includes("统计结束日期早于开始日期")) {
    title = "统计日期顺序不正确";
    detail = "表格中的结束日期早于开始日期。";
    suggestion = "请检查导出时选择的日期范围，然后重新导出。";
  } else if (rawDetail.includes("未找到“考勤结果”每日明细")) {
    title = "找不到每日考勤结果";
    detail = "月度汇总表中没有找到每天的考勤结果区域。";
    suggestion = "请确认选择的是钉钉导出的月度汇总表，且没有删除或移动表头。";
  } else if (
    rawDetail.includes("每日打卡列少于") ||
    rawDetail.includes("每日考勤结果列少于")
  ) {
    title = "每日数据不完整";
    detail = "表格中的每日数据列少于本次统计周期应有的天数。";
    suggestion = "请使用未经删减的钉钉原始导出文件。";
  } else if (rawDetail.includes("输出文件不能覆盖")) {
    title = "不能覆盖原始文件";
    detail = "保存位置与其中一张原始考勤表相同。";
    suggestion = "请选择其他文件名或保存位置。";
  } else if (rawDetail.includes("操作超时")) {
    title = "处理时间过长";
    detail = "应用未能在规定时间内完成处理。";
    suggestion = "请关闭占用该文件的 Excel 窗口后重试。";
  }

  return {
    title,
    detail,
    suggestion,
    fileKind
  };
}

function FileCard({
  kind,
  file,
  validation,
  disabled,
  isError,
  onSelect
}: {
  kind: FileKind;
  file: DesktopSelection | null;
  validation: FileValidation;
  disabled: boolean;
  isError: boolean;
  onSelect(): void;
}) {
  const label = FILE_LABELS[kind];
  const employeeCount = validation.result?.employee_count ?? null;

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
            {validation.error ? (
              <span className="file-error-icon" aria-hidden="true">
                !
              </span>
            ) : (
              <CheckIcon className="selected-check" />
            )}
            <div className="selected-file-copy">
              <span className="file-name" title={file.name}>
                {file.name}
              </span>
              {validation.error ? (
                <div
                  className="file-validation-error"
                >
                  <strong>{validation.error.title}</strong>
                  <span>{validation.error.detail}</span>
                  <span className="file-error-suggestion">
                    {validation.error.suggestion}
                  </span>
                </div>
              ) : (
                <span className="file-meta">
                  {validation.status === "validating"
                    ? `${formatFileSize(file.size)} · 正在校验…`
                    : employeeCount === null
                      ? `${formatFileSize(file.size)} · 等待校验`
                      : `已校验 · ${employeeCount} 人`}
                </span>
              )}
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
  const [punchValidation, setPunchValidation] =
    useState<FileValidation>(EMPTY_VALIDATION);
  const [monthlyValidation, setMonthlyValidation] =
    useState<FileValidation>(EMPTY_VALIDATION);
  const [crossChecking, setCrossChecking] = useState(false);
  const [result, setResult] = useState<GenerateResponse | null>(null);
  const [error, setError] = useState<ErrorState | null>(null);
  const [differenceOpen, setDifferenceOpen] = useState(false);
  const [resultOpen, setResultOpen] = useState(false);
  const [revealed, setRevealed] = useState(false);
  const [checkingForUpdates, setCheckingForUpdates] = useState(false);
  const validationVersions = useRef<Record<FileKind, number>>({
    punch: 0,
    monthly: 0
  });

  const ready = punchFile !== null && monthlyFile !== null;
  const filesValidated =
    punchValidation.status === "valid" && monthlyValidation.status === "valid";
  const isBusy =
    busy !== "idle" ||
    crossChecking ||
    punchValidation.status === "validating" ||
    monthlyValidation.status === "validating";
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

  useEffect(() => {
    if (!punchFile || !monthlyFile || !filesValidated) {
      return;
    }

    let active = true;
    setParseResult(null);
    setError(null);
    setCrossChecking(true);

    void parseWorkbook(punchFile.path, monthlyFile.path)
      .then((parsed) => {
        if (active) {
          setParseResult(parsed);
        }
      })
      .catch((caught: unknown) => {
        if (active) {
          setError(classifyError(caught, "文件校验未通过"));
        }
      })
      .finally(() => {
        if (active) {
          setCrossChecking(false);
        }
      });

    return () => {
      active = false;
    };
  }, [filesValidated, monthlyFile, punchFile]);

  async function handleDesktopSelect(kind: FileKind) {
    try {
      const selected = await selectDesktopWorkbook(kind);
      if (!selected) {
        return;
      }
      const version = validationVersions.current[kind] + 1;
      validationVersions.current[kind] = version;
      const setValidation =
        kind === "punch" ? setPunchValidation : setMonthlyValidation;
      if (kind === "punch") {
        setPunchFile(selected);
      } else {
        setMonthlyFile(selected);
      }
      setValidation({ status: "validating", result: null, error: null });
      setParseResult(null);
      setResult(null);
      setError(null);
      setRevealed(false);
      setDifferenceOpen(false);
      setResultOpen(false);
      try {
        const validated = await validateWorkbook(kind, selected.path);
        if (validationVersions.current[kind] === version) {
          setValidation({ status: "valid", result: validated, error: null });
        }
      } catch (caught) {
        if (validationVersions.current[kind] === version) {
          setValidation({
            status: "error",
            result: null,
            error: classifyError(caught, "文件校验未通过", kind)
          });
        }
      }
    } catch (caught) {
      setError(classifyError(caught));
    }
  }

  async function generateFromParsed(parsed: ParseResponse) {
    if (!punchFile || !monthlyFile) {
      return;
    }
    const outputPath = await selectDesktopOutput(buildOutputFilename(parsed));
    if (!outputPath) {
      return;
    }
    setBusy("generating");
    const generated = await generateSummary(
      punchFile.path,
      monthlyFile.path,
      outputPath
    );
    setResult(generated);
    setResultOpen(true);
    setRevealed(false);
  }

  async function handleGenerate() {
    if (!punchFile || !monthlyFile || !parseResult || isBusy) {
      return;
    }
    setError(null);
    try {
      const parsed = parseResult;
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

  async function handleCheckForUpdates() {
    if (checkingForUpdates) {
      return;
    }
    setCheckingForUpdates(true);
    try {
      await checkForDesktopUpdates();
    } finally {
      setCheckingForUpdates(false);
    }
  }

  const buttonLabel =
    busy === "generating"
        ? "正在计算并生成…"
        : punchValidation.status === "validating" ||
            monthlyValidation.status === "validating"
          ? "正在校验文件…"
          : crossChecking
            ? "正在核对两张表…"
        : parseResult
          ? "生成考勤汇总表"
          : error && ready
            ? "校验未通过，请更换文件"
            : "选择两张表后自动校验";

  return (
    <div className="application-window">
      <header className="titlebar" aria-label="窗口标题栏" />

      <main>
        <section className="setup-view" aria-busy={isBusy}>
          <div className="intro">
            <h1>生成考勤汇总表</h1>
            <button
              className="secondary-button update-button"
              type="button"
              disabled={checkingForUpdates || isBusy}
              onClick={() => void handleCheckForUpdates()}
            >
              <RefreshIcon className={checkingForUpdates ? "is-spinning" : ""} />
              <span>{checkingForUpdates ? "正在检查…" : "检查更新"}</span>
            </button>
          </div>

          <div className="file-grid">
            <FileCard
              kind="punch"
              file={punchFile}
              validation={punchValidation}
              disabled={busy === "generating"}
              isError={punchValidation.status === "error"}
              onSelect={() => void handleDesktopSelect("punch")}
            />
            <FileCard
              kind="monthly"
              file={monthlyFile}
              validation={monthlyValidation}
              disabled={busy === "generating"}
              isError={monthlyValidation.status === "error"}
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
                  <span className="error-suggestion">{error.suggestion}</span>
                </div>
              </div>
            ) : parseResult ? (
              <div className="validation-summary">
                <CheckIcon />
                <span>
                  已校验，打卡时间表 {parseResult.detected.employee_count} 人，月度汇总表{" "}
                  {parseResult.detected.monthly_employee_count} 人
                </span>
              </div>
            ) : null}
          </div>

          <div className="action-zone">
            <button
              className="primary-button generate-button"
              type="button"
              disabled={!ready || !filesValidated || !parseResult || isBusy}
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
            <h2 id="difference-title">部分员工只存在于其中一张表</h2>
          </div>
          <p id="difference-description">
            发现 {differences.length || parseResult?.detected.source_warnings.length || 0}{" "}
            名员工只存在于其中一张表。继续生成后，汇总表仍会包含两张表中的全部员工：仅在打卡时间表中的员工保留加班、餐补等计算结果；仅在月度汇总表中的员工保留每日考勤和请假信息；两张表中的同一员工将通过 UserId 合并。
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
                ? `已汇总 ${result.stats.people} 人（按两张表人员并集）、${result.stats.overtime_records} 条加班记录与 ${result.stats.meal_records} 次餐补。`
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
