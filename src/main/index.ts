import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { app, BrowserWindow, dialog, ipcMain, shell } from "electron";
import squirrelStartup from "electron-squirrel-startup";

import type { WorkerHello } from "../shared/ipc-contract";

const REQUEST_TIMEOUT_MS = 120_000;
const UPDATE_CHECK_INTERVAL_MS = 60 * 60 * 1000;
const UPDATE_MANIFEST_URL =
  "https://gitee.com/xf_wwx/attendance-ledger-updates/raw/master/win32/x64/update.json";
const UPDATE_ASSET_PATH_PREFIX =
  "/xf_wwx/attendance-ledger-updates/attach_files/";

interface UpdatePart {
  url: string;
  size: number;
}

interface UpdateManifest {
  version: string;
  sha256: string;
  size: number;
  parts: UpdatePart[];
}

interface WorkerResponse {
  request_id?: string;
  ok: boolean;
  result?: unknown;
  error?: {
    code?: string;
    message?: string;
  };
}

interface PendingRequest {
  resolve(value: unknown): void;
  reject(reason: unknown): void;
  timeout: NodeJS.Timeout;
}

let mainWindow: BrowserWindow | null = null;
let worker: ChildProcessWithoutNullStreams | null = null;
let workerReady: Promise<WorkerHello> | null = null;
let updateInProgress = false;
const pending = new Map<string, PendingRequest>();

function workerCommand(): { command: string; args: string[]; cwd?: string } {
  if (app.isPackaged) {
    const executable = process.platform === "win32" ? "attendance-worker.exe" : "attendance-worker";
    return {
      command: path.join(process.resourcesPath, "attendance-worker", executable),
      args: []
    };
  }

  if (process.env.ATTENDANCE_WORKER_PATH) {
    return { command: process.env.ATTENDANCE_WORKER_PATH, args: [] };
  }

  const projectRoot = path.resolve(__dirname, "../..");
  const virtualEnvPython = process.platform === "win32"
    ? path.join(projectRoot, ".venv", "Scripts", "python.exe")
    : path.join(projectRoot, ".venv", "bin", "python");
  return {
    command: fs.existsSync(virtualEnvPython) ? virtualEnvPython : "python3",
    args: ["-m", "attendance_sidecar.main"],
    cwd: projectRoot
  };
}

function rejectAllPending(error: Error): void {
  for (const item of pending.values()) {
    clearTimeout(item.timeout);
    item.reject(error);
  }
  pending.clear();
}

function startWorker(): void {
  if (worker && !worker.killed) {
    return;
  }

  const launch = workerCommand();
  const child = spawn(launch.command, launch.args, {
    cwd: launch.cwd,
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true
  });
  worker = child;

  const lines = readline.createInterface({ input: child.stdout });
  lines.on("line", (line) => {
    let response: WorkerResponse;
    try {
      response = JSON.parse(line) as WorkerResponse;
    } catch (error) {
      console.error("Python worker returned invalid JSON", line, error);
      return;
    }

    if (!response.request_id) {
      return;
    }
    const item = pending.get(response.request_id);
    if (!item) {
      return;
    }
    clearTimeout(item.timeout);
    pending.delete(response.request_id);
    if (response.ok) {
      item.resolve(response.result);
    } else {
      const error = new Error(response.error?.message || "Python worker 处理失败") as Error & {
        code?: string;
      };
      error.code = response.error?.code;
      item.reject(error);
    }
  });

  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (data: string) => console.error(`[python] ${data.trimEnd()}`));
  child.on("error", (error) => rejectAllPending(error));
  child.on("exit", (code, signal) => {
    rejectAllPending(new Error(`Python worker 已退出（code=${code}, signal=${signal}）`));
    worker = null;
    workerReady = null;
  });
}

function requestWorker<T>(method: string, payload: Record<string, unknown> = {}): Promise<T> {
  startWorker();
  const child = worker;
  if (!child) {
    return Promise.reject(new Error("Python worker 启动失败"));
  }

  return new Promise<T>((resolve, reject) => {
    const requestId = crypto.randomUUID();
    const timeout = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error(`操作超时：${method}`));
    }, REQUEST_TIMEOUT_MS);
    pending.set(requestId, {
      resolve: (value) => resolve(value as T),
      reject,
      timeout
    });
    child.stdin.write(`${JSON.stringify({ request_id: requestId, method, payload })}\n`);
  });
}

async function ensureWorker(): Promise<WorkerHello> {
  if (!workerReady) {
    workerReady = requestWorker<WorkerHello>("hello").then((result) => {
      if (result.protocol_version !== 2) {
        throw new Error(`不支持的 Python worker 协议版本：${result.protocol_version}`);
      }
      return result;
    });
  }
  return workerReady;
}

