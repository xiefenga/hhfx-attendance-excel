import { contextBridge, ipcRenderer } from "electron";

import type { AttendanceDesktopApi } from "../shared/ipc-contract";

const attendanceDesktop: AttendanceDesktopApi = {
  hello: () => ipcRenderer.invoke("attendance:hello"),
  selectInput: (kind) => ipcRenderer.invoke("attendance:select-input", kind),
  selectOutput: (defaultName) => ipcRenderer.invoke("attendance:select-output", defaultName),
  validate: (kind, inputPath) =>
    ipcRenderer.invoke("attendance:validate", kind, inputPath),
  parse: (inputPath, monthlyPath) =>
    ipcRenderer.invoke("attendance:parse", inputPath, monthlyPath),
  generate: (inputPath, monthlyPath, outputPath) =>
    ipcRenderer.invoke("attendance:generate", inputPath, monthlyPath, outputPath),
  reveal: (outputPath) => ipcRenderer.invoke("attendance:reveal", outputPath)
};

contextBridge.exposeInMainWorld("attendanceDesktop", attendanceDesktop);
