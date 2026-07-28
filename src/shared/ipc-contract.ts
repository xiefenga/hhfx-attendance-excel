export interface SummaryStats {
  people: number;
  detail_records: number;
  overtime_records: number;
  absence_records: number;
  late_records: number;
  meal_records: number;
  total_overtime_hours: number;
  total_holiday_overtime_days: number;
  total_meal_amount: number;
}

export interface ParsedHoliday {
  date: string;
  label: string;
}

export interface ParsedNonWorkday {
  date: string;
  label: string;
}

export interface ParsedWorkbook {
  report_start: string;
  report_end: string;
  holidays: ParsedHoliday[];
  weekend_dates: string[];
  non_workdays: ParsedNonWorkday[];
  employee_count: number;
  date_count: number;
  monthly_employee_count: number;
  matched_employee_count: number;
  punch_only_employees: string[];
  monthly_only_employees: string[];
  source_warnings: string[];
}

export interface ParseResponse {
  filename: string;
  source_path: string;
  monthly_filename: string;
  monthly_source_path: string;
  detected: ParsedWorkbook;
}

export interface GenerateResponse {
  filename: string;
  output_path: string;
  stats: SummaryStats;
}

export interface WorkerHello {
  protocol_version: number;
  worker_version: string;
}

export interface DesktopSelection {
  path: string;
  name: string;
  size: number;
}

export interface AttendanceDesktopApi {
  hello(): Promise<WorkerHello>;
  selectInput(kind: "punch" | "monthly"): Promise<DesktopSelection | null>;
  selectOutput(defaultName: string): Promise<string | null>;
  parse(inputPath: string, monthlyPath: string): Promise<ParseResponse>;
  generate(
    inputPath: string,
    monthlyPath: string,
    outputPath: string
  ): Promise<GenerateResponse>;
  reveal(outputPath: string): Promise<void>;
}
