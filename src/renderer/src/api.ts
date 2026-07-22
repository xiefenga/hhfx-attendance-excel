import type {
  AttendanceConfig,
  DesktopSelection,
  GenerateResponse,
  ParseResponse
} from "../../shared/ipc-contract";

function desktopApi() {
  return window.attendanceDesktop;
}

export async function selectDesktopWorkbook(): Promise<DesktopSelection | null> {
  return desktopApi().selectInput();
}

export async function parseWorkbook(inputPath: string): Promise<ParseResponse> {
  return desktopApi().parse(inputPath);
}

export async function generateSummary(
  inputPath: string,
  outputPath: string,
  config: AttendanceConfig
): Promise<GenerateResponse> {
  return desktopApi().generate(inputPath, outputPath, config);
}

export async function selectDesktopOutput(defaultName: string): Promise<string | null> {
  return desktopApi().selectOutput(defaultName);
}

export async function revealDesktopOutput(outputPath: string): Promise<void> {
  await desktopApi().reveal(outputPath);
}
