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
可以直接分发的 `attendance-ledger-internal-release` 目录。

CI 读取 PFX 时会显式传入密码，不会等待交互输入。对于自签名证书，工作流通过
`certutil -user -f` 非交互地把公钥临时加入一次性 Windows runner 当前用户的受信任根
和受信任发布者，以便 Windows 完整验证签名状态；构建结束后 runner 会被销毁。文件签名
证书的指纹还必须与 PFX 完全一致。目标电脑上的安装脚本仍会在管理员确认后安装公钥。

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

## 四、整理内部安装目录

找到 `out\make\` 下生成的 `*Setup.exe`，执行：

```powershell
.\packaging\windows\New-InternalReleaseBundle.ps1 `
  -InstallerPath ".\out\make\squirrel.windows\x64\Attendance Ledger Setup.exe" `
  -CertificatePath "$env:USERPROFILE\Documents\AttendanceLedgerSigning\attendance-ledger.cer"
```

脚本先核对安装器签名，然后生成 `attendance-ledger-internal-release`：

```text
attendance-ledger-internal-release/
├── Install Attendance Ledger.cmd
├── Install-AttendanceLedger.ps1
├── attendance-ledger.cer
├── attendance-ledger.cer.thumbprint.txt
└── Attendance Ledger Setup.exe
```

只分发这个目录，不得把 PFX 放进去。

## 五、在目标电脑安装

1. 通过 U 盘或可信的公司内部共享目录复制整个安装目录。
2. 双击 `Install Attendance Ledger.cmd`。
3. 接受一次 Windows 管理员权限提示。
4. 脚本检查证书用途和指纹，将证书加入本机信任，并验证安装器确实由该证书签名。
5. 验证通过后自动启动 Squirrel 安装程序。

以后继续使用同一个 PFX 签名升级版本时，不需要重复安装证书。

## 移除内部信任

如果目标电脑不再使用该应用，以管理员身份打开 PowerShell，将指纹替换为实际值：

```powershell
$thumbprint = "证书指纹"
Remove-Item "Cert:\LocalMachine\TrustedPublisher\$thumbprint" -ErrorAction SilentlyContinue
Remove-Item "Cert:\LocalMachine\Root\$thumbprint" -ErrorAction SilentlyContinue
```
