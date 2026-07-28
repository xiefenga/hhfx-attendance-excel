# Windows 内部免费签名与安装

本方案适用于一两台受控 Windows 电脑。它使用自签名代码签名证书，不需要购买商业证书。
自签名证书不会自动受到其他电脑信任，因此只能把公钥安装到明确授权的内部电脑。

## 安全边界

- `attendance-ledger-signing.pfx` 包含私钥，只能保存在构建电脑、离线备份或 GitHub Secrets。
- PFX 密码应保存在密码管理器中，不能提交到 Git、聊天或安装包。
- `attendance-ledger.cer` 只有公钥，可以随安装包分发。
- 安装脚本会把公钥加入目标电脑的本机受信任根和受信任发布者，需要管理员权限。
- 不再使用这套应用时，应从目标电脑的两个证书存储区移除该证书。

## 一、生成证书

在一台可信的 Windows 电脑上打开 PowerShell：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\packaging\windows\New-CodeSigningCertificate.ps1
```

脚本默认把以下文件生成到“文档\AttendanceLedgerSigning”：

- `attendance-ledger-signing.pfx`：构建私钥，禁止分发。
- `attendance-ledger.cer`：安装到目标电脑的公钥。
- `attendance-ledger.cer.thumbprint.txt`：证书指纹。

脚本同时将公钥加入构建电脑“当前用户”的受信任根和受信任发布者，以便本地验证签名；
不会修改整台电脑的证书存储。

证书默认有效五年。到期或私钥泄露后，应生成新证书并重新部署公钥。

## 二、配置 GitHub Actions

打开仓库的 Settings → Secrets and variables → Actions，添加：

- `WINDOWS_CERTIFICATE`：PFX 文件的 Base64 文本。
- `WINDOWS_CERTIFICATE_PASSWORD`：生成证书时设置的密码。

在 Windows PowerShell 中将 PFX 转成 Base64 并复制到剪贴板：

```powershell
$pfx = "$env:USERPROFILE\Documents\AttendanceLedgerSigning\attendance-ledger-signing.pfx"
[Convert]::ToBase64String([IO.File]::ReadAllBytes($pfx)) | Set-Clipboard
```

工作流会把证书写入 runner 临时目录。Electron Packager 递归签署应用主程序、DLL、Node
原生模块和 `attendance-worker.exe`，Squirrel maker 再签署安装器。构建完成后，工作流会
验证主程序、sidecar 和 `Setup.exe` 的签名及证书指纹，并在 Windows artifact 中生成
可以直接分发的 `Attendance-Ledger-Windows-x64.zip`。GitHub Actions artifact 和
GitHub Release 都只发布这个 Windows ZIP，不再附带松散的 Squirrel 文件。

CI 读取 PFX 时会显式传入密码，不会等待交互输入，也不会尝试修改 GitHub runner 的证书
信任库。自签名证书在 CI 中可能返回 `NotTrusted` 或 `UnknownError`，但签名证书必须存在
且指纹必须与 PFX 完全一致；`NotSigned`、`HashMismatch` 等状态仍会导致构建失败。目标
电脑上的安装脚本会在管理员确认后安装公钥，并要求安装器签名状态为 `Valid`。

## 三、本地 Windows 构建

也可以在持有 PFX 的 Windows 电脑上本地构建：

```powershell
$env:WINDOWS_CERTIFICATE_FILE = "$env:USERPROFILE\Documents\AttendanceLedgerSigning\attendance-ledger-signing.pfx"
$env:WINDOWS_CERTIFICATE_PASSWORD = "PFX 密码"
npm run make -- --arch=x64
```

不要把密码写入仓库脚本或 `.env` 文件。构建完成后清除当前终端中的密码：

```powershell
Remove-Item Env:WINDOWS_CERTIFICATE_PASSWORD
Remove-Item Env:WINDOWS_CERTIFICATE_FILE
```

## 四、生成内部安装 ZIP

找到 `out\make\` 下生成的 `*Setup.exe`，执行：

```powershell
.\packaging\windows\New-InternalReleaseBundle.ps1 `
  -InstallerPath ".\out\make\squirrel.windows\x64\Attendance Ledger Setup.exe" `
  -CertificatePath "$env:USERPROFILE\Documents\AttendanceLedgerSigning\attendance-ledger.cer" `
  -ArchivePath ".\out\Attendance-Ledger-Windows-x64.zip"
```

