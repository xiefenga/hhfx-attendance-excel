const path = require("node:path");

const projectRoot = __dirname;
const extraResource = [path.join(projectRoot, "resources", "sidecar", "attendance-worker")];

const packagerConfig = {
  asar: true,
  appBundleId: "com.attendanceexcel.desktop",
  appCategoryType: "public.app-category.productivity",
  executableName: "attendance-excel",
  extraResource,
  ignore: [
    /^\/(?!dist(?:\/|$)|package\.json$).+/
  ]
};

if (process.platform === "darwin") {
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
  name: "attendance_excel",
  authors: "Attendance Excel",
  description: "离线考勤 Excel 解析与汇总工具"
};

if (process.env.WINDOWS_CERTIFICATE_FILE) {
  squirrelConfig.certificateFile = process.env.WINDOWS_CERTIFICATE_FILE;
  squirrelConfig.certificatePassword = process.env.WINDOWS_CERTIFICATE_PASSWORD;
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
      config: { format: "ULFO" }
    },
    {
      name: "@electron-forge/maker-zip",
      platforms: ["darwin"]
    }
  ]
};
