import type { AttendanceDesktopApi } from "../../shared/ipc-contract";

declare global {
  const __APP_VERSION__: string;

  interface Window {
    attendanceDesktop: AttendanceDesktopApi;
  }
}

export {};