脚本先核对安装器签名，然后生成单个 ZIP。解压后的结构如下：

```text
Attendance-Ledger-Windows-x64/
├── Install Attendance Ledger.cmd
└── Attendance Ledger Files/
    ├── Install Attendance Ledger.cmd
    ├── Install-AttendanceLedger.ps1
    ├── attendance-ledger.cer
    ├── attendance-ledger.cer.thumbprint.txt
    ├── attendance-ledger.version.txt
    └── Attendance Ledger Setup.exe
```

根目录只有一个安装入口和一个文件夹；文件夹内包含 6 个发布文件。生成脚本会检查
归档内 7 个文件的精确路径和数量。版本文件用于区分首次安装、同版本重复执行、升级和
降级。ZIP 只包含公钥证书，不包含 PFX 或私钥。

## 五、在目标电脑首次安装

1. 通过 U 盘或可信的公司内部共享目录复制 ZIP，并完整解压到任意位置。
2. 双击 `Install Attendance Ledger.cmd`。
3. 接受一次 Windows 管理员权限提示。
4. 脚本检查证书用途和指纹，将证书加入本机信任，并验证安装器确实由该证书签名。
5. 验证通过后自动启动 Squirrel 安装程序。

## 六、手动升级

升级版本必须使用相同的 Squirrel 应用标识，并把应用版本号提升，例如从 `0.1.3` 提升到
`0.1.4`。Release 工作流会使用 `v*` 标签作为安装包版本：

```bash
git tag v0.1.4
git push origin v0.1.4
```

在目标电脑下载并完整解压新版本 ZIP，再次双击 `Install Attendance Ledger.cmd`：

- 未找到现有版本时执行首次安装；
- 新版本高于现有版本时执行覆盖升级；
- 新旧版本相同时提示已经安装并退出；
- 新版本低于现有版本时拒绝降级；
- 使用同一签名证书且证书仍在两个本机信任存储中时，不重复导入证书，也不请求管理员权限；
- 证书缺失或轮换时，才请求管理员权限并部署新证书。

Windows 安装版会从以下 Gitee 静态更新源自动检查新版本：

```text
https://gitee.com/xf_wwx/attendance-ledger-updates/raw/master/win32/x64
```

应用启动后检查一次，此后每小时检查一次。发现新版本后会在后台下载，并提示用户重启
完成安装。GitHub Release 中的内部安装 ZIP 仍保留，可在自动更新不可用时手工升级。

推送 `v*` 标签时，Release 工作流使用 GitHub Secret `GITEE_TOKEN` 在 Gitee 更新仓库中：

1. 创建对应版本的 Release；
2. 上传 Squirrel `.nupkg`、`Setup.exe` 和 `RELEASES`；
3. 将包含 `.nupkg` 绝对下载地址的 `win32/x64/RELEASES` 写入 `master` 分支。

令牌只保存在 GitHub Actions Secrets 中，不得写入仓库、安装包或客户端配置。

## 七、移除内部信任

如果目标电脑不再使用该应用，以管理员身份打开 PowerShell，将指纹替换为实际值：

```powershell
$thumbprint = "证书指纹"
Remove-Item "Cert:\LocalMachine\TrustedPublisher\$thumbprint" -ErrorAction SilentlyContinue
Remove-Item "Cert:\LocalMachine\Root\$thumbprint" -ErrorAction SilentlyContinue
```
