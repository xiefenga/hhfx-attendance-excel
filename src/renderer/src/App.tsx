import {
  DownloadOutlined,
  FileExcelOutlined,
  PlayCircleOutlined,
  SearchOutlined
} from "@ant-design/icons";
import {
  Alert,
  Button,
  Card,
  ConfigProvider,
  DatePicker,
  Form,
  InputNumber,
  Layout,
  Result,
  Space,
  Steps,
  Tag,
  TimePicker,
  Typography
} from "antd";
import zhCN from "antd/locale/zh_CN";
import dayjs, { Dayjs } from "dayjs";
import "dayjs/locale/zh-cn";
import { useMemo, useState } from "react";
import {
  generateSummary,
  parseWorkbook,
  revealDesktopOutput,
  selectDesktopOutput,
  selectDesktopWorkbook
} from "./api";
import type {
  AttendanceConfig,
  GenerateResponse,
  ParseResponse
} from "../../shared/ipc-contract";

const { Content } = Layout;
const { RangePicker } = DatePicker;
dayjs.locale("zh-cn");

interface FormValues {
  dateRange: [Dayjs, Dayjs];
  ignoreDates?: Dayjs[];
  overnight_cutoff: Dayjs;
  work_start_time: Dayjs;
  work_end_time: Dayjs;
  overtime_start_time: Dayjs;
  workday_overtime_2h_after: Dayjs;
  workday_meal_after: Dayjs;
  meal_allowance_amount: number;
}

const defaultValues: FormValues = {
  dateRange: [dayjs("2026-06-01"), dayjs("2026-06-29")],
  ignoreDates: [],
  overnight_cutoff: dayjs("07:00", "HH:mm"),
  work_start_time: dayjs("08:30", "HH:mm"),
  work_end_time: dayjs("18:00", "HH:mm"),
  overtime_start_time: dayjs("19:00", "HH:mm"),
  workday_overtime_2h_after: dayjs("21:00", "HH:mm"),
  workday_meal_after: dayjs("22:00", "HH:mm"),
  meal_allowance_amount: 30
};

function toDateStrings(values?: Dayjs[]): string[] {
  return (values ?? []).map((value) => value.format("YYYY-MM-DD"));
}

function buildConfig(values: FormValues): AttendanceConfig {
  const [start, end] = values.dateRange;
  const allIgnoreDates = [...toDateStrings(values.ignoreDates)];

  return {
    start_date: start.format("YYYY-MM-DD"),
    end_date: end.format("YYYY-MM-DD"),
    ignore_dates: allIgnoreDates,
    overnight_cutoff: values.overnight_cutoff.format("HH:mm:ss"),
    work_start_time: values.work_start_time.format("HH:mm:ss"),
    work_end_time: values.work_end_time.format("HH:mm:ss"),
    overtime_start_time: values.overtime_start_time.format("HH:mm:ss"),
    workday_overtime_2h_after: values.workday_overtime_2h_after.format("HH:mm:ss"),
    workday_meal_after: values.workday_meal_after.format("HH:mm:ss"),
    meal_allowance_amount: values.meal_allowance_amount,
    output_filename: `考勤加班汇总_${start.format("YYYYMMDD")}_${end.format("YYYYMMDD")}.xlsx`
  };
}

