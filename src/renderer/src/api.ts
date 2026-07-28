import type {
  DesktopSelection,
  GenerateResponse,
  ParseResponse,
  ValidateResponse
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

export async function validateWorkbook(
  kind: "punch" | "monthly",
  inputPath: string
): Promise<ValidateResponse> {
  return desktopApi().validate(kind, inputPath);
}

export async function generateSummary(
  inputPath: string,
  monthlyPath: string,
  outputPath: string
): Promise<GenerateResponse> {
  return desktopApi().generate(inputPath, monthlyPath, outputPath);
}

export async function selectDesktopOutput(defaultName: string): Promise<string | null> {
  return desktopApi().selectOutput(defaultName);
}

export async function revealDesktopOutput(outputPath: string): Promise<void> {
  await desktopApi().reveal(outputPath);
}
