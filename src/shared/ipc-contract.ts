export interface AttendanceConfig {
  start_date: string;
  end_date: string;
  ignore_dates: string[];
  overnight_cutoff: string;
  work_start_time: string;
  work_end_time: string;
  overtime_start_time: string;
  workday_overtime_2h_after: string;
  workday_meal_after: string;
  meal_allowance_amount: number;
  output_filename: string;
}

export interface SummaryStats {
  people: number;
  detail_records: number;
  overtime_records: number;
  absence_records: number;
  late_records: number;
  meal_records: number;
  total_overtime_hours: number;
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
  suggested_start_date: string;
  suggested_end_date: string;
  suggested_ignore_dates: string[];
  holidays: ParsedHoliday[];
  weekend_dates: string[];
  non_workdays: ParsedNonWorkday[];
  employee_count: number;
  date_count: number;
}

export interface ParseResponse {
  filename: string;
  source_path: string;
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
}

export interface AttendanceDesktopApi {
  hello(): Promise<WorkerHello>;
  selectInput(): Promise<DesktopSelection | null>;
  selectOutput(defaultName: string): Promise<string | null>;
  parse(inputPath: string): Promise<ParseResponse>;
  generate(
    inputPath: string,
    outputPath: string,
    config: AttendanceConfig
  ): Promise<GenerateResponse>;
  reveal(outputPath: string): Promise<void>;
}