export default function App() {
  const [form] = Form.useForm<FormValues>();
  const [desktopFile, setDesktopFile] = useState<{ path: string; name: string } | null>(null);
  const [parsing, setParsing] = useState(false);
  const [generating, setGenerating] = useState(false);
  const [parseResult, setParseResult] = useState<ParseResponse | null>(null);
  const [result, setResult] = useState<GenerateResponse | null>(null);
  const [error, setError] = useState<string | null>(null);

  const currentStep = result ? 2 : parseResult ? 1 : 0;
  const canParse = useMemo(
    () => desktopFile !== null && !parsing,
    [desktopFile, parsing]
  );
  const canGenerate = useMemo(
    () => parseResult !== null && !generating,
    [parseResult, generating]
  );

  async function handleParse() {
    if (!desktopFile) {
      setError("请先选择考勤 Excel 文件");
      return;
    }
    setError(null);
    setParsing(true);
    setResult(null);
    try {
      const response = await parseWorkbook(desktopFile.path);
      setParseResult(response);
      form.setFieldsValue({
        dateRange: [
          dayjs(response.detected.suggested_start_date),
          dayjs(response.detected.suggested_end_date)
        ],
        ignoreDates: response.detected.suggested_ignore_dates.map((value) => dayjs(value))
      });
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : "解析失败";
      setError(message);
    } finally {
      setParsing(false);
    }
  }

  async function handleGenerate() {
    if (!parseResult || !desktopFile) {
      setError("请先解析考勤 Excel 文件");
      return;
    }
    try {
      const values = await form.validateFields();
      const config = buildConfig(values);
      const outputPath = await selectDesktopOutput(config.output_filename);
      if (!outputPath) {
        return;
      }
      setError(null);
      setGenerating(true);
      const response = await generateSummary(desktopFile.path, outputPath, config);
      setResult(response);
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : "生成失败";
      setError(message);
    } finally {
      setGenerating(false);
    }
  }

  async function handleDesktopSelect() {
    const selected = await selectDesktopWorkbook();
    if (!selected) {
      return;
    }
    setDesktopFile(selected);
    setParseResult(null);
    setResult(null);
    setError(null);
  }

  return (
    <ConfigProvider locale={zhCN}>
      <Layout className="app-shell">
        <Content className="app-content">
          <div className="page-title">
            <Typography.Title level={2}>考勤汇总工具</Typography.Title>
          </div>

          <div className="workspace">
            <section className="main-panel">
              <Card size="small">
              <Steps
                current={currentStep}
                items={[
                  { title: "选择解析" },
                  { title: "校验生成" },
                  { title: "保存结果" }
                ]}
                className="flow-steps"
              />
              {error ? <Alert className="form-alert" type="error" showIcon message={error} /> : null}
              <Form form={form} layout="vertical" initialValues={defaultValues}>
                {currentStep === 0 ? (
                  <div className="upload-step">
                    <Result
                      icon={<FileExcelOutlined className="upload-result-icon" />}
                      title="选择原始考勤表"
                      extra={
                        <Space className="upload-actions" size="middle">
                          <Button icon={<FileExcelOutlined />} onClick={handleDesktopSelect}>
                            {desktopFile?.name ?? "选择 Excel"}
                          </Button>
                          <Button
                            type="primary"
                            icon={<SearchOutlined />}
                            loading={parsing}
                            disabled={!canParse}
                            onClick={handleParse}
                          >
                            解析文件
                          </Button>
                        </Space>
                      }
                    />
                  </div>
                ) : currentStep === 1 ? (
                  <>
                    <Typography.Paragraph type="secondary">
                      已解析：{parseResult?.filename}
                    </Typography.Paragraph>
                    <div className="non-workday-row">
                      <Typography.Text type="secondary">自动识别非工作日</Typography.Text>
                      <div className="tag-list">
                        {parseResult?.detected.non_workdays.length ? (
                          parseResult.detected.non_workdays.map((day) => (
                            <Tag color="blue" key={`${day.date}-${day.label}`}>
                              {day.date} {day.label}
                            </Tag>
                          ))
                        ) : (
                          <Typography.Text>无</Typography.Text>
                        )}
                      </div>
                    </div>

                    <div className="form-grid">
                      <Form.Item
                        name="dateRange"
                        label="统计日期"
                        rules={[{ required: true, message: "请选择统计日期" }]}
                      >
                        <RangePicker />
                      </Form.Item>
                      <Form.Item name="ignoreDates" label="忽略日期">
                        <DatePicker multiple />
                      </Form.Item>
                      <Form.Item name="overnight_cutoff" label="凌晨打卡截止">
                        <TimePicker format="HH:mm" />
                      </Form.Item>
                      <Form.Item name="work_start_time" label="上班时间">
                        <TimePicker format="HH:mm" />
                      </Form.Item>
                      <Form.Item name="work_end_time" label="下班时间">
                        <TimePicker format="HH:mm" />
                      </Form.Item>
                      <Form.Item name="overtime_start_time" label="加班起始时间">
                        <TimePicker format="HH:mm" />
                      </Form.Item>
                      <Form.Item name="workday_meal_after" label="工作日餐补阈值">
                        <TimePicker format="HH:mm" />
                      </Form.Item>
                      <Form.Item name="workday_overtime_2h_after" label="2小时加班阈值">
                        <TimePicker format="HH:mm" />
                      </Form.Item>
                      <Form.Item
                        name="meal_allowance_amount"
                        label="餐补金额"
                        rules={[{ required: true, message: "请输入餐补金额" }]}
                      >
                        <InputNumber min={0} precision={0} addonAfter="元" />
                      </Form.Item>
                    </div>

                    <Space className="generate-actions">
                      <Button
                        type="primary"
                        icon={<PlayCircleOutlined />}
                        loading={generating}
                        disabled={!canGenerate}
                        onClick={handleGenerate}
                      >
                        生成汇总表
                      </Button>
                    </Space>
                  </>
                ) : (
                  <Result
                    status="success"
                    title="汇总表已生成"
                    extra={
                      result ? (
                        <Button
                          type="primary"
                          icon={<DownloadOutlined />}
                          onClick={() => revealDesktopOutput(result.output_path)}
                        >
                          在文件夹中显示
                        </Button>
                      ) : null
                    }
                  />
                )}
              </Form>
              </Card>
            </section>
          </div>
        </Content>
      </Layout>
    </ConfigProvider>
  );
}
