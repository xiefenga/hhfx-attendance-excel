# 考勤汇总工具

本项目是一个本地考勤 Excel 汇总应用：先解析原始打卡表并回填可校验参数，再按规则生成加班、旷工、迟到、餐补汇总表。

## 后端

```bash
uv sync
uv run uvicorn backend.main:app --reload --host 127.0.0.1 --port 8001
```

接口：

- `GET /api/health`
- `POST /api/parse`
- `POST /api/generate`
- `GET /api/download/{file_id}`

## 前端

```bash
cd frontend
npm install
npm run dev
```

打开：

```text
http://127.0.0.1:5173
```

## 校验

```bash
uv run pytest
uv run mypy attendance_app backend
cd frontend
npm run typecheck
npm run build
```

## 命令行生成

```bash
python3 generate_attendance_summary.py
```

## Docker 部署

```bash
docker compose up --build
```

容器会在 `8001` 端口提供完整应用。镜像构建时会先编译前端 SPA，再由 FastAPI 同时提供 API 和静态资源：

```text
http://127.0.0.1:8001
```

部署后可以用健康检查接口确认服务状态：

```bash
curl http://127.0.0.1:8001/api/health
```

## 交互流程

1. 上传 Excel 后点击“解析文件”。
2. 系统从表头解析统计范围和所有非工作日，包括周六、周日和 `xx节` 节假日。
3. 用户校验回填的统计日期、忽略日期、餐补和时间阈值。
4. 点击“生成汇总表”进入下载结果步骤。