async function createWindow(): Promise<void> {
  mainWindow = new BrowserWindow({
    width: 1000,
    height: 760,
    minWidth: 760,
    minHeight: 640,
    show: false,
    title: "Attendance Ledger",
    backgroundColor: "#fdf3ec",
    titleBarStyle: "hidden",
    titleBarOverlay: {
      color: "#fffaf7",
      symbolColor: "#73737b",
      height: 44
    },
    webPreferences: {
      preload: path.join(__dirname, "../preload/index.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });

  mainWindow.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  mainWindow.webContents.on("will-navigate", (event) => event.preventDefault());
  mainWindow.once("ready-to-show", () => mainWindow?.show());

  if (!app.isPackaged && process.env.ELECTRON_RENDERER_URL) {
    await mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL);
  } else {
    await mainWindow.loadFile(path.join(__dirname, "../renderer/index.html"));
  }
}

function registerIpc(): void {
  ipcMain.handle("attendance:hello", async () => ensureWorker());
  ipcMain.handle("attendance:select-input", async (_event, kind: "punch" | "monthly") => {
    const options: Electron.OpenDialogOptions = {
      title: kind === "monthly" ? "选择钉钉月度汇总表" : "选择钉钉打卡时间表",
      properties: ["openFile"],
      filters: [{ name: "Excel 工作簿", extensions: ["xlsx"] }]
    };
    const result = mainWindow
      ? await dialog.showOpenDialog(mainWindow, options)
      : await dialog.showOpenDialog(options);
    if (result.canceled || result.filePaths.length === 0) {
      return null;
    }
    const selectedPath = result.filePaths[0];
    const selectedStats = await fs.promises.stat(selectedPath);
    return { path: selectedPath, name: path.basename(selectedPath), size: selectedStats.size };
  });
  ipcMain.handle("attendance:select-output", async (_event, defaultName: string) => {
    const options: Electron.SaveDialogOptions = {
      title: "保存考勤汇总表",
      defaultPath: defaultName,
      filters: [{ name: "Excel 工作簿", extensions: ["xlsx"] }]
    };
    const result = mainWindow
      ? await dialog.showSaveDialog(mainWindow, options)
      : await dialog.showSaveDialog(options);
    return result.canceled ? null : result.filePath;
  });
  ipcMain.handle(
    "attendance:validate",
    async (_event, kind: "punch" | "monthly", inputPath: string) => {
      await ensureWorker();
      return requestWorker("validate", { kind, input_path: inputPath });
    }
  );
  ipcMain.handle("attendance:parse", async (_event, inputPath: string, monthlyPath: string) => {
    await ensureWorker();
    return requestWorker("parse", { input_path: inputPath, monthly_path: monthlyPath });
  });
  ipcMain.handle(
    "attendance:generate",
    async (
      _event,
      inputPath: string,
      monthlyPath: string,
      outputPath: string
    ) => {
      await ensureWorker();
      return requestWorker("generate", {
        input_path: inputPath,
        monthly_path: monthlyPath,
        output_path: outputPath
      });
    }
  );
  ipcMain.handle("attendance:reveal", async (_event, outputPath: string) => {
    shell.showItemInFolder(outputPath);
  });
}

function isUpdateManifest(value: unknown): value is UpdateManifest {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const manifest = value as Record<string, unknown>;
  if (
    typeof manifest.version !== "string" ||
    !/^\d+\.\d+\.\d+$/.test(manifest.version) ||
    typeof manifest.sha256 !== "string" ||
    !/^[a-f0-9]{64}$/i.test(manifest.sha256) ||
    typeof manifest.size !== "number" ||
    !Number.isSafeInteger(manifest.size) ||
    manifest.size <= 0 ||
    !Array.isArray(manifest.parts) ||
    manifest.parts.length === 0
  ) {
    return false;
  }
  return manifest.parts.every((part) => {
    if (typeof part !== "object" || part === null) {
      return false;
    }
    const candidate = part as Record<string, unknown>;
    if (
      typeof candidate.url !== "string" ||
      typeof candidate.size !== "number" ||
      !Number.isSafeInteger(candidate.size) ||
      candidate.size <= 0
    ) {
      return false;
    }
    try {
      const url = new URL(candidate.url);
      return (
        url.protocol === "https:" &&
        url.hostname === "gitee.com" &&
        url.pathname.startsWith(UPDATE_ASSET_PATH_PREFIX)
      );
    } catch {
      return false;
    }
  });
}

function isNewerVersion(candidate: string, current: string): boolean {
  const candidateParts = candidate.split(".").map(Number);
  const currentParts = current.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (candidateParts[index] !== currentParts[index]) {
      return candidateParts[index] > currentParts[index];
    }
  }
  return false;
}

async function calculateSha256(filePath: string): Promise<string> {
  const hash = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(filePath)) {
    hash.update(chunk);
  }
  return hash.digest("hex");
}

async function downloadUpdate(manifest: UpdateManifest): Promise<string> {
  const updateDirectory = path.join(
    app.getPath("temp"),
    "attendance-ledger-updates",
    manifest.version
  );
  const partialPath = path.join(updateDirectory, "Attendance Ledger Setup.exe.part");
  const installerPath = path.join(updateDirectory, "Attendance Ledger Setup.exe");
  await fs.promises.mkdir(updateDirectory, { recursive: true });
  await fs.promises.writeFile(partialPath, new Uint8Array());

  let downloadedSize = 0;
  for (const [index, part] of manifest.parts.entries()) {
    const response = await fetch(part.url, {
      redirect: "follow",
      signal: AbortSignal.timeout(10 * 60 * 1000)
    });
    if (!response.ok) {
      throw new Error(`更新分片下载失败：HTTP ${response.status}`);
    }
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength !== part.size) {
      throw new Error(
        `更新分片大小不匹配：预期 ${part.size}，实际 ${bytes.byteLength}`
      );
    }
    await fs.promises.appendFile(partialPath, bytes);
    downloadedSize += bytes.byteLength;
    mainWindow?.setProgressBar((index + 1) / manifest.parts.length);
  }

  if (downloadedSize !== manifest.size) {
    throw new Error(`更新文件大小不匹配：预期 ${manifest.size}，实际 ${downloadedSize}`);
  }
  const actualSha256 = await calculateSha256(partialPath);
  if (actualSha256.toLowerCase() !== manifest.sha256.toLowerCase()) {
    throw new Error("更新文件 SHA-256 校验失败");
  }
  await fs.promises.rm(installerPath, { force: true });
  await fs.promises.rename(partialPath, installerPath);
  return installerPath;
}

