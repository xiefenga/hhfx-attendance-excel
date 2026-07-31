using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

internal static class AttendanceLedgerInstaller
{
    private const string BundleResourceName = "AttendanceLedgerBundle.zip";
    private const string InstallerScriptRelativePath =
        @"Attendance Ledger Files\Install-AttendanceLedger.ps1";

    [STAThread]
    private static int Main(string[] args)
    {
        bool validateOnly =
            args.Length == 1 &&
            string.Equals(args[0], "--validate-only", StringComparison.OrdinalIgnoreCase);
        string temporaryDirectory = Path.Combine(
            Path.GetTempPath(),
            "attendance-ledger-installer-" + Guid.NewGuid().ToString("N"));

        try
        {
            Directory.CreateDirectory(temporaryDirectory);
            string archivePath = Path.Combine(temporaryDirectory, "bundle.zip");
            ExtractBundle(archivePath);
            ZipFile.ExtractToDirectory(archivePath, temporaryDirectory);

            string scriptPath = Path.Combine(
                temporaryDirectory,
                InstallerScriptRelativePath);
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException(
                    "安装程序内部缺少 Install-AttendanceLedger.ps1。",
                    scriptPath);
            }

            ProcessResult result = RunInstallerScript(
                scriptPath,
                validateOnly);
            if (result.ExitCode != 0)
            {
                throw new InvalidOperationException(
                    BuildFailureMessage(result));
            }

            if (!validateOnly)
            {
                Application.EnableVisualStyles();
                MessageBox.Show(
                    "Attendance Ledger 已成功安装或更新。",
                    "Attendance Ledger 安装程序",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            return 0;
        }
        catch (Exception error)
        {
            if (!validateOnly)
            {
                Application.EnableVisualStyles();
                MessageBox.Show(
                    error.Message,
                    "Attendance Ledger 安装失败",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
            return 1;
        }
        finally
        {
            TryDeleteDirectory(temporaryDirectory);
        }
    }

    private static void ExtractBundle(string archivePath)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        using (Stream resource = assembly.GetManifestResourceStream(BundleResourceName))
        {
            if (resource == null)
            {
                throw new InvalidOperationException("安装程序内部缺少发布包资源。");
            }
            using (FileStream output = File.Create(archivePath))
            {
                resource.CopyTo(output);
            }
        }
    }

    private static ProcessResult RunInstallerScript(
        string scriptPath,
        bool validateOnly)
    {
        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = "powershell.exe";
        startInfo.Arguments =
            "-NoProfile -ExecutionPolicy Bypass -File " +
            Quote(scriptPath) +
            (validateOnly ? " -ValidatePathsOnly" : "");
        startInfo.WorkingDirectory = Path.GetDirectoryName(scriptPath);
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.RedirectStandardOutput = true;
        startInfo.RedirectStandardError = true;

        using (Process process = Process.Start(startInfo))
        {
            Task<string> standardOutput = process.StandardOutput.ReadToEndAsync();
            Task<string> standardError = process.StandardError.ReadToEndAsync();
            process.WaitForExit();
            Task.WaitAll(standardOutput, standardError);
            return new ProcessResult(
                process.ExitCode,
                standardOutput.Result,
                standardError.Result);
        }
    }

    private static string BuildFailureMessage(ProcessResult result)
    {
        StringBuilder message = new StringBuilder();
        message.AppendLine("安装未成功完成。");
        message.AppendLine("退出码：" + result.ExitCode);
        string details = (result.StandardError + Environment.NewLine +
            result.StandardOutput).Trim();
        if (details.Length > 1600)
        {
            details = details.Substring(details.Length - 1600);
        }
        if (details.Length > 0)
        {
            message.AppendLine();
            message.AppendLine(details);
        }
        message.AppendLine();
        message.Append(
            @"详细日志通常位于 %LOCALAPPDATA%\SquirrelTemp\SquirrelSetup.log。");
        return message.ToString();
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static void TryDeleteDirectory(string path)
    {
        for (int attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                if (Directory.Exists(path))
                {
                    Directory.Delete(path, true);
                }
                return;
            }
            catch
            {
                System.Threading.Thread.Sleep(300);
            }
        }
    }

    private sealed class ProcessResult
    {
        internal ProcessResult(
            int exitCode,
            string standardOutput,
            string standardError)
        {
            ExitCode = exitCode;
            StandardOutput = standardOutput;
            StandardError = standardError;
        }

        internal int ExitCode { get; private set; }
        internal string StandardOutput { get; private set; }
        internal string StandardError { get; private set; }
    }
}
