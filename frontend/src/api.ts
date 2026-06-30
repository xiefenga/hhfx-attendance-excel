import axios from "axios";
import type { AttendanceConfig, GenerateResponse, ParseResponse } from "./types";

export async function parseWorkbook(file: File): Promise<ParseResponse> {
  const form = new FormData();
  form.append("file", file);

  const response = await axios.post<ParseResponse>("/api/parse", form, {
    headers: { "Content-Type": "multipart/form-data" }
  });
  return response.data;
}

export async function generateSummary(
  sourceFileId: string,
  config: AttendanceConfig
): Promise<GenerateResponse> {
  const response = await axios.post<GenerateResponse>("/api/generate", {
    source_file_id: sourceFileId,
    config
  });
  return response.data;
}

export function downloadUrl(fileId: string): string {
  return `/api/download/${fileId}`;
}
