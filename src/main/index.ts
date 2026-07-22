import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { app, BrowserWindow, dialog, ipcMain, shell } from "electron";

import type { WorkerHello } from "../shared/ipc-contract";

const REQUEST_TIMEOUT_MS = 120_000;

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
      if (result.protocol_version !== 1) {
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
    title: "考勤汇总工具",
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
  ipcMain.handle("attendance:select-input", async () => {
    const options: Electron.OpenDialogOptions = {
      title: "选择原始考勤表",
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
    return { path: selectedPath, name: path.basename(selectedPath) };
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
  ipcMain.handle("attendance:parse", async (_event, inputPath: string) => {
    await ensureWorker();
    return requestWorker("parse", { input_path: inputPath });
  });
  ipcMain.handle(
    "attendance:generate",
    async (_event, inputPath: string, outputPath: string, config: Record<string, unknown>) => {
      await ensureWorker();
      return requestWorker("generate", {
        input_path: inputPath,
        output_path: outputPath,
        config
      });
    }
  );
  ipcMain.handle("attendance:reveal", async (_event, outputPath: string) => {
    shell.showItemInFolder(outputPath);
  });
}

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
