import type {
  AttendanceConfig,
  DesktopSelection,
  GenerateResponse,
  ParseResponse
} from "../../shared/ipc-contract";

function desktopApi() {
  return window.attendanceDesktop;
}

export async function selectDesktopWorkbook(
  kind: "punch" | "monthly"
): Promise<DesktopSelection | null> {
  return desktopApi().selectInput(kind);
}

export async function parseWorkbook(
  inputPath: string,
  monthlyPath: string
): Promise<ParseResponse> {
  return desktopApi().parse(inputPath, monthlyPath);
}

export async function generateSummary(
  inputPath: string,
  monthlyPath: string,
  outputPath: string,
  config: AttendanceConfig
): Promise<GenerateResponse> {
  return desktopApi().generate(inputPath, monthlyPath, outputPath, config);
}

export async function selectDesktopOutput(defaultName: string): Promise<string | null> {
  return desktopApi().selectOutput(defaultName);
}

export async function revealDesktopOutput(outputPath: string): Promise<void> {
  await desktopApi().reveal(outputPath);
}
