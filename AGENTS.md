# AGENTS.md

本文件适用于整个仓库，供自动化编码代理和贡献者使用。

## 项目目标

这是一个完全离线的考勤 Excel 桌面应用。Electron 负责桌面能力和界面承载，React 负责渲染，Python sidecar 负责 Excel 解析与业务计算。运行时不得启动 HTTP 服务或监听网络端口。

## 目录职责

- `src/main/`：Electron 主进程；窗口、原生对话框、sidecar 生命周期与 IPC handler。
- `src/preload/`：通过 `contextBridge` 暴露最小化、白名单化的桌面 API。
- `src/renderer/`：React 渲染进程；不得直接访问 Node.js 或 Electron API。
- `src/shared/`：main、preload、renderer 共用的 IPC 类型契约。
- `attendance_core/`：平台无关的考勤业务核心，不依赖 Electron。
- `attendance_sidecar/`：JSON Lines 协议入口，保持标准输出仅包含协议消息。
- `packaging/pyinstaller/`：Python sidecar 冻结配置。
- `.github/workflows/`：macOS 和 Windows 构建、签名及 Release 工作流。

## 工程约束

- 保持 `contextIsolation: true`、`nodeIntegration: false` 和 `sandbox: true`。
- 新增桌面能力时同步更新 `src/shared/ipc-contract.ts`、preload 白名单和 main handler。
- 不把任意 shell、文件系统或 Electron 对象直接暴露给 renderer。
- Python 业务逻辑优先放在 `attendance_core/`；sidecar 只负责协议转换和调用编排。
- 不重新引入 FastAPI、Docker 或本地 Web 服务，除非需求明确改变整体架构。
- macOS 与 Windows 制品必须分别在对应操作系统上构建，不假设 PyInstaller 可以跨平台打包。
- 不提交原始 Excel、`outputs/`、`.venv/`、`node_modules/`、`dist/`、`resources/sidecar/`、`.build/` 或 `out/`。

## 开发环境

- Node.js 由 Volta 固定为 24.13.1，npm 为 11.8.0。
- Python 版本由 `.python-version` 固定，依赖使用 `uv` 管理。
- Node 依赖以根目录 `package.json` 和 `package-lock.json` 为唯一来源，不创建子工程锁文件。

初始化命令：

```bash
uv sync --frozen
uv pip install --python .venv -r packaging/pyinstaller/requirements.txt
npm ci
```

开发启动：

```bash
npm run dev
```

## 修改后的验证

根据变更范围执行必要检查，提交前应尽量完成：

```bash
npm run typecheck
npm run build:electron
uv run pytest -q
uv run mypy attendance_core attendance_sidecar
```

涉及 sidecar、Forge、资源路径或签名配置时，还应在当前平台运行：

```bash
npm run make
```

Windows 构建使用：

```powershell
npm run make -- --arch=x64
```

## 代码与提交约定

- TypeScript 与 Python 均保持严格类型检查通过。
- 优先复用共享类型，避免在 renderer、preload 和 main 中重复定义协议结构。
- 保留用户已有数据和无关修改，不使用破坏性 Git 命令清理工作区。
- 提交信息遵循 Conventional Commits，说明优先使用中文，例如：`fix(sidecar): 修复 Windows 路径解析`。
- 依赖升级必须同步更新锁文件，并检查 peer dependency 与 Node/Python 版本要求。
