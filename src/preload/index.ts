import { contextBridge, ipcRenderer } from "electron";

import type { AttendanceDesktopApi } from "../shared/ipc-contract";

const attendanceDesktop: AttendanceDesktopApi = {
  hello: () => ipcRenderer.invoke("attendance:hello"),
  selectInput: (kind) => ipcRenderer.invoke("attendance:select-input", kind),
  selectOutput: (defaultName) => ipcRenderer.invoke("attendance:select-output", defaultName),
  parse: (inputPath, monthlyPath) =>
    ipcRenderer.invoke("attendance:parse", inputPath, monthlyPath),
  generate: (inputPath, monthlyPath, outputPath, config) =>
    ipcRenderer.invoke("attendance:generate", inputPath, monthlyPath, outputPath, config),
  reveal: (outputPath) => ipcRenderer.invoke("attendance:reveal", outputPath)
};

contextBridge.exposeInMainWorld("attendanceDesktop", attendanceDesktop);
