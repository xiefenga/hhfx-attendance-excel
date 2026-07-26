const path = require("node:path");

const projectRoot = __dirname;
const extraResource = [path.join(projectRoot, "resources", "sidecar", "attendance-worker")];
const iconDirectory = path.join(projectRoot, "assets", "icons");
const macIcon = path.join(iconDirectory, "attendance-ledger.icns");
const windowsIcon = path.join(iconDirectory, "attendance-ledger.ico");

const packagerConfig = {
  asar: true,
  appBundleId: "com.attendanceledger.desktop",
  appCategoryType: "public.app-category.productivity",
  executableName: "attendance-ledger",
  extraResource,
  ignore: [
    /^\/(?!dist(?:\/|$)|package\.json$).+/
  ]
};

if (process.platform === "darwin") {
  packagerConfig.icon = macIcon;
  packagerConfig.osxSign = process.env.MACOS_CERTIFICATE
    ? { continueOnError: false }
    : {
        identity: "-",
        identityValidation: false,
        optionsForFile: () => ({
          hardenedRuntime: false,
          timestamp: "none"
        }),
        continueOnError: false
      };
}

if (process.platform === "win32") {
  packagerConfig.icon = windowsIcon;
}

if (
  process.platform === "darwin" &&
  process.env.APPLE_ID &&
  process.env.APPLE_APP_SPECIFIC_PASSWORD &&
  process.env.APPLE_TEAM_ID
) {
  packagerConfig.osxNotarize = {
    appleId: process.env.APPLE_ID,
    appleIdPassword: process.env.APPLE_APP_SPECIFIC_PASSWORD,
    teamId: process.env.APPLE_TEAM_ID
  };
}

const squirrelConfig = {
  name: "attendance_ledger",
  authors: "Attendance Ledger",
  description: "离线考勤 Excel 解析与汇总工具",
  setupExe: "Attendance Ledger Setup.exe",
  setupIcon: windowsIcon
};

if (process.env.WINDOWS_CERTIFICATE_FILE) {
  const windowsSign = {
    certificateFile: process.env.WINDOWS_CERTIFICATE_FILE,
    certificatePassword: process.env.WINDOWS_CERTIFICATE_PASSWORD,
    description: "Attendance Ledger",
    hashes: ["sha256"]
  };
  packagerConfig.windowsSign = windowsSign;
  squirrelConfig.windowsSign = windowsSign;
}

module.exports = {
  packagerConfig,
  rebuildConfig: {},
  makers: [
    {
      name: "@electron-forge/maker-squirrel",
      config: squirrelConfig
    },
    {
      name: "@electron-forge/maker-dmg",
      config: { format: "ULFO", icon: macIcon }
    },
    {
      name: "@electron-forge/maker-zip",
      platforms: ["darwin"]
    }
  ]
};
