import type { AttendanceDesktopApi } from "../../shared/ipc-contract";

declare global {
  interface Window {
    attendanceDesktop: AttendanceDesktopApi;
  }
}

export {};
