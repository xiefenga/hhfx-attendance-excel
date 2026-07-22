# 考勤汇总工具

一个完全离线的桌面应用：读取原始考勤 Excel，校验日期和规则参数，并生成加班、旷工、迟到及餐补汇总表。

桌面壳使用 Electron，界面使用 React，考勤逻辑保留在 Python sidecar 中。Electron 与 sidecar 通过标准输入/输出上的 JSON Lines 协议通信，不启动 Web 服务、不监听端口；安装后的目标电脑不需要预装 Python、Node.js 或 Docker。

## 技术分工

- `electron-vite`：编译 Electron main、preload 和 React renderer，并提供开发期热更新。
- Electron Forge：组装应用、生成 macOS/Windows 安装包，以及承接签名和发布配置。
- PyInstaller：将 Python 核心和解释器冻结为随应用分发的 sidecar。

## 工程结构

```text
src/
  main/                 Electron 主进程
  preload/              安全的渲染进程桥接层
  renderer/             React 界面
  shared/               main/preload/renderer 共用的 IPC 类型
attendance_core/        平台无关的 Excel 解析与考勤业务核心
attendance_sidecar/     Electron 与 Python 之间的 JSON Lines 协议入口
packaging/pyinstaller/  Python sidecar 的打包配置
tests/                  Python 核心与 sidecar 测试
```

构建目录的职责如下：

- `dist/`：electron-vite 编译结果。
- `resources/sidecar/`：PyInstaller 生成的 sidecar。
- `.build/`：PyInstaller 临时文件。
- `out/`：Electron Forge 生成的应用和安装包。

## 准备开发环境

工程使用 [Volta](https://volta.sh/) 固定 Node.js 24.13.1 和 npm 11.8.0。安装 Volta 后，进入工程目录会自动使用指定版本。

```bash
volta install node@24.13.1 npm@11.8.0
uv sync
uv pip install --python .venv -r packaging/pyinstaller/requirements.txt
ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/ npm ci
```

工程级 `.npmrc` 已将 npm 包下载源设为 npmmirror；`ELECTRON_MIRROR` 只控制 Electron 二进制的下载地址。

## 开发运行

```bash
npm run dev
```

该命令同时启动 electron-vite 开发服务器、Electron 主进程和 `.venv` 中的 `attendance_sidecar.main`，React 修改可热更新。

如需用生产构建结果本地预览：

```bash
npm start
```

## 检查与测试

```bash
uv run pytest
uv run mypy attendance_core attendance_sidecar
npm run typecheck
npm run build:electron
```

## 构建桌面安装包

```bash
npm run make
```

构建依次执行 TypeScript 类型检查、electron-vite 生产编译、PyInstaller sidecar 打包和 Electron Forge 制品生成。安装包位于 `out/make/`。

PyInstaller 和 Electron 原生制品不能可靠地跨系统构建，因此 Windows 包在 Windows runner 上生成，macOS 包在 macOS runner 上生成。

## GitHub Actions Release

`.github/workflows/release-desktop.yml` 构建以下平台：

- macOS Apple Silicon（arm64）
- macOS Intel（x64）
- Windows x64

手动运行工作流只生成 Actions artifacts；推送 `v*` 标签时还会创建 GitHub Release：

```bash
git tag v0.1.0
git push origin v0.1.0
```

未提供正式证书时，macOS 使用 ad-hoc 签名，Windows 不签名。正式签名使用工作流中声明的 macOS/Windows 仓库 Secrets。

## 命令行生成

业务核心仍可单独从命令行运行：

```bash
uv run python generate_attendance_summary.py
```

## 使用流程

1. 选择原始考勤 `.xlsx` 文件并解析。
2. 校验统计日期、非工作日、忽略日期和时间阈值。
3. 选择输出路径并生成汇总表。
4. 在 Finder 或文件资源管理器中定位结果。