async function checkForUpdates(): Promise<void> {
  if (updateInProgress) {
    return;
  }
  updateInProgress = true;
  try {
    const response = await fetch(UPDATE_MANIFEST_URL, {
      cache: "no-store",
      redirect: "follow",
      signal: AbortSignal.timeout(30_000)
    });
    if (response.status === 404) {
      return;
    }
    if (!response.ok) {
      throw new Error(`更新清单请求失败：HTTP ${response.status}`);
    }
    const value: unknown = await response.json();
    if (!isUpdateManifest(value)) {
      throw new Error("更新清单格式无效");
    }
    if (!isNewerVersion(value.version, app.getVersion())) {
      return;
    }

    const prompt = mainWindow
      ? await dialog.showMessageBox(mainWindow, {
          type: "info",
          title: "发现新版本",
          message: `发现新版本 v${value.version}`,
          detail: "是否现在下载更新？下载完成后可立即安装。",
          buttons: ["下载更新", "稍后"],
          defaultId: 0,
          cancelId: 1,
          noLink: true
        })
      : await dialog.showMessageBox({
          type: "info",
          title: "发现新版本",
          message: `发现新版本 v${value.version}`,
          detail: "是否现在下载更新？下载完成后可立即安装。",
          buttons: ["下载更新", "稍后"],
          defaultId: 0,
          cancelId: 1,
          noLink: true
        });
    if (prompt.response !== 0) {
      return;
    }

    const installerPath = await downloadUpdate(value);
    mainWindow?.setProgressBar(-1);
    const ready = mainWindow
      ? await dialog.showMessageBox(mainWindow, {
          type: "info",
          title: "更新已下载",
          message: `Attendance Ledger v${value.version} 已下载完成`,
          detail: "立即退出应用并安装新版本？",
          buttons: ["立即安装", "稍后"],
          defaultId: 0,
          cancelId: 1,
          noLink: true
        })
      : await dialog.showMessageBox({
          type: "info",
          title: "更新已下载",
          message: `Attendance Ledger v${value.version} 已下载完成`,
          detail: "立即退出应用并安装新版本？",
          buttons: ["立即安装", "稍后"],
          defaultId: 0,
          cancelId: 1,
          noLink: true
        });
    if (ready.response === 0) {
      spawn(installerPath, ["--silent"], {
        detached: true,
        stdio: "ignore",
        windowsHide: false
      }).unref();
      app.quit();
    }
  } catch (error) {
    mainWindow?.setProgressBar(-1);
    console.error("自动更新失败", error);
  } finally {
    updateInProgress = false;
  }
}

function startAutoUpdates(): void {
  if (!app.isPackaged || process.platform !== "win32") {
    return;
  }

  const start = (): void => {
    checkForUpdates().catch((error) => console.error("自动更新检查失败", error));
    const timer = setInterval(() => {
      checkForUpdates().catch((error) => console.error("自动更新检查失败", error));
    }, UPDATE_CHECK_INTERVAL_MS);
    timer.unref();
  };

  if (process.argv.includes("--squirrel-firstrun")) {
    setTimeout(start, 10_000);
  } else {
    start();
  }
}

if (squirrelStartup) {
  app.quit();
} else {
  const gotLock = app.requestSingleInstanceLock();
  if (!gotLock) {
    app.quit();
  } else {
    app.on("second-instance", () => {
      if (mainWindow) {
        if (mainWindow.isMinimized()) mainWindow.restore();
        mainWindow.focus();
      }
    });
    app.whenReady().then(async () => {
      registerIpc();
      await createWindow();
      ensureWorker().catch((error) => console.error("Python worker failed to start", error));
      startAutoUpdates();
    });
    app.on("activate", () => {
      if (BrowserWindow.getAllWindows().length === 0) {
        createWindow().catch((error) => console.error("Failed to create window", error));
      }
    });
    app.on("window-all-closed", () => {
      if (process.platform !== "darwin") app.quit();
    });
    app.on("before-quit", () => {
      if (worker && !worker.killed) worker.kill();
    });
  }
}
