import { contextBridge, ipcRenderer } from "electron";

import type { AttendanceDesktopApi } from "../shared/ipc-contract";

const attendanceDesktop: AttendanceDesktopApi = {
  hello: () => ipcRenderer.invoke("attendance:hello"),
  selectInput: () => ipcRenderer.invoke("attendance:select-input"),
  selectOutput: (defaultName) => ipcRenderer.invoke("attendance:select-output", defaultName),
  parse: (inputPath) => ipcRenderer.invoke("attendance:parse", inputPath),
  generate: (inputPath, outputPath, config) =>
    ipcRenderer.invoke("attendance:generate", inputPath, outputPath, config),
  reveal: (outputPath) => ipcRenderer.invoke("attendance:reveal", outputPath)
};

contextBridge.exposeInMainWorld("attendanceDesktop", attendanceDesktop);
